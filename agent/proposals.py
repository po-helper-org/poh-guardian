#!/usr/bin/env python3
"""Вырезать из доклада агента блок ```proposals [...]``` и проверить его.

  proposals.py split <state_dir>   # report_raw.txt → report.txt + proposals.json; печатает число предложений
  proposals.py show <file> <i>     # текст вопроса владельцу
  proposals.py cmd <file> <i>      # команда предложения i

Ошибки разбора не глотаются: в доклад дописывается строка «⚠️ предложения агента не разобраны: …».
"""
import json
import re
import sys

BLOCK = re.compile(r"```proposals\s*(.*?)```", re.S)


def split(text):
    """(доклад без блока, [предложения], [замечания])."""
    m = BLOCK.search(text)
    if not m:
        return text.rstrip(), [], []
    body, notes, props = m.group(1).strip(), [], []
    text = (text[:m.start()] + text[m.end():]).rstrip()
    try:
        items = json.loads(body)
    except ValueError as e:
        return text, [], ["⚠️ предложения агента не разобраны (не JSON: %s) — смотрите следы прогона" % e]
    if not isinstance(items, list):
        items = [items]
    for i, p in enumerate(items, 1):
        if isinstance(p, dict) and isinstance(p.get("command"), str) and p["command"].strip():
            props.append({k: str(p.get(k, "")) for k in ("title", "command", "why", "risk")})
        else:
            notes.append("⚠️ предложение %d отброшено: нет поля command" % i)
    return text, props, notes


def question(p, i):
    return "🛠 Предложение %d: %s\nКоманда: %s\nЗачем: %s\nРиск: %s" % (
        i + 1, p["title"], p["command"], p["why"], p["risk"])


def main(argv):
    if argv[0] == "split":
        d = argv[1]
        with open(d + "/report_raw.txt") as f:
            text, props, notes = split(f.read())
        with open(d + "/report.txt", "w") as f:
            f.write("\n\n".join([text] + notes) if notes else text)
        with open(d + "/proposals.json", "w") as f:
            json.dump(props, f, ensure_ascii=False)
        print(len(props))
        return 0
    with open(argv[1]) as f:
        p = json.load(f)[int(argv[2])]
    print(question(p, int(argv[2])) if argv[0] == "show" else p["command"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
