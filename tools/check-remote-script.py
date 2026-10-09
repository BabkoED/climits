#!/usr/bin/env python3
"""Проверка питона, который мак шлёт по ssh на удалённую машину.

ЗАЧЕМ. Скрипт живёт строкой внутри RemoteScan.swift, и до 1.21.0 его не
гонял ни один тест: Swift-проверки видят только разбор его ответа. Ревью
09.10.2026 нашло в нём две тихие ошибки, обе прогоном на подставных файлах:
  * два разговора с одинаковым именем затирали друг друга - в разбивке
    «куда ушло за неделю» дорогой пропадал, оставался дешёвый;
  * три фоновых запуска одной команды за пять минут давали тревогу
    «крутится»: пустой stdout считался одинаковым выводом. Swift на маке
    в том же случае молчит, а расходиться детекторам нельзя.

Здесь скрипт вынимается из исходника как есть и запускается на подставном
~/.claude: расшифровки, файл живой сессии. Сеть и ssh не нужны.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "Sources", "RemoteScan.swift")

checks = 0
failures = 0


def check(name, cond):
    global checks, failures
    checks += 1
    if cond:
        print("  ok   " + name)
    else:
        failures += 1
        print("  FAIL " + name)


def script():
    src = open(SRC, encoding="utf-8").read()
    a = src.index('#"""') + len('#"""\n')
    b = src.index('"""#', a)
    return src[a:b]


def iso(seconds_ago):
    t = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=seconds_ago)
    return t.isoformat().replace("+00:00", "Z")


def write_jsonl(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")


def assistant(mid, out_tokens, seconds_ago=60):
    return {"type": "assistant", "timestamp": iso(seconds_ago),
            "message": {"id": mid, "model": "claude-opus-5-5",
                        "usage": {"input_tokens": 10, "output_tokens": out_tokens}}}


def bash_call(n, cmd, seconds_ago, result):
    tid = "toolu_%d" % n
    call = {"type": "assistant", "timestamp": iso(seconds_ago),
            "message": {"id": "m%d" % n, "content": [
                {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": cmd}}]}}
    answer = {"type": "user", "timestamp": iso(seconds_ago),
              "message": {"content": [{"type": "tool_result", "tool_use_id": tid, "content": "x"}]},
              "toolUseResult": result}
    return [call, answer]


def run(root):
    now = int(dt.datetime.now().timestamp())
    args = [sys.executable, "-I", "-", str(now - 3600),
            "flags:activity=0;pwin=0", os.path.join(root, "projects")]
    out = subprocess.run(args, input=script(), capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        print(out.stderr)
    return json.loads(out.stdout)


def session_file(root, sid):
    # Живая сессия - этот самый процесс: os.kill(pid, 0) его найдёт.
    rec = {"pid": os.getpid(), "cwd": "/tmp/work", "sessionId": sid,
           "startedAt": int(dt.datetime.now().timestamp() * 1000), "status": "busy"}
    path = os.path.join(root, "sessions", "%d.json" % os.getpid())
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec, fh)


def main():
    print("\nудалённый скрипт")
    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "projects", "p"))
        os.makedirs(os.path.join(root, "sessions"))
        proj = os.path.join(root, "projects", "p")

        # Два разговора с одним и тем же первым запросом.
        for name, mid, out in (("aaaa", "msg_a", 1000), ("bbbb", "msg_b", 2000)):
            write_jsonl(os.path.join(proj, name + ".jsonl"), [
                {"type": "last-prompt", "lastPrompt": "продолжаем"},
                assistant(mid, out)])
        ans = run(root)
        total = sum(v["output"] for v in ans["windows"][0]["families"].values())
        chats = {k: sum(v["output"] for v in f.values()) for k, f in ans["projects"].items()}
        check("окно: все 3000 токенов выхода", total == 3000)
        check("одноимённые разговоры сложены, а не затёрты", chats.get("продолжаем") == 3000)

    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "projects", "p"))
        os.makedirs(os.path.join(root, "sessions"))
        proj = os.path.join(root, "projects", "p")

        # Фоновый запуск: stdout пуст, backgroundTaskId каждый раз новый.
        rows = []
        for n in range(3):
            rows += bash_call(n, "./run-tests.sh", 200 - n * 60,
                              {"stdout": "", "stderr": "", "interrupted": False, "isImage": False,
                               "noOutputExpected": False, "backgroundTaskId": "bg%d" % n})
        write_jsonl(os.path.join(proj, "sess-bg.jsonl"), rows)
        session_file(root, "sess-bg")
        ans = run(root)
        s = ans["sessions"][0] if ans["sessions"] else {}
        check("живая сессия найдена", bool(ans["sessions"]))
        check("три фоновых запуска - не кручение", "loop" not in s)

    with tempfile.TemporaryDirectory() as root:
        os.makedirs(os.path.join(root, "projects", "p"))
        os.makedirs(os.path.join(root, "sessions"))
        proj = os.path.join(root, "projects", "p")

        # Контроль: настоящее кручение детектор обязан ловить и дальше.
        rows = []
        for n in range(3):
            rows += bash_call(n, "swift build", 200 - n * 60,
                              {"stdout": "", "stderr": "error: no such module", "interrupted": False,
                               "isImage": False, "noOutputExpected": False})
        write_jsonl(os.path.join(proj, "sess-loop.jsonl"), rows)
        session_file(root, "sess-loop")
        ans = run(root)
        s = ans["sessions"][0] if ans["sessions"] else {}
        check("одна ошибка трижды - кручение", (s.get("loop") or {}).get("count") == 3)

    print("\nпроверок питона: %d, провалов: %d" % (checks, failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
