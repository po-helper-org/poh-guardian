#!/usr/bin/env python3
"""Слушатель задач: сообщение владельца в Telegram-боте хранителя → ИИ-агент исполняет его в белом списке.

Работает на Mac (launchd, KeepAlive). Читает только личку владельца (TELEGRAM_CHAT_ID), по одной задаче за раз.
Пока работает хранитель (замок heal.lock), сообщения не читает — иначе getUpdates спорит с кнопками ✅/❌.
Задача старше GUARDIAN_TASK_MAX_AGE (по умолчанию 1 ч) не исполняется: инфраструктурные просьбы устаревают.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import telegram  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
STATE = os.path.expanduser("~/.local/state/poh-guardian")
OFFSET_FILE = os.path.join(STATE, "listen.offset")
LOCK = os.path.join(STATE, "heal.lock")
MAX_AGE = int(os.environ.get("GUARDIAN_TASK_MAX_AGE", "3600"))
HELP = ("Я хранитель сервера dede. Напишите задачу про обслуживание или доступность сервера — "
        "например «почему лежит Инбокс?» или «перезапусти matrix-synapse». "
        "Что вне моего белого списка, пришлю кнопкой ✅/❌.")


def read_offset(path=OFFSET_FILE):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return None


def write_offset(offset, path=OFFSET_FILE):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(str(offset))


def run_task(text):
    env = dict(os.environ, GUARDIAN_TASK=text, GUARDIAN_FORCE="1", GUARDIAN_SCENARIO="task",
               GUARDIAN_REASON="задача владельца из Telegram")
    subprocess.run([os.path.join(ROOT, "agent", "heal.sh")], env=env, cwd=ROOT)


def handle(bot, msgs, now, run=run_task):
    """Исполнить сообщения по очереди. Возвращает число запущенных задач."""
    started = 0
    for m in msgs:
        text = m["text"].strip()
        if text in ("/start", "/help"):
            bot.send(HELP)
        elif now - m["date"] > MAX_AGE:
            bot.send("⏳ Задача «%s» пришла давно (>%d мин), не исполняю — повторите, если ещё нужна." % (text[:80], MAX_AGE // 60))
        else:
            run(text)
            started += 1
    return started


def main():
    for f in ("telegram.env", "guardian.env"):
        path = os.path.expanduser("~/.config/poh-guardian/" + f)
        if os.path.exists(path):
            for line in open(path):
                k, _, v = line.strip().partition("=")
                if k and v and not k.startswith("#"):
                    os.environ.setdefault(k, v)
    bot = telegram.Bot()
    if not bot.configured:
        print("telegram не настроен — слушать нечего", file=sys.stderr)
        return 1
    offset = read_offset()
    if offset is None:  # первый запуск: старую переписку не исполнять
        old = bot.call("getUpdates", offset=-1, timeout=0)
        offset = old[-1]["update_id"] + 1 if old else 0
        write_offset(offset)
    while True:
        if os.path.isdir(LOCK):  # хранитель занят (в т.ч. ждёт кнопку)
            time.sleep(10)
            continue
        try:
            offset, msgs = bot.messages(offset)
        except RuntimeError as err:
            print("[listen] %s" % err, file=sys.stderr)
            time.sleep(10)
            continue
        write_offset(offset)
        handle(bot, msgs, time.time())


if __name__ == "__main__":
    sys.exit(main())
