"""listen.py: задачи владельца из Telegram → запуск агента; чужие и устаревшие — нет."""
import os
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "agent"))
import listen  # noqa: E402
import telegram  # noqa: E402


class Api:
    def __init__(self, updates):
        self.updates, self.sent = updates, []

    def __call__(self, method, payload):
        if method == "sendMessage":
            self.sent.append(payload["text"])
            return {"ok": True, "result": {"message_id": 1}}
        if method == "getUpdates":
            return {"ok": True, "result": self.updates}
        return {"ok": True, "result": True}


def msg(uid, chat, frm, text, date=1000):
    return {"update_id": uid, "message": {"chat": {"id": chat}, "from": {"id": frm}, "text": text, "date": date}}


class ListenTest(unittest.TestCase):
    def test_only_owner_private_chat(self):
        api = Api([msg(1, 99, 99, "чужой"), msg(2, 1, 99, "в чате, но не владелец"), msg(3, 1, 1, "перезапусти synapse")])
        off, got = telegram.Bot("t", "1", call=api).messages(0)
        self.assertEqual(off, 4)
        self.assertEqual([m["text"] for m in got], ["перезапусти synapse"])

    def test_fresh_task_runs_old_is_refused(self):
        api = Api([])
        ran = []
        bot = telegram.Bot("t", "1", call=api)
        n = listen.handle(bot, [{"text": "свежая", "date": 9000}, {"text": "старая", "date": 100}], 9100, run=ran.append)
        self.assertEqual((n, ran), (1, ["свежая"]))
        self.assertTrue(any("старая" in s and "не исполняю" in s for s in api.sent))

    def test_start_gives_help_not_task(self):
        api, ran = Api([]), []
        listen.handle(telegram.Bot("t", "1", call=api), [{"text": "/start", "date": 9000}], 9000, run=ran.append)
        self.assertEqual(ran, [])
        self.assertIn("хранитель", api.sent[0])

    def test_offset_roundtrip(self):
        p = os.path.join(tempfile.mkdtemp(), "x", "off")
        self.assertIsNone(listen.read_offset(p))
        listen.write_offset(17, p)
        self.assertEqual(listen.read_offset(p), 17)

    def test_task_scenario_passes_task_to_agent(self):
        tmp = tempfile.mkdtemp()
        claude, probe = os.path.join(tmp, "claude"), os.path.join(tmp, "probe")
        open(claude, "w").write('#!/usr/bin/env python3\nimport sys,json,os\nopen(os.environ["FAKE_DUMP"],"w").write(sys.argv[2])\n'
                                'print(json.dumps({"result": "Что было: задача. Сейчас: ок."}))\n')
        open(probe, "w").write("#!/usr/bin/env bash\necho '{\"ok\": true, \"total\": 7, \"failed\": []}'\n")
        for p in (claude, probe):
            os.chmod(p, stat.S_IRWXU)
        dump = os.path.join(tmp, "dump")
        env = {"PATH": os.environ["PATH"], "HOME": tmp, "CLAUDE_BIN": claude, "GUARDIAN_PROBE": probe,
               "GUARDIAN_SCENARIO": "task", "GUARDIAN_FORCE": "1", "GUARDIAN_TASK": "почему лежит Инбокс?",
               "GUARDIAN_STATE": os.path.join(tmp, "state"), "FAKE_DUMP": dump, "ZAI_API_KEY": "k"}
        r = subprocess.run(["bash", os.path.join(ROOT, "agent", "heal.sh")], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        prompt = open(dump).read()
        self.assertIn("ЗАДАЧА ВЛАДЕЛЬЦА (из Telegram): почему лежит Инбокс?", prompt)
        self.assertIn("Режим задачи", prompt)
        self.assertIn("Сейчас: ок.", r.stdout)


if __name__ == "__main__":
    unittest.main()
