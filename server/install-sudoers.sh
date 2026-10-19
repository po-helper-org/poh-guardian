#!/usr/bin/env bash
# Шаг владельца (sudo): разрешить хранителю под aleks ТОЛЬКО смотреть и снимать бан fail2ban в jail sshd.
# Запуск: ssh -t harness-mts 'sudo bash ~/Projects/poh-guardian/server/install-sudoers.sh'   (--remove — снять)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен sudo"; exit 1; }
f=/etc/sudoers.d/poh-guardian
if [ "${1:-}" = --remove ]; then rm -f "$f"; echo "правило снято"; exit 0; fi
tmp=$(mktemp)
cat > "$tmp" <<'RULE'
# poh-guardian (ADR 0001): хранитель снимает бан IP владельца, ничего больше
aleks ALL=(root) NOPASSWD: /usr/bin/fail2ban-client status sshd, /usr/bin/fail2ban-client set sshd unbanip *
RULE
visudo -cf "$tmp" && install -m 440 -o root -g root "$tmp" "$f" && rm -f "$tmp"
sudo -u aleks sudo -n /usr/bin/fail2ban-client status sshd | head -3
