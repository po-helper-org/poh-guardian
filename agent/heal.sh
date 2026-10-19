#!/usr/bin/env bash
# Один цикл хранителя: подтвердить сбой → 🚨 в Telegram → ИИ-агент чинит → ✅/⚠️ в Telegram →
# предложения вне белого списка — кнопками, по ✅ выполняются ключом approved.
# Одинаково работает в GitHub Actions (.github/workflows/heal.yml) и на Mac (руками или из сторожа).
#
# Окружение: GUARDIAN_REASON (почему разбудили), GUARDIAN_FORCE=1 (чинить, даже если пинг уже зелёный),
# GUARDIAN_SCENARIO=canary (учения: проверить и поднять канарейку), CLAUDE_BIN (по умолчанию claude),
# TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID, CLAUDE_CODE_OAUTH_TOKEN (в Actions).
set -uo pipefail
cd "$(dirname "$0")/.."
export GUARDIAN_STATE="${GUARDIAN_STATE:-$PWD/.state}"
mkdir -p "$GUARDIAN_STATE"; rm -f "$GUARDIAN_STATE/ssh_failures"
tg() { python3 agent/telegram.py "$@"; }
where="${GITHUB_RUN_ID:+GitHub Actions, прогон $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}"
[ "$(uname)" = Darwin ] && where="${where:-Mac владельца}"
where="${where:-$(uname -n)}"
reason="${GUARDIAN_REASON:-запуск вручную}"
scenario="${GUARDIAN_SCENARIO:-}"
started=$(date +%s)

probe_json=$(python3 probe/probe.py --json --gap 15); probe_rc=$?
owner_ip="${GUARDIAN_OWNER_IP:-}"
# Из облака всё отвечает, а у владельца нет → почти наверняка бан его IP fail2ban'ом (инцидент 2026-10-19 20:36).
if [ $probe_rc -eq 0 ] && [ -n "$owner_ip" ] && [ -z "$scenario" ]; then scenario=ban; fi
if [ $probe_rc -eq 0 ] && [ "${GUARDIAN_FORCE:-0}" != 1 ] && [ -z "$scenario" ]; then
  echo "пинг зелёный — сбой не подтвердился: $reason"
  tg send "ℹ️ Хранитель: тревога не подтвердилась (снаружи всё отвечает). Причина побудки: $reason" >/dev/null
  exit 0
fi

failed=$(python3 -c 'import json,sys; s=json.loads(sys.argv[1]); print("\n".join("• %s — %s" % (r["name"], r["error"] or "код %s" % r["code"]) for r in s["failed"]) or "• снаружи всё отвечает")' "$probe_json")
title="🚨 Сбой: разбираюсь"; [ "$scenario" = canary ] && title="🧪 Учения хранителя: канарейка"
[ "$scenario" = ban ] && title="🚫 У вас всё недоступно, из облака сервер отвечает — проверяю бан вашего IP $owner_ip"
tg send "$title
$failed
Побудка: $reason
Где работаю: $where" --id-file "$GUARDIAN_STATE/tg_start" >/dev/null

task="Причина побудки: $reason
Результат внешнего пинга (JSON): $probe_json"
if [ "$scenario" = canary ]; then
  task="$task
УЧЕНИЯ: снаружи всё может быть зелёным. Проверь канарейку — юнит poh-guardian-canary, http 8649 /healthz.
Если она не отвечает — найди доказательство в logs/units и подними её restart. Прод-сервисы не трогай."
fi
if [ "$scenario" = ban ]; then
  task="$task
БАН: у владельца (IP $owner_ip) сервер недоступен, а из облака отвечает. Проверь \`bans\`. Если $owner_ip забанен —
\`unban $owner_ip\`. Затем найди источник ошибок входа: \`syslog ssh 300\` (строки [preauth] с $owner_ip незадолго
до бана) и доложи, что их дало (обычно — короткий claude -p с SSH-MCP на Mac). Прод-сервисы не трогай."
fi
prompt="$(cat agent/prompt.md)

## Задача
$task"

claude_bin="${CLAUDE_BIN:-claude}"
# агенту — ни токена Telegram, ни ключа approved: только ./agent/g с ключом heal
env -u TELEGRAM_BOT_TOKEN -u GUARDIAN_APPROVED_KEY_PEM "$claude_bin" -p "$prompt" \
  --strict-mcp-config \
  --allowedTools "Bash(./agent/g:*)" \
  --disallowedTools "Read,Write,Edit,MultiEdit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,Task,Agent,TodoWrite" \
  --max-turns 40 --output-format json > "$GUARDIAN_STATE/run.json" 2> "$GUARDIAN_STATE/run.err"
claude_rc=$?
report=$(python3 -c '
import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("result") or "агент закончил без доклада (%s)" % d.get("subtype"))
except Exception as e:
    print("агент не запустился: %s" % e)' "$GUARDIAN_STATE/run.json")
[ $claude_rc -eq 0 ] || report="$report
(код claude $claude_rc: $(tail -c 300 "$GUARDIAN_STATE/run.err"))"

# предложения — вырезать из доклада в файл
printf '%s' "$report" > "$GUARDIAN_STATE/report_raw.txt"
python3 - "$GUARDIAN_STATE" <<'PY'
import json, re, sys
text = open(sys.argv[1] + "/report_raw.txt").read()
m = re.search(r"```proposals\s*(\[.*?\])\s*```", text, re.S)
props = []
if m:
    try:
        props = [p for p in json.loads(m.group(1)) if p.get("command")]
    except ValueError:
        pass
    text = text[:m.start()].rstrip()
open(sys.argv[1] + "/report.txt", "w").write(text)
json.dump(props, open(sys.argv[1] + "/proposals.json", "w"), ensure_ascii=False)
PY

python3 probe/probe.py --json --gap 0 > "$GUARDIAN_STATE/probe_after.json"; after_rc=$?
mins=$(( ($(date +%s) - started + 59) / 60 ))
if [ $after_rc -eq 0 ]; then head="✅ Работает снова (≈${mins} мин)"; else head="⚠️ Не всё поднялось (≈${mins} мин)"; fi
[ "$scenario" = canary ] && head="🧪 Учения: доклад агента (≈${mins} мин)"
tg send "$head

$(cat "$GUARDIAN_STATE/report.txt")" >/dev/null
echo "=== доклад ==="; cat "$GUARDIAN_STATE/report.txt"; echo

# действия вне белого списка — только по ✅ владельца
n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$GUARDIAN_STATE/proposals.json")
for ((i = 0; i < n; i++)); do
  q=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))[int(sys.argv[2])]; print("🛠 Предложение %d: %s\nКоманда: %s\nЗачем: %s\nРиск: %s" % (int(sys.argv[2])+1, p.get("title",""), p["command"], p.get("why",""), p.get("risk","")))' "$GUARDIAN_STATE/proposals.json" "$i")
  echo "$q"
  ans=$(tg ask "$q" --timeout "${GUARDIAN_ASK_TIMEOUT:-1800}")
  if [ "$ans" = yes ]; then
    cmd=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[int(sys.argv[2])]["command"])' "$GUARDIAN_STATE/proposals.json" "$i")
    out=$(./agent/approve-run "$cmd" 2>&1 | tail -c 1500)
    python3 probe/probe.py --gap 10 >/dev/null && st="снаружи всё отвечает" || st="снаружи ещё есть сбои"
    tg send "Выполнено: $cmd
$out
Пинг: $st" >/dev/null
  else
    echo "предложение $((i + 1)): $ans — не выполнено"
  fi
done
[ $after_rc -eq 0 ] || [ "$scenario" = canary ]
