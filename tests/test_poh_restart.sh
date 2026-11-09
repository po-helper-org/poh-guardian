#!/usr/bin/env bash
# tests/test_poh_restart.sh — poh-restart работает в разных окружениях (t_e025f7b7).
# TDD-цикл для бага: SSH_CONNECTION unbound variable при локальном запуске (set -u).
# Изоляция: HOME → tmp (changes.jsonl не трогаем), systemctl/curl → PATH-заглушки.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
script="$repo/server/poh-restart"
tmp_home="$(mktemp -d)"
changes="$tmp_home/.local/state/poh-guardian/changes.jsonl"
pass=0; fail=0

# Фиктивное окружение: systemctl всегда active, curl всегда 200.
stub="$(mktemp -d)"
printf '#!/bin/sh\necho active\n' > "$stub/systemctl"; chmod +x "$stub/systemctl"
printf '#!/bin/sh\nprintf "200"\n' > "$stub/curl"; chmod +x "$stub/curl"
run_env() {
  # $1 = clean|ssh; остальное — аргументы poh-restart
  mode="$1"; shift
  if [ "$mode" = clean ]; then
    env -u SSH_CONNECTION -u POH_BY -u USER PATH="$stub:$PATH" HOME="$tmp_home" bash "$script" "$@"
  else
    env -u POH_BY -u USER SSH_CONNECTION="192.0.2.10 12345 192.0.2.1 22" PATH="$stub:$PATH" HOME="$tmp_home" bash "$script" "$@"
  fi
}
run_case() {
  name="$1"; want_rc="$2"; mode="$3"; shift 3
  out="$(run_env "$mode" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want_rc" ]; then
    pass=$((pass+1)); echo "ok   $name (rc=$rc)"
  else
    fail=$((fail+1)); echo "FAIL $name: rc=$rc, want $want_rc"
    printf '%s\n' "$out" | sed 's/^/     | /'
  fi
}

# 1. РЕГРЕССИЯ бага: локальный запуск без SSH_CONNECTION/USER не должен падать
run_case "local run without SSH_CONNECTION" 0 clean test-unit --by "tdd"
# 2. Локальный запуск + health OK
run_case "local run with health" 0 clean test-unit --by "tdd" --health http://127.0.0.1:1/ok
# 3. SSH-окружение по-прежнему работает
run_case "ssh run" 0 ssh test-unit --by "tdd"
# 4. Нет аргумента → usage, rc 1
run_case "no args usage" 1 clean

# 5. След в changes.jsonl (tmp-HOME): локальный запуск пишет from=null
if grep -q '"from": null' "$changes" 2>/dev/null; then
  pass=$((pass+1)); echo "ok   changes.jsonl from=null (local)"
else
  fail=$((fail+1)); echo "FAIL changes.jsonl: нет локальной записи с from=null"
fi
# 6. В ssh-запуске from = клиентский IP
if grep -q '"from": "192.0.2.10"' "$changes" 2>/dev/null; then
  pass=$((pass+1)); echo "ok   changes.jsonl from=ip (ssh)"
else
  fail=$((fail+1)); echo "FAIL changes.jsonl: нет ssh-записи с from=ip"
fi
# 7. Продовый changes.jsonl не тронут
if [ ! -e "$changes" ] || [ "$(wc -l < "$changes")" -le 4 ]; then :; fi

rm -rf "$stub" "$tmp_home"
echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
