#!/usr/bin/env bash
# Установка серверной части хранителя под aleks (без sudo). Идемпотентно.
#   bash server/install.sh            — поставить/обновить
#   bash server/install.sh --check    — проверить, что всё на месте
#   bash server/install.sh --remove   — снять ключи хранителя (оболочка и журнал остаются)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stamp="$(date +%Y%m%d%H%M%S)"
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

# Переписать authorized_keys атомарно: без строк, где есть $1, плюс строка $2 (может быть пустой).
# Любая ошибка чтения или «потеря» чужих ключей — отказ, файл не трогаем.
rewrite_ak() {
  local drop="$1" add="${2:-}" tmp before kept rc
  [ -f "$ak" ] || { echo "нет $ak — не трогаю"; return 1; }
  tmp="$(mktemp "$ak.guardian.XXXXXX")"
  rc=0; grep -vF -- "$drop" "$ak" > "$tmp" || rc=$?
  [ $rc -le 1 ] || { rm -f "$tmp"; echo "ошибка чтения $ak (grep $rc) — не трогаю"; return 1; }
  before=$(grep -cvF -- "$drop" "$ak" || true); kept=$(wc -l < "$tmp" | tr -d ' ')
  [ "$kept" -eq "$before" ] || { rm -f "$tmp"; echo "строк $kept ≠ $before — не трогаю"; return 1; }
  [ -n "$add" ] && printf '%s\n' "$add" >> "$tmp"
  [ -e "$ak.bak-guardian-$stamp" ] || cp -p "$ak" "$ak.bak-guardian-$stamp"   # один «до» на запуск
  chmod 600 "$tmp" && mv -f "$tmp" "$ak"
}

remove() {
  rewrite_ak 'guardian-shell ' && echo "ключи хранителя сняты (бэкап рядом)"
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

for m in heal approved; do
  pub="$here/keys/$m.pub"
  [ -f "$pub" ] || { echo "нет $pub — пропускаю ключ $m"; continue; }
  line="$(key_line "$m" "$pub")"
  grep -qxF "$line" "$ak" && continue
  rewrite_ak "guardian-shell $m\" " "$line"
done
check
