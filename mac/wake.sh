#!/usr/bin/env bash
# Разбудить агента (зовёт сторож Mac, причина — в $GUARDIAN_REASON).
# Сначала — прогон в GitHub Actions (там токены и ключи); не вышло или Claude там ещё не настроен —
# разбор прямо на Mac (тот же раннер на GLM с ключом из ~/.config/poh-guardian/guardian.env; вход Claude владельца не трогается).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
reason="${GUARDIAN_REASON:-сторож Mac}"
log() { echo "$(date '+%F %T') wake: $*"; }
# свой внешний IP — чтобы агент из облака проверил, не забанен ли он fail2ban'ом
ip=$(curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | sed -n 's/^ip=//p')
if gh secret list -R po-helper-org/poh-guardian 2>/dev/null | grep -q '^ZAI_API_KEY' \
   && gh workflow run heal.yml -R po-helper-org/poh-guardian -f reason="$reason (сторож Mac)" -f owner_ip="$ip" 2>/dev/null; then
  log "прогон в Actions запущен: $reason"
  exit 0
fi
log "Actions недоступен или не настроен — разбираю на Mac: $reason"
for f in "$HOME/.config/poh-guardian/telegram.env" "$HOME/.config/poh-guardian/guardian.env"; do
  [ -f "$f" ] && { set -a; . "$f"; set +a; }
done
GUARDIAN_REASON="$reason (сторож Mac, локально)" GUARDIAN_STATE="$HOME/.local/state/poh-guardian/run" \
  nohup "$repo/agent/heal.sh" >> "$HOME/Library/Logs/poh-guardian-heal.log" 2>&1 &
