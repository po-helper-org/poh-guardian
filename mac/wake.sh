#!/usr/bin/env bash
# Разбудить агента (зовёт сторож Mac, причина — в $GUARDIAN_REASON).
# Сначала — прогон в GitHub Actions (там токены и ключи); не вышло или Claude там ещё не настроен —
# разбор прямо на Mac (claude владельца, ключ ~/.ssh/poh_guardian_heal).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
reason="${GUARDIAN_REASON:-сторож Mac}"
log() { echo "$(date '+%F %T') wake: $*"; }
if gh secret list -R po-helper-org/poh-guardian 2>/dev/null | grep -q '^CLAUDE_CODE_OAUTH_TOKEN' \
   && gh workflow run heal.yml -R po-helper-org/poh-guardian -f reason="$reason (сторож Mac)" 2>/dev/null; then
  log "прогон в Actions запущен: $reason"
  exit 0
fi
log "Actions недоступен или не настроен — разбираю на Mac: $reason"
[ -f "$HOME/.config/poh-guardian/telegram.env" ] && set -a && . "$HOME/.config/poh-guardian/telegram.env" && set +a
GUARDIAN_REASON="$reason (сторож Mac, локально)" GUARDIAN_STATE="$HOME/.local/state/poh-guardian/run" \
  nohup "$repo/agent/heal.sh" >> "$HOME/Library/Logs/poh-guardian-heal.log" 2>&1 &
