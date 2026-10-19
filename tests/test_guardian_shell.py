import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

PATH = os.path.join(os.path.dirname(__file__), "..", "server", "guardian-shell")
loader = importlib.machinery.SourceFileLoader("guardian_shell", PATH)
spec = importlib.util.spec_from_loader("guardian_shell", loader)
gs = importlib.util.module_from_spec(spec)
loader.exec_module(gs)


class HealModeTest(unittest.TestCase):
    def test_unknown_verb_refused(self):
        with self.assertRaises(gs.Refused):
            gs.run("heal", "rm -rf /")

    def test_shell_injection_is_just_unknown_verb(self):
        with self.assertRaises(gs.Refused):
            gs.run("heal", "overview; cat ~/.hermes/.env")

    def test_restart_outside_allowlist_refused(self):
        for unit in ("hermes-gateway", "repowise-mcp", "nginx", "ssh"):
            with self.assertRaises(gs.Refused, msg=unit):
                gs.run("heal", "restart " + unit)

    def test_logs_rejects_odd_unit_names(self):
        with self.assertRaises(gs.Refused):
            gs.run("heal", "logs '../../etc;id'")

    def test_http_rejects_bad_path(self):
        with self.assertRaises(gs.Refused):
            gs.run("heal", "http 8628 /x;id")

    def test_unban_validates_ip(self):
        for bad in ("1.2.3", "1.2.3.4; id", "300.1.1.1", "--all"):
            with self.assertRaises(gs.Refused, msg=bad):
                gs.run("heal", "unban " + bad)

    def test_empty_mode_refused(self):
        with self.assertRaises(gs.Refused):
            gs.run("", "overview")


class RestartBudgetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        gs.STATE = self.tmp
        gs.RESTARTS = os.path.join(self.tmp, "restarts.json")

    def test_three_per_hour_then_refuse(self):
        for t in (0, 10, 20):
            gs._restart_budget("poh-widget-inbox", 1000 + t)
        with self.assertRaises(gs.Refused):
            gs._restart_budget("poh-widget-inbox", 1030)
        gs._restart_budget("poh-widget-inbox", 1000 + 3601)  # старые вышли из окна


class KillableTest(unittest.TestCase):
    def test_test_browser_old_enough(self):
        ok, _ = gs.killable("/opt/chrome --user-data-dir=/tmp/pw-test-home", 1000, 3600, 1000)
        self.assertTrue(ok)

    def test_young_process_spared(self):
        ok, why = gs.killable("node prod-check.mjs", 1000, 120, 1000)
        self.assertFalse(ok)
        self.assertIn("10 минут", why)

    def test_service_never_killed(self):
        ok, _ = gs.killable("python3 -m synapse.app.homeserver --user-data-dir=/tmp/x", 1000, 9999, 1000)
        self.assertFalse(ok)

    def test_other_user_spared(self):
        ok, _ = gs.killable("chrome --user-data-dir=/tmp/x", 0, 9999, 1000)
        self.assertFalse(ok)

    def test_production_chrome_not_matched(self):
        ok, _ = gs.killable("/opt/google/chrome/chrome --user-data-dir=/home/kasm-user/profile", 1000, 9999, 1000)
        self.assertFalse(ok)


class ApprovedGuardTest(unittest.TestCase):
    def test_secrets_refused(self):
        for cmd in ("cat ~/.hermes/.env", "cat ~/.config/corp-link/bot.env", "cat /proc/123/environ",
                    "less ~/.ssh/authorized_keys", "printenv"):
            with self.assertRaises(gs.Refused, msg=cmd):
                gs.guard_secret(cmd)

    def test_sudo_and_pkill_f_refused(self):
        for cmd in ("sudo systemctl restart nginx", "pkill -f run-bridge.py"):
            with self.assertRaises(gs.Refused, msg=cmd):
                gs.guard_secret(cmd)

    def test_normal_command_passes(self):
        gs.guard_secret("systemctl --user restart hermes-gateway")


class RedactTest(unittest.TestCase):
    def test_redacts_tokens(self):
        s = gs.redact('token=abc123 Authorization: Bearer xyz.789 key ghp_ABCDEFGHIJKLMNOP')
        self.assertNotIn("abc123", s)
        self.assertNotIn("xyz.789", s)
        self.assertNotIn("ghp_ABCDEFGH", s)

    def test_keeps_normal_log_lines(self):
        line = "Oct 19 19:54:38 dede systemd[15055]: poh-widget-inbox.service: Consumed 5min CPU time."
        self.assertEqual(gs.redact(line), line)


if __name__ == "__main__":
    unittest.main()
