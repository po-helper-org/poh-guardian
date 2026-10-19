#!/usr/bin/env bash
# Один цикл хранителя: подтвердить сбой → 🚨 в Telegram → ИИ-агент чинит → ✅/⚠️ в Telegram →
# предложения вне белого списка — кнопками, по ✅ выполняются ключом approved.
# Одинаково работает в GitHub Actions (.github/workflows/heal.yml) и на Mac (руками или из сторожа).
#
# Окружение: GUARDIAN_REASON (почему разбудили), GUARDIAN_FORCE=1 (чинить, даже если пинг уже зелёный),
# GUARDIAN_SCENARIO=canary (учения: проверить и поднять канарейку), CLAUDE_BIN (по умолчанию claude),
# TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID, ZAI_API_KEY (GLM Coding Plan; на Mac — из ~/.config/poh-guardian/guardian.env).
# Модель — GLM (Z.AI) через Claude Code CLI с ANTHROPIC_BASE_URL; подписка Claude владельца не используется никогда:
# CLI запускается с пустым CLAUDE_CONFIG_DIR (нет входа) и без CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY.
set -uo pipefail
cd "$(dirname "$0")/.."
export GUARDIAN_STATE="${GUARDIAN_STATE:-$PWD/.state}"
mkdir -p "$GUARDIAN_STATE"
# один прогон за раз на машину (на Mac сторож может разбудить снова, пока ждём кнопку)
lock="$HOME/.local/state/poh-guardian/heal.lock"; mkdir -p "$(dirname "$lock")"
if ! mkdir "$lock" 2>/dev/null; then
  pid="$(cat "$lock/pid" 2>/dev/null)"
  age=$(( $(date +%s) - $(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock") ))
  # занят: живой pid или pid ещё не записан, а замку меньше 90 мин
  if { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || { [ -z "$pid" ] && [ "$age" -lt 5400 ]; }; then
    echo "хранитель уже работает — выхожу"; exit 0
  fi
  rm -rf "$lock"; mkdir "$lock" || exit 0
fi
echo $$ > "$lock/pid"; trap 'rm -rf "$lock"' EXIT
cfg="$HOME/.config/poh-guardian/guardian.env"
if [ -z "${ZAI_API_KEY:-}" ] && [ -f "$cfg" ]; then set -a; . "$cfg"; set +a; fi
tg() { python3 agent/telegram.py "$@"; }
probe() { ${GUARDIAN_PROBE:-python3 probe/probe.py} "$@"; }   # подмена — только для тестов
where="${GITHUB_RUN_ID:+GitHub Actions, прогон $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}"
[ "$(uname)" = Darwin ] && where="${where:-Mac владельца}"
where="${where:-$(uname -n)}"
reason="${GUARDIAN_REASON:-запуск вручную}"
scenario="${GUARDIAN_SCENARIO:-}"
started=$(date +%s)

probe_json=$(probe --json --gap 15); probe_rc=$?
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
glm_home="$GUARDIAN_STATE/claude-home"; mkdir -p "$glm_home"   # пустой: входа Claude владельца тут нет
# агенту — ни токена Telegram, ни ключа approved: только ./agent/g с ключом heal;
# без MCP (оборванные SSH-MCP = бан fail2ban) и без пользовательских CLAUDE.md/хуков (--setting-sources "")
if [ -z "${ZAI_API_KEY:-}" ]; then
  echo '{"result": "агент не запущен: нет ключа Z.AI (ZAI_API_KEY) — запустите wizard/setup-owner.sh"}' > "$GUARDIAN_STATE/run.json"
  : > "$GUARDIAN_STATE/run.err"; claude_rc=1
else
env -u TELEGRAM_BOT_TOKEN -u GUARDIAN_APPROVED_KEY_PEM -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY \
    CLAUDE_CONFIG_DIR="$glm_home" ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic" \
    ANTHROPIC_AUTH_TOKEN="$ZAI_API_KEY" ANTHROPIC_MODEL="${GUARDIAN_MODEL:-glm-5.3}" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="${GUARDIAN_MODEL:-glm-5.3}" ANTHROPIC_DEFAULT_SONNET_MODEL="${GUARDIAN_MODEL:-glm-5.3}" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5.3-flash" API_TIMEOUT_MS=600000 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    ZAI_API_KEY= \
  "$claude_bin" -p "$prompt" \
  --strict-mcp-config --setting-sources "" --permission-mode default \
  --allowedTools "Bash(./agent/g:*)" \
  --disallowedTools "Read,Write,Edit,MultiEdit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,Task,Agent,TodoWrite" \
  --max-turns 40 --output-format json > "$GUARDIAN_STATE/run.json" 2> "$GUARDIAN_STATE/run.err"
claude_rc=$?
fi
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
n=$(python3 agent/proposals.py split "$GUARDIAN_STATE") || { n=0; cp "$GUARDIAN_STATE/report_raw.txt" "$GUARDIAN_STATE/report.txt"; echo '[]' > "$GUARDIAN_STATE/proposals.json"; }

probe --json --gap 0 > "$GUARDIAN_STATE/probe_after.json"; after_rc=$?
mins=$(( ($(date +%s) - started + 59) / 60 ))
if [ $after_rc -eq 0 ]; then head="✅ Работает снова (≈${mins} мин)"; else head="⚠️ Не всё поднялось (≈${mins} мин)"; fi
[ "$scenario" = canary ] && head="🧪 Учения: доклад агента (≈${mins} мин)"
tg send "$head

$(cat "$GUARDIAN_STATE/report.txt")" >/dev/null
echo "=== доклад ==="; cat "$GUARDIAN_STATE/report.txt"; echo

# действия вне белого списка — только по ✅ владельца
for ((i = 0; i < n; i++)); do
  q=$(python3 agent/proposals.py show "$GUARDIAN_STATE/proposals.json" "$i")
  echo "$q"
  ans=$(tg ask "$q" --timeout "${GUARDIAN_ASK_TIMEOUT:-1800}")
  if [ "$ans" = yes ]; then
    cmd=$(python3 agent/proposals.py cmd "$GUARDIAN_STATE/proposals.json" "$i")
    out=$(./agent/approve-run "$cmd" 2>&1 | tail -c 1500)
    probe --gap 10 >/dev/null && st="снаружи всё отвечает" || st="снаружи ещё есть сбои"
    tg send "Выполнено: $cmd
$out
Пинг: $st" >/dev/null
  else
    echo "предложение $((i + 1)): $ans — не выполнено"
  fi
done
[ $after_rc -eq 0 ] || [ "$scenario" = canary ]
