#!/usr/bin/env python3
"""Внешний пинг: доступна ли система снаружи.

Только stdlib, Python 3.9+ (Mac — 3.9, раннер GitHub — 3.12).
Проверяет HTTPS-адреса из checks.json; упавшие перепроверяет через `--gap` секунд,
чтобы короткий рестарт сервиса не будил агента.

  probe.py                       # человекочитаемо, код 1 — есть сбои
  probe.py --json                # JSON для workflow
  probe.py --loop-state F --trigger-cmd "…"   # режим сторожа на Mac (см. mac/)
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # 302 — это ответ, а не переход
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_status(url, timeout):
    """(код | None, ошибка | None). Без переходов по редиректу."""
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "poh-guardian-probe/1"})
    try:
        with _OPENER.open(req, timeout=timeout) as resp:
            return resp.status, None
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception as e:  # таймаут, DNS, отказ соединения, TLS
        return None, "%s: %s" % (type(e).__name__, e)


def run_checks(checks, fetch=http_status, timeout=15):
    results = []
    for c in checks:
        code, err = fetch(c["url"], c.get("timeout", timeout))
        ok = err is None and code in c["expect"]
        results.append({"name": c["name"], "url": c["url"], "ok": ok, "code": code,
                        "error": err, "expect": c["expect"]})
    return results


def probe(checks, fetch=http_status, gap=20, sleep=time.sleep):
    """Проверить; упавшие — ещё раз через gap секунд. Сбой = упал оба раза."""
    first = run_checks(checks, fetch)
    failed = [c for c, r in zip(checks, first) if not r["ok"]]
    if not failed or gap <= 0:
        return first
    sleep(gap)
    second = {r["url"]: r for r in run_checks(failed, fetch)}
    return [second.get(r["url"], r) for r in first]


def network_ok(url, fetch=http_status):
    """Есть ли интернет у самого наблюдателя (Mac без сети ≠ сервер лежит)."""
    code, err = fetch(url, 10)
    return err is None and code is not None and code < 500


def summary(results):
    bad = [r for r in results if not r["ok"]]
    return {"ok": not bad, "total": len(results), "failed": bad,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z")}


def describe(r):
    got = r["error"] or ("код %s" % r["code"])
    return "%s — %s (ждали %s)" % (r["name"], got, "/".join(map(str, r["expect"])))


# --- режим сторожа (Mac): решение «будить ли агента» отдельно, чтобы тестировать ---

def decide(state, ok, now, need=2, cooldown=1800):
    """Вернуть (новое состояние, будить_ли). Будим после `need` провалов подряд, не чаще cooldown."""
    state = dict(state or {})
    if ok:
        state["fails"] = 0
        return state, False
    state["fails"] = state.get("fails", 0) + 1
    last = state.get("last_trigger")
    if state["fails"] >= need and (last is None or now - last >= cooldown):
        state["last_trigger"] = now
        return state, True
    return state, False


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--checks", default=os.path.join(HERE, "checks.json"))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--gap", type=int, default=20)
    ap.add_argument("--loop-state", help="файл состояния сторожа (провалы подряд, последний вызов)")
    ap.add_argument("--trigger-cmd", help="команда, будящая агента; причина — в $GUARDIAN_REASON")
    ap.add_argument("--need", type=int, default=2)
    ap.add_argument("--cooldown", type=int, default=1800)
    ap.add_argument("--reference", help="адрес для проверки своей сети (напр. https://api.github.com/zen)")
    a = ap.parse_args(argv)

    if a.reference and not network_ok(a.reference):
        print("нет интернета у наблюдателя — пропуск (%s)" % a.reference)
        return 3

    with open(a.checks) as f:
        checks = json.load(f)["checks"]
    s = summary(probe(checks, gap=a.gap))

    if a.json:
        print(json.dumps(s, ensure_ascii=False))
    else:
        print("OK: все %d проверок" % s["total"] if s["ok"] else
              "СБОЙ:\n" + "\n".join("  " + describe(r) for r in s["failed"]))

    if a.loop_state:
        state, wake = decide(_load(a.loop_state), s["ok"], time.time(), a.need, a.cooldown)
        _save(a.loop_state, state)
        if wake and a.trigger_cmd:
            reason = "; ".join(describe(r) for r in s["failed"])
            env = dict(os.environ, GUARDIAN_REASON=reason)
            rc = subprocess.call(shlex.split(a.trigger_cmd), env=env)
            print("агент разбужен (код %s): %s" % (rc, reason), file=sys.stderr)
    return 0 if s["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
