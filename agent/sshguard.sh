# shellcheck shell=bash
# Общий предохранитель SSH для ./agent/g и ./agent/approve-run (подключать через source).
# fail2ban на dede (aggressive) банит IP на 24 ч после 3 событий за 10 мин. Мы разрешаем себе
# не больше 2 провалов за 10 мин — по одному файлу с отметками времени на машину, без сброса
# между прогонами и общему для обоих ключей.
GUARD_FILE="${GUARD_FILE:-$HOME/.local/state/poh-guardian/ssh_failures}"
GUARD_WINDOW=600
GUARD_MAX=2

guard_recent() { # число провалов за окно
  local now t n=0; now=$(date +%s)
  [ -f "$GUARD_FILE" ] || { echo 0; return; }
  while read -r t; do
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ $((now - t)) -lt $GUARD_WINDOW ] && n=$((n + 1))
  done < "$GUARD_FILE"
  echo "$n"
}

guard_check() { # 0 — можно стучаться
  local n; n=$(guard_recent)
  if [ "$n" -ge "$GUARD_MAX" ]; then
    echo "SSH недоступен: $n провала за 10 мин, новые попытки заблокированы до конца окна (fail2ban банит после 3)."
    return 1
  fi
}

guard_record() { # rc ssh → отметить провал соединения (255)
  [ "$1" -eq 255 ] || return 0
  mkdir -p "$(dirname "$GUARD_FILE")"
  date +%s >> "$GUARD_FILE"
  echo "[ssh: ошибка соединения, провалов за 10 мин: $(guard_recent) из $GUARD_MAX]"
}
