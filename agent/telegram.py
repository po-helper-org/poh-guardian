#!/usr/bin/env python3
"""Telegram-бот хранителя: отправить, поправить, спросить кнопками.

Секреты — только из окружения: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID (личка владельца с ботом).
Нет токена — печатает в stderr с пометкой и не падает (workflow не должен ломаться из-за канала).

  telegram.py send "текст" [--id-file F]      # напечатает message_id
  telegram.py edit F "текст"                  # поправить сообщение из id-файла
  telegram.py ask "вопрос" [--timeout 1800]   # ✅/❌; печатает yes|no|timeout
"""
import argparse
import json
import os
import sys
import time
import urllib.request

LIMIT = 4000


class Bot:
    def __init__(self, token=None, chat_id=None, call=None):
        self.token = token if token is not None else os.environ.get("TELEGRAM_BOT_TOKEN", "")
        self.chat_id = str(chat_id if chat_id is not None else os.environ.get("TELEGRAM_CHAT_ID", ""))
        self._call = call or self._http

    @property
    def configured(self):
        return bool(self.token and self.chat_id)

    def _http(self, method, payload, timeout=70):
        req = urllib.request.Request(
            "https://api.telegram.org/bot%s/%s" % (self.token, method),
            data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except Exception as e:  # текст ошибки без токена: в URL он есть, в e — нет
            raise RuntimeError("telegram %s: %s" % (method, type(e).__name__)) from None

    def call(self, method, **payload):
        res = self._call(method, payload)
        if not res.get("ok"):
            raise RuntimeError("telegram %s: %s" % (method, res.get("description", "ошибка")))
        return res["result"]

    def send(self, text, buttons=None):
        if not self.configured:
            print("[telegram не настроен] " + text, file=sys.stderr)
            return None
        mid = None
        for i in range(0, max(len(text), 1), LIMIT):
            payload = {"chat_id": self.chat_id, "text": text[i:i + LIMIT],
                       "disable_web_page_preview": True}
            if buttons and i + LIMIT >= len(text):
                payload["reply_markup"] = {"inline_keyboard": [[
                    {"text": label, "callback_data": data} for label, data in buttons]]}
            mid = self.call("sendMessage", **payload)["message_id"]
        return mid

    def edit(self, message_id, text):
        if not self.configured or not message_id:
            print("[telegram не настроен] " + text, file=sys.stderr)
            return
        self.call("editMessageText", chat_id=self.chat_id, message_id=int(message_id),
                  text=text[:LIMIT], disable_web_page_preview=True)

    def ask(self, text, timeout=1800, clock=time.time):
        """Кнопки ✅/❌. Ответ принимается только из чата владельца и только на это сообщение."""
        if not self.configured:
            print("[telegram не настроен — вопрос без ответа] " + text, file=sys.stderr)
            return "timeout"
        # пропустить старые апдейты
        old = self.call("getUpdates", offset=-1, timeout=0)
        offset = old[-1]["update_id"] + 1 if old else 0
        mid = self.send(text, buttons=[("✅ Выполнить", "yes"), ("❌ Не надо", "no")])
        deadline = clock() + timeout
        while clock() < deadline:
            wait = int(max(1, min(50, deadline - clock())))
            for upd in self.call("getUpdates", offset=offset, timeout=wait,
                                 allowed_updates=["callback_query"]):
                offset = upd["update_id"] + 1
                cq = upd.get("callback_query")
                if not cq or str(cq.get("message", {}).get("chat", {}).get("id")) != self.chat_id:
                    continue
                if cq.get("message", {}).get("message_id") != mid:
                    continue
                if str(cq.get("from", {}).get("id")) != self.chat_id:  # нажать может только владелец (личка)
                    continue
                answer = "yes" if cq.get("data") == "yes" else "no"
                self.call("answerCallbackQuery", callback_query_id=cq["id"],
                          text="Выполняю" if answer == "yes" else "Не выполняю")
                self.edit(mid, text + ("\n\n→ ✅ одобрено" if answer == "yes" else "\n\n→ ❌ отклонено"))
                return answer
        self.edit(mid, text + "\n\n→ ⏳ ответа не было, не выполнено")
        return "timeout"


def main(argv=None):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send"); s.add_argument("text"); s.add_argument("--id-file")
    e = sub.add_parser("edit"); e.add_argument("id_file"); e.add_argument("text")
    q = sub.add_parser("ask"); q.add_argument("text"); q.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args(argv)
    bot = Bot()
    try:
        if a.cmd == "send":
            mid = bot.send(a.text)
            if a.id_file and mid:
                with open(a.id_file, "w") as f:
                    f.write(str(mid))
            print(mid or "")
        elif a.cmd == "edit":
            try:
                mid = open(a.id_file).read().strip()
            except OSError:
                mid = None
            bot.edit(mid, a.text) if mid else bot.send(a.text)
        else:
            print(bot.ask(a.text, timeout=a.timeout))
    except RuntimeError as err:  # канал не должен ронять разбор
        print("[telegram ошибка] %s" % err, file=sys.stderr)
        if a.cmd == "ask":
            print("timeout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
