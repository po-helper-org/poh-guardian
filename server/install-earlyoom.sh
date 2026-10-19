#!/usr/bin/env bash
# earlyoom: при нехватке памяти (≤4% RAM и ≤10% swap) убивает сначала тестовые браузеры и прогоны,
# а не Synapse/шлюзы — сервер не уходит в «swap 4/4, load 140, SSH без баннера» (инцидент 2026-10-07).
# Шаг владельца (sudo). Запуск: ssh -t harness-mts 'sudo bash ~/Projects/poh-guardian/server/install-earlyoom.sh'
#   --remove — снять
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "нужен sudo"; exit 1; }
if [ "${1:-}" = --remove ]; then systemctl disable --now earlyoom; echo "earlyoom выключен"; exit 0; fi
command -v earlyoom >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom
[ -f /etc/default/earlyoom ] && cp -n /etc/default/earlyoom /etc/default/earlyoom.bak-guardian
cat > /etc/default/earlyoom <<'EOF'
# poh-guardian (ADR 0001): сначала тестовые браузеры и прогоны, никогда — ядро системы
EARLYOOM_ARGS="-m 4 -s 10 -r 3600 --prefer '(^|/)(chrome|chromium|chrome-headless|chrome-headless-shell|Xvfb)$' --avoid '(^|/)(sshd|systemd|systemd-journal|nginx|python3|hermes|gotosocial|dockerd|containerd|Xvnc|xrdp|wg-quick|vpnagentd)$'"
EOF
systemctl enable earlyoom >/dev/null
systemctl restart earlyoom
sleep 2
systemctl is-active earlyoom && journalctl -u earlyoom -n 5 --no-pager
