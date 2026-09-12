#!/usr/bin/env python3
"""Сверка обращений вида `Тип.имя` с тем, что в этом типе объявлено.

ЗАЧЕМ. Половина исходников тянет AppKit, и на Linux они не типизируются
вовсе: `swiftc -parse` видит только синтаксис, `run-tests.sh` собирает
лишь файлы без AppKit. Значит переименование поля ловится не здесь,
а сборкой в CI - через несколько минут и в чужом логе.

Случай, ради которого это написано (12.09.2026): настройку переименовали
из `showProjects` в `showSpendByChat`, одно обращение осталось висеть
в MenuBar.swift. Тесты зелёные, `-parse` чист, снимок меню в CI упал.

ЧТО ЭТО НЕ ДЕЛАЕТ. Это не проверка типов и не замена сборке: сверяются
только имена членов у горстки своих типов, перечисленных ниже. Ошибку
в типе аргумента или в порядке параметров она не увидит.
"""
import re
import sys
import glob
import os

# Типы, у которых члены объявлены в одном файле и зовутся по имени типа.
# Список нарочно короткий: сюда попадает то, что переименовывают руками
# и зовут из AppKit-файлов, а не всё подряд.
WATCHED = ["Prefs", "Transcripts", "Sessions", "Loops", "Activity", "Pricing"]

DECL = re.compile(r"static (?:var|let|func)\s+(\w+)")
NESTED = re.compile(r"(?:struct|enum|class)\s+(\w+)")

# Расширения файлов: «Pricing.swift» в тексте - это имя файла, а не
# обращение к члену. Первое же испытание проверки поймало ровно это.
FILE_EXT = {"swift", "py", "sh", "md", "json", "plist", "yml", "yaml", "jsonl"}


def strip_comments(src):
    """Убрать комментарии, не тронув «//» внутри строковых литералов.

    Иначе «https://...» в строке обрезается по «//», и всё, что стоит
    дальше по строке, перестаёт проверяться вовсе - тихая потеря
    покрытия, которую в выводе не видно.
    """
    out = []
    in_block = 0
    for line in src.split("\n"):
        buf = []
        i = 0
        in_str = False
        while i < len(line):
            two = line[i:i + 2]
            if in_block:
                if two == "*/":
                    in_block -= 1
                    i += 2
                    continue
                i += 1
                continue
            if in_str:
                if line[i] == "\\":
                    buf.append(line[i:i + 2])
                    i += 2
                    continue
                if line[i] == '"':
                    in_str = False
                buf.append(line[i])
                i += 1
                continue
            if two == "//":
                break
            if two == "/*":
                in_block += 1
                i += 2
                continue
            if line[i] == '"':
                in_str = True
            buf.append(line[i])
            i += 1
        out.append("".join(buf))
    return "\n".join(out)


def declared(path):
    src = strip_comments(open(path, encoding="utf-8").read())
    return set(DECL.findall(src)) | set(NESTED.findall(src))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    files = sorted(glob.glob("Sources/*.swift")) + sorted(glob.glob("Tests/*.swift"))

    # Где объявлен каждый наблюдаемый тип. Тип может лежать не в одноимённом
    # файле: Loops и Activity оба живут в SessionWatch.swift.
    text = {f: strip_comments(open(f, encoding="utf-8").read()) for f in files}

    owners = {}
    for name in WATCHED:
        for f in files:
            if re.search(r"(?:enum|struct|final class|class)\s+%s\b" % name, text[f]):
                owners.setdefault(name, []).append(f)

    missing_types = [n for n in WATCHED if n not in owners]
    if missing_types:
        print("не нашёл объявления типов: %s" % ", ".join(missing_types))
        return 1

    bad = []
    for name, paths in owners.items():
        known = set()
        for p in paths:
            known |= declared(p)
        use = re.compile(r"\b%s\.(\w+)" % name)
        for f in files:
            src = text[f]
            for m in use.finditer(src):
                member = m.group(1)
                if member in known or member in FILE_EXT:
                    continue
                line = src[: m.start()].count("\n") + 1
                bad.append((f, line, name, member))

    if not bad:
        print("  ok   ссылки на свои типы: все имена на месте (%d файлов)" % len(files))
        return 0

    for f, line, name, member in bad:
        print("  FAIL %s:%d - %s.%s не объявлено" % (f, line, name, member))
    return 1


sys.exit(main())
