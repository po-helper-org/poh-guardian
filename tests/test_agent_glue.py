import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "agent"))
import proposals  # noqa: E402


class ProposalsTest(unittest.TestCase):
    def test_no_block(self):
        self.assertEqual(proposals.split("доклад\n"), ("доклад", [], []))

    def test_valid_block_removed_from_report(self):
        text = 'Что было: x\n```proposals\n[{"title": "t", "command": "systemctl --user restart hermes-gateway"}]\n```\n'
        report, props, notes = proposals.split(text)
        self.assertEqual(report, "Что было: x")
        self.assertEqual(props[0]["command"], "systemctl --user restart hermes-gateway")
        self.assertEqual(props[0]["risk"], "")
        self.assertEqual(notes, [])

    def test_invalid_json_is_reported_not_swallowed(self):
        report, props, notes = proposals.split("доклад\n```proposals\n[{oops}]\n```")
        self.assertEqual(props, [])
        self.assertIn("не разобраны", notes[0])
        self.assertEqual(report, "доклад")

    def test_malformed_item_dropped_with_note(self):
        _, props, notes = proposals.split('```proposals\n[{"title": "без команды"}, "строка", {"command": "ls"}]\n```')
        self.assertEqual([p["command"] for p in props], ["ls"])
        self.assertEqual(len(notes), 2)


class SshGuardTest(unittest.TestCase):
    """agent/sshguard.sh: не больше 2 провалов за 10 минут — общий счётчик для g и approve-run."""

    def run_guard(self, script, guard_file):
        lib = os.path.join(HERE, "..", "agent", "sshguard.sh")
        return subprocess.run(["bash", "-c", ". %s; %s" % (lib, script)], capture_output=True, text=True,
                              env=dict(os.environ, GUARD_FILE=guard_file))

    def test_two_failures_block_third_attempt(self):
        f = os.path.join(tempfile.mkdtemp(), "fails")
        self.assertEqual(self.run_guard("guard_check", f).returncode, 0)
        self.run_guard("guard_record 255; guard_record 0; guard_record 255", f)
        r = self.run_guard("guard_check", f)
        self.assertEqual(r.returncode, 1)
        self.assertIn("заблокированы", r.stdout)

    def test_old_failures_expire(self):
        f = os.path.join(tempfile.mkdtemp(), "fails")
        with open(f, "w") as fh:
            fh.write("1000\n2000\nмусор\n")
        self.assertEqual(self.run_guard("guard_check", f).returncode, 0)


if __name__ == "__main__":
    unittest.main()
