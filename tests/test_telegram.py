import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "agent"))
import telegram  # noqa: E402


class FakeApi:
    def __init__(self, updates=()):
        self.calls = []
        self.updates = list(updates)  # список ответов на getUpdates (по очереди)

    def __call__(self, method, payload):
        self.calls.append((method, payload))
        if method == "sendMessage":
            return {"ok": True, "result": {"message_id": 42}}
        if method == "getUpdates":
            return {"ok": True, "result": self.updates.pop(0) if self.updates else []}
        return {"ok": True, "result": True}


def cq(update_id, chat, mid, data):
    return {"update_id": update_id, "callback_query": {
        "id": "q%d" % update_id, "data": data, "from": {"id": chat},
        "message": {"message_id": mid, "chat": {"id": chat}}}}


class BotTest(unittest.TestCase):
    def test_unconfigured_does_not_fail(self):
        bot = telegram.Bot(token="", chat_id="")
        self.assertIsNone(bot.send("x"))
        self.assertEqual(bot.ask("x", timeout=1), "timeout")

    def test_long_text_split(self):
        api = FakeApi()
        telegram.Bot("t", "1", call=api).send("a" * 9000)
        self.assertEqual(sum(1 for m, _ in api.calls if m == "sendMessage"), 3)

    def test_ask_accepts_only_owner_and_this_message(self):
        api = FakeApi(updates=[
            [{"update_id": 5}],                       # offset=-1: старый апдейт
            [cq(6, 999, 42, "yes"),                   # чужой чат — игнор
             cq(7, 1, 41, "yes"),                     # другое сообщение — игнор
             cq(8, 1, 42, "no")],                     # владелец, наше сообщение
        ])
        bot = telegram.Bot("t", "1", call=api)
        self.assertEqual(bot.ask("перезапустить?", timeout=100), "no")
        offsets = [p.get("offset") for m, p in api.calls if m == "getUpdates"]
        self.assertEqual(offsets[:2], [-1, 6])

    def test_ask_timeout(self):
        t = [0]

        def clock():
            t[0] += 60
            return t[0]
        api = FakeApi(updates=[[], [], [], []])
        self.assertEqual(telegram.Bot("t", "1", call=api).ask("?", timeout=100, clock=clock), "timeout")

    def test_http_error_hides_token(self):
        bot = telegram.Bot("SECRET123", "1")
        bot._call = lambda m, p: (_ for _ in ()).throw(RuntimeError("telegram %s: URLError" % m))
        with self.assertRaises(RuntimeError) as ctx:
            bot.send("x")
        self.assertNotIn("SECRET123", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
