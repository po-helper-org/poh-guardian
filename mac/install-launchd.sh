#!/usr/bin/env bash
# Сторож на Mac: пинг раз в 2 минуты, пока Mac не спит. 2 провала подряд → mac/wake.sh (не чаще раза в 30 мин).
#   bash mac/install-launchd.sh            — поставить/обновить
#   bash mac/install-launchd.sh --remove   — снять
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
label="ru.aleksishmanov.poh-guardian"
plist="$HOME/Library/LaunchAgents/$label.plist"
state="$HOME/.local/state/poh-guardian"
if [ "${1:-}" = --remove ]; then
  for l in "$label" "$label-listen"; do launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true; done
  rm -f "$plist" "$HOME/Library/LaunchAgents/$label-listen.plist"; echo "сторож и слушатель задач сняты"; exit 0
fi
mkdir -p "$state" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$repo/probe/probe.py</string>
    <string>--reference</string><string>https://api.github.com/zen</string>
    <string>--loop-state</string><string>$state/mac.json</string>
    <string>--trigger-cmd</string><string>$repo/mac/wake.sh</string>
  </array>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/poh-guardian.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/poh-guardian.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "сторож стоит: $(launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -m1 'state =' | xargs)"
echo "журнал: tail -f ~/Library/Logs/poh-guardian.log"

# Слушатель задач: сообщение владельца в Telegram-боте → агент исполняет (agent/listen.py)
lplist="$HOME/Library/LaunchAgents/$label-listen.plist"
cat > "$lplist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label-listen</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>$repo/agent/listen.py</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/poh-guardian-listen.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/poh-guardian-listen.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$label-listen" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$lplist"
echo "слушатель задач стоит; журнал: tail -f ~/Library/Logs/poh-guardian-listen.log"
