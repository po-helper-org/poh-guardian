# poh-guardian — хранитель сервера dede

**Что это.** Когда система владельца (Инбокс, Matrix, виджеты на `harness.aleksishmanov.ru`) перестаёт
отвечать, хранитель:
1. замечает это снаружи;
2. пишет в отдельный Telegram-бот «🚨 Сбой — разбираюсь»;
3. сам заходит на сервер, находит причину и чинит в пределах белого списка;
4. докладывает «✅ Работает снова: что было, что сделал».

Всё, что вне белого списка, присылает кнопкой ✅/❌.

**Когда нужен.** Всегда. Почему он живёт вне сервера и почему так устроен — [ADR 0001](docs/adr/0001-guardian-outside-dede.md).

```
Mac (каждые 2 мин) ─┐                     ┌─ Telegram: 🚨 → доклад → ✅/❌
GitHub cron (3 ч)  ─┼─ probe.py ─сбой×2─▶ heal.sh ─ claude -p ─ ./agent/g ──SSH(ключ heal)──▶ guardian-shell на dede
руками (Actions)   ─┘                     └─ по ✅: approve-run ──SSH(ключ approved)──▶ команда под aleks
```

## Как пользоваться
- **Учения:** `ssh harness-mts 'systemctl --user stop poh-guardian-canary'` → GitHub → Actions → heal →
  Run workflow → `scenario=canary`. Через 2–4 мин в Telegram придёт доклад «канарейка поднята».
- **Разбудить руками:** `gh workflow run heal.yml -R po-helper-org/poh-guardian -f force=1 -f reason="…"`.
- **На Mac без GitHub:** `GUARDIAN_FORCE=1 ./agent/heal.sh`.

## Установка
| Что | Кто | Команда |
|---|---|---|
| Серверная часть (оболочка, `poh-restart`, канарейка, ключи) | агент | `rsync` репо в `~/Projects/poh-guardian`, `bash server/install.sh` (`--check`, `--remove`) |
| SSH-ключи в секреты GitHub | агент | `gh secret set GUARDIAN_HEAL_SSH_KEY < ~/.ssh/poh_guardian_heal` (и `…APPROVED…`) |
| Telegram-бот и токен Claude | **владелец**, ~5 мин | `bash wizard/setup-owner.sh` |
| Сторож на Mac | агент | `bash mac/install-launchd.sh` (`--remove`), журнал `~/Library/Logs/poh-guardian.log` |
| earlyoom (не дать серверу задохнуться в swap) | **владелец**, sudo | `bash server/install-earlyoom.sh` |

## Правило для всех сессий
Рестарт прод-юнита — через `poh-restart <юнит> --by "<сессия/зачем>" [--health URL]`. Обёртка ждёт active,
проверяет health и пишет след в `~/.local/state/poh-guardian/changes.jsonl`. По этому следу хранитель видит,
кто и что трогал перед сбоем.

## Разработка
`python3 -m unittest discover -s tests`. Python 3.9+ (Mac), сервер — 3.10, только stdlib.
Белый список юнитов и процессов — в `server/guardian-shell` (`RESTARTABLE`, `KILLABLE`). Ранбук агента —
`agent/prompt.md`, туда же дописывать новые известные причины из «Журнала инцидентов».
