#!/usr/bin/env bash
# Установка серверной части хранителя под aleks (без sudo). Идемпотентно.
#   bash server/install.sh            — поставить/обновить
#   bash server/install.sh --check    — проверить, что всё на месте
#   bash server/install.sh --remove   — снять ключи хранителя (оболочка и журнал остаются)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
bin="$HOME/.local/bin"; ak="$HOME/.ssh/authorized_keys"
canary="$HOME/.local/share/poh-guardian/canary"; unitdir="$HOME/.config/systemd/user"

key_line() { # mode pubfile
  printf 'restrict,command="%s/guardian-shell %s" %s\n' "$bin" "$1" "$(cut -d' ' -f1,2 "$2") poh-guardian-$1"
}

check() {
  local bad=0
  for f in guardian-shell poh-restart; do
    cmp -s "$here/$f" "$bin/$f" && echo "ok   $bin/$f" || { echo "FAIL $bin/$f отличается/нет"; bad=1; }
  done
  for m in heal approved; do
    grep -qF "guardian-shell $m\" " "$ak" && echo "ok   ключ $m в authorized_keys" || { echo "FAIL ключа $m нет"; bad=1; }
  done
  [ "$(systemctl --user is-enabled poh-guardian-canary 2>/dev/null)" = enabled ] \
    && echo "ok   канарейка: $(systemctl --user is-active poh-guardian-canary)" || { echo "FAIL канарейка не включена"; bad=1; }
  return $bad
}

remove() {
  cp -p "$ak" "$ak.bak-guardian-$(date +%Y%m%d%H%M%S)"
  grep -vF 'guardian-shell ' "$ak" > "$ak.tmp" && cat "$ak.tmp" > "$ak" && rm -f "$ak.tmp"
  echo "ключи хранителя сняты (бэкап рядом)"
}

case "${1:-}" in
  --check) check; exit ;;
  --remove) remove; exit ;;
esac

mkdir -p "$bin" "$canary" "$unitdir" "$HOME/.local/state/poh-guardian"
install -m 755 "$here/guardian-shell" "$bin/guardian-shell"
install -m 755 "$here/poh-restart" "$bin/poh-restart"
echo ok > "$canary/healthz"
install -m 644 "$here/poh-guardian-canary.service" "$unitdir/poh-guardian-canary.service"
systemctl --user daemon-reload
systemctl --user enable --now poh-guardian-canary >/dev/null 2>&1 || true

changed=0
for m in heal approved; do
  pub="$here/keys/$m.pub"
  [ -f "$pub" ] || { echo "нет $pub — пропускаю ключ $m"; continue; }
  line="$(key_line "$m" "$pub")"
  grep -qxF "$line" "$ak" && continue
  [ $changed = 1 ] || cp -p "$ak" "$ak.bak-guardian-$(date +%Y%m%d%H%M%S)"
  grep -vF "guardian-shell $m\" " "$ak" > "$ak.tmp" || true
  echo "$line" >> "$ak.tmp"; cat "$ak.tmp" > "$ak"; rm -f "$ak.tmp"; changed=1
done
check
