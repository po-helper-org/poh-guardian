import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "probe"))
import probe  # noqa: E402

CHECKS = [
    {"name": "A", "url": "https://a/", "expect": [200]},
    {"name": "B", "url": "https://b/", "expect": [302]},
]


class FakeFetch:
    def __init__(self, answers):
        self.answers = {k: list(v) for k, v in answers.items()}
        self.calls = []

    def __call__(self, url, timeout):
        self.calls.append(url)
        return self.answers[url].pop(0)


class ProbeTest(unittest.TestCase):
    def test_all_ok_no_recheck(self):
        f = FakeFetch({"https://a/": [(200, None)], "https://b/": [(302, None)]})
        s = probe.summary(probe.probe(CHECKS, fetch=f, sleep=lambda _: None))
        self.assertTrue(s["ok"])
        self.assertEqual(f.calls, ["https://a/", "https://b/"])

    def test_short_blip_is_not_failure(self):
        # Рестарт сервиса: первый раз 502, через gap — 200. Агента не будим.
        f = FakeFetch({"https://a/": [(502, None), (200, None)], "https://b/": [(302, None)]})
        s = probe.summary(probe.probe(CHECKS, fetch=f, sleep=lambda _: None))
        self.assertTrue(s["ok"])
        self.assertEqual(f.calls, ["https://a/", "https://b/", "https://a/"])

    def test_persistent_failure_reported_with_reason(self):
        f = FakeFetch({"https://a/": [(None, "timeout"), (None, "timeout")], "https://b/": [(302, None)]})
        s = probe.summary(probe.probe(CHECKS, fetch=f, sleep=lambda _: None))
        self.assertFalse(s["ok"])
        self.assertEqual([r["name"] for r in s["failed"]], ["A"])
        self.assertIn("timeout", probe.describe(s["failed"][0]))

    def test_unexpected_code_is_failure(self):
        f = FakeFetch({"https://a/": [(200, None)], "https://b/": [(200, None), (200, None)]})
        s = probe.summary(probe.probe(CHECKS, fetch=f, sleep=lambda _: None))
        self.assertIn("ждали 302", probe.describe(s["failed"][0]))


class NetworkTest(unittest.TestCase):
    def test_reference_down_means_no_network(self):
        self.assertFalse(probe.network_ok("https://r/", fetch=lambda u, t: (None, "URLError")))
        self.assertTrue(probe.network_ok("https://r/", fetch=lambda u, t: (200, None)))


class DecideTest(unittest.TestCase):
    def test_wakes_after_two_fails_then_cooldown(self):
        st, wake = probe.decide({}, False, now=1000)
        self.assertFalse(wake)
        st, wake = probe.decide(st, False, now=1120)
        self.assertTrue(wake)
        st, wake = probe.decide(st, False, now=1240)
        self.assertFalse(wake, "в пределах cooldown не будим повторно")
        st, wake = probe.decide(st, False, now=1120 + 1800)
        self.assertTrue(wake)

    def test_ok_resets_counter(self):
        st, _ = probe.decide({}, False, now=1)
        st, _ = probe.decide(st, True, now=2)
        st, wake = probe.decide(st, False, now=3)
        self.assertFalse(wake)
        self.assertEqual(st["fails"], 1)


if __name__ == "__main__":
    unittest.main()
