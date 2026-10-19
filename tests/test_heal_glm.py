"""heal.sh: агент работает на GLM (Z.AI) и никогда не видит вход/токен Claude владельца."""
import json
import os
import stat
import subprocess
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

FAKE_CLAUDE = """#!/usr/bin/env python3
import json, os, sys
json.dump({"env": {k: os.environ.get(k) for k in (
    "CLAUDE_CONFIG_DIR", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
    "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN", "ZAI_API_KEY",
    "GUARDIAN_APPROVED_KEY_PEM")}, "argv": sys.argv[1:]}, open(os.environ["FAKE_DUMP"], "w"))
print(json.dumps({"result": "Что было: учения. Сейчас: ок."}))
"""
FAKE_PROBE = """#!/usr/bin/env bash
echo '{"ok": true, "total": 7, "failed": []}'
"""


class HealGlmTest(unittest.TestCase):
    def run_heal(self, extra_env):
        tmp = tempfile.mkdtemp()
        claude, probe = os.path.join(tmp, "claude"), os.path.join(tmp, "probe")
        for path, body in ((claude, FAKE_CLAUDE), (probe, FAKE_PROBE)):
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, stat.S_IRWXU)
        dump = os.path.join(tmp, "dump.json")
        env = {"PATH": os.environ["PATH"], "HOME": tmp, "CLAUDE_BIN": claude, "GUARDIAN_PROBE": probe,
               "GUARDIAN_SCENARIO": "canary", "GUARDIAN_STATE": os.path.join(tmp, "state"), "FAKE_DUMP": dump,
               # что лежит в окружении владельца/раннера и НЕ должно дойти до агента:
               "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-OWNER", "ANTHROPIC_API_KEY": "sk-ant-api-OWNER",
               "GUARDIAN_APPROVED_KEY_PEM": "PEM"}
        env.update(extra_env)
        r = subprocess.run(["bash", os.path.join(ROOT, "agent", "heal.sh")], env=env,
                           capture_output=True, text=True, timeout=60)
        seen = json.load(open(dump)) if os.path.exists(dump) else None
        return r, seen, tmp

    def test_agent_runs_on_zai_without_owner_claude(self):
        r, seen, tmp = self.run_heal({"ZAI_API_KEY": "zai-test-key", "TELEGRAM_BOT_TOKEN": "tg"})
        self.assertEqual(r.returncode, 0, r.stderr)
        e = seen["env"]
        self.assertEqual(e["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        self.assertEqual(e["ANTHROPIC_AUTH_TOKEN"], "zai-test-key")
        self.assertTrue(e["ANTHROPIC_MODEL"].startswith("glm-"))
        self.assertTrue(e["CLAUDE_CONFIG_DIR"].startswith(os.path.join(tmp, "state")), "пустой конфиг, не ~/.claude")
        for leaked in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN", "GUARDIAN_APPROVED_KEY_PEM"):
            self.assertIsNone(e[leaked], leaked)
        self.assertFalse(e["ZAI_API_KEY"], "ключ — только как ANTHROPIC_AUTH_TOKEN")
        self.assertIn("--strict-mcp-config", seen["argv"])
        i = seen["argv"].index("--setting-sources")
        self.assertEqual(seen["argv"][i + 1], "")
        self.assertIn("Сейчас: ок.", r.stdout)

    def test_no_key_means_no_agent_at_all(self):
        r, seen, _ = self.run_heal({})
        self.assertIsNone(seen, "без ключа Z.AI раннер не запускается (и не уходит в подписку Claude)")
        self.assertIn("нет ключа Z.AI", r.stdout)

    def test_key_from_mac_config_file(self):
        tmp = tempfile.mkdtemp()
        os.makedirs(os.path.join(tmp, ".config", "poh-guardian"))
        with open(os.path.join(tmp, ".config", "poh-guardian", "guardian.env"), "w") as f:
            f.write("ZAI_API_KEY=from-file\n")
        r, seen, _ = self.run_heal({"HOME": tmp})
        self.assertEqual(seen["env"]["ANTHROPIC_AUTH_TOKEN"], "from-file")


if __name__ == "__main__":
    unittest.main()
