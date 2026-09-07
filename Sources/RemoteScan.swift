import Foundation

// Счёт расшифровок на второй машине - по ssh.
//
// ЗАЧЕМ. Процент лимита сервер Anthropic считает по всему аккаунту, а токены
// и деньги приложение считает само - по файлам ~/.claude/projects той машины,
// где запущено. Если работа идёт ещё и по ssh на сервере, локальный счёт
// видит меньшую часть расхода. Замер 28.08.2026: за одно и то же недельное
// окно мак насчитал $258, а сервер - $924. Это не разные лимиты, это два
// куска одного расхода, и приложение показывало меньший, не сказав об этом.
//
// КАК. Тот же разбор, что и в Transcripts, только выполняется на той стороне:
// гонять по сети гигабайт расшифровок ради двух десятков чисел бессмысленно.
// Скрипт уезжает на stdin, обратно приезжает JSON на несколько строк.
//
// ЧЕГО ЗДЕСЬ НЕТ НАМЕРЕННО:
//   * BatchMode=yes - пароль спрашивать некому, окна для этого нет. Нет
//     ключа - честная ошибка в меню, а не молчаливое зависание;
//   * StrictHostKeyChecking не ослаблен. Незнакомый хост - это ошибка,
//     а не повод молча принять чей угодно ключ. Подключись из терминала
//     один раз, дальше приложение подхватит known_hosts;
//   * команда собирается массивом аргументов, не строкой для шелла.
// Что человек уже настроил в ~/.ssh/config. Нужно ровно за тем, чтобы
// не заставлять его вспоминать адрес и не ловить опечатку: в настройках
// список подставляется в выпадающий список, и адрес выбирается, а не
// набирается.
enum SSHConfig {
    static var path: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
    }

    static func hosts(at url: URL? = nil) -> [String] {
        guard let text = try? String(contentsOf: url ?? path, encoding: .utf8) else { return [] }
        return hosts(inText: text)
    }

    static func hosts(inText text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            // «Host» пишут и «host», и «HOST» - ssh к регистру равнодушен.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let head = parts.first, head.lowercased() == "host" else { continue }
            for pattern in parts.dropFirst() {
                let name = String(pattern)
                // Шаблоны - это правила для всех хостов сразу, а не адрес,
                // по которому куда-то можно зайти. Отрицания тоже.
                if name.contains("*") || name.contains("?") || name.hasPrefix("!") { continue }
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }
}

enum RemoteScan {

    enum Failure: Error {
        case badHost(String)
        case timeout
        case ssh(String)
        case badAnswer(String)

        var text: String {
            switch self {
            case .badHost(let s): return L("непонятный адрес: \(s)", "bad host: \(s)")
            case .timeout: return L("не ответил вовремя", "timed out")
            case .ssh(let s): return s
            case .badAnswer(let s): return L("странный ответ: \(s)", "odd answer: \(s)")
            }
        }
    }

    // Что приезжает с той стороны. Раньше это был просто массив окон;
    // сессии приехали к нему в компанию, потому что везёт их тот же
    // единственный вызов ssh. Заводить второй заход ради восьми маленьких
    // файлов - это второе рукопожатие и второй шанс не ответить вовремя.
    struct Answer {
        var windows: [WindowUsage] = []
        var sessions: [AgentSession] = []
    }

    // Сколько ждём. Обход сотни мегабайт на той стороне - это секунды, но
    // на холодном кэше файловой системы бывает и полминуты.
    static let timeout: TimeInterval = 60

    // Синхронный вызов: гонять его можно только с фоновой очереди.
    static func usage(host: String, path: String, cutoffs: [Date]) -> Result<Answer, Failure> {
        // Адрес, начинающийся с дефиса, ssh примет за свой ключ. Пробел
        // внутри - это уже не адрес, а попытка дописать аргументов.
        guard !host.isEmpty, !host.hasPrefix("-"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return .failure(.badHost(host)) }

        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ClearAllForwardings=yes", "-T",
                    host, "/usr/bin/env", "python3", "-"]
        args += cutoffs.map { String(Int($0.timeIntervalSince1970)) }
        // Каталог уезжает аргументом скрипта, а не подстановкой в текст:
        // так путь с пробелом или кавычкой остаётся путём.
        args.append(path.isEmpty ? "~/.claude/projects" : path)

        switch run(args: args, stdin: script) {
        case .failure(let e): return .failure(e)
        case .success(let data): return parse(data, expected: cutoffs.count, host: host)
        }
    }

    // --- запуск -------------------------------------------------------------
    private static func run(args: [String], stdin: String) -> Result<Data, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardInput = inPipe

        // Ошибки уходят в файл, а не в трубу. Труба на несколько килобайт -
        // это ещё один способ встать намертво: ssh пишет предупреждение,
        // буфер кончается, ssh ждёт читателя, читатель ждёт конца вывода.
        // Читать её параллельно тоже можно, но это гонка за переменной,
        // а файл проще и не врёт.
        let errFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("climits-ssh-\(getpid())-\(Int(Date().timeIntervalSince1970)).err")
        _ = FileManager.default.createFile(atPath: errFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errFile) }
        if let fh = try? FileHandle(forWritingTo: errFile) { p.standardError = fh }

        do { try p.run() } catch { return .failure(.ssh(error.localizedDescription)) }

        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        inPipe.fileHandleForWriting.closeFile()

        // Сторож: без него неотвечающий хост держит фоновую задачу навсегда,
        // и следующий обход не начнётся никогда.
        var timedOut = false
        let watchdog = DispatchWorkItem {
            timedOut = true
            p.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        if timedOut { return .failure(.timeout) }
        guard p.terminationStatus == 0 else {
            let errData = (try? Data(contentsOf: errFile)) ?? Data()
            let msg = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = msg.split(separator: "\n").first.map(String.init) ?? ""
            if let plain = explain(msg) { return .failure(.ssh(plain)) }
            return .failure(.ssh(firstLine.isEmpty
                ? L("ssh вышел с кодом \(p.terminationStatus)", "ssh exited \(p.terminationStatus)")
                : firstLine))
        }
        return .success(out)
    }

    // Частые причины отказа - словами, а не как их печатает ssh.
    //
    // «Permission denied (publickey)» человеку не говорит, ЧТО делать,
    // а сделать надо ровно одно понятное действие. Незнакомую ошибку
    // не переводим: выдумать неверное объяснение хуже, чем отдать как есть.
    static func explain(_ raw: String) -> String? {
        let m = raw.lowercased()
        if m.contains("permission denied") {
            return L("ключ этой машины не пущен на ту сторону",
                     "this machine's key is not authorised there")
        }
        if m.contains("host key verification failed") {
            return L("хост незнакомый - зайди на него из терминала один раз",
                     "unknown host - log in from a terminal once")
        }
        if m.contains("could not resolve hostname") {
            return L("такое имя не находится", "no such hostname")
        }
        if m.contains("connection refused") || m.contains("connection timed out") ||
           m.contains("no route to host") {
            return L("не достучаться до хоста", "cannot reach the host")
        }
        if m.contains("python3") && (m.contains("not found") || m.contains("no such file")) {
            return L("на той стороне нет python3", "no python3 on that side")
        }
        if m.contains("operation timed out") {
            return L("не ответил вовремя", "timed out")
        }
        return nil
    }

    // --- разбор ответа ------------------------------------------------------
    static func parse(_ data: Data, expected: Int,
                      host: String = "") -> Result<Answer, Failure> {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["windows"] as? [[String: Any]], list.count == expected
        else {
            let head = String(decoding: data.prefix(120), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.badAnswer(head))
        }

        var out: [WindowUsage] = []
        for item in list {
            var w = WindowUsage()
            if let fams = item["families"] as? [String: [String: Any]] {
                for (family, v) in fams {
                    w.byFamily[family] = TokenTally(
                        input: Int(jsonNumber(v["input"]) ?? 0),
                        output: Int(jsonNumber(v["output"]) ?? 0),
                        cacheWrite: Int(jsonNumber(v["cache_write"]) ?? 0),
                        cacheRead: Int(jsonNumber(v["cache_read"]) ?? 0),
                        requests: Int(jsonNumber(v["requests"]) ?? 0),
                        // Старая версия скрипта на той стороне этого поля
                        // не пришлёт - тогда ноль, и часовая надбавка просто
                        // не учтётся. Это лучше, чем отказаться от ответа.
                        cacheWrite1h: Int(jsonNumber(v["cache_write_1h"]) ?? 0))
                }
            }
            if let u = item["unknown"] as? [String] { w.unknownModels = Set(u) }
            w.truncated = (item["truncated"] as? Bool) ?? false
            out.append(w)
        }

        // Сессии - необязательная часть ответа. Скрипт на той стороне
        // старой версии их не пришлёт, и это не повод отказаться от денег
        // и токенов, которые пришли: раздел просто будет пуст.
        //
        // Живость на той стороне проверил тот же скрипт: pid оттуда на
        // этой машине не значит ничего, а то и значит чужой процесс.
        var live: [AgentSession] = []
        if let items = root["sessions"] as? [[String: Any]] {
            for item in items {
                if let s = Sessions.parse(json: item, machine: host) { live.append(s) }
            }
        }
        return .success(Answer(windows: out, sessions: Sessions.sorted(live)))
    }

    // --- то, что выполняется на той стороне ----------------------------------
    //
    // Повторяет Transcripts.usage: те же окна, тот же дедуп по message.id,
    // тот же хвост в 64 МБ, тот же пропуск служебных моделей. Расхождение
    // между этими двумя разборами будет тихим - сумма просто станет другой, -
    // поэтому правки сюда и туда идут вместе.
    private static let script = #"""
import json, os, sys, datetime

MAX_TAIL = 64 * 1024 * 1024
FAMILIES = ("fable", "opus", "sonnet", "haiku")
FALLBACK = "sonnet"

cutoffs = [int(a) for a in sys.argv[1:-1]]
root = os.path.expanduser(sys.argv[-1])
earliest = min(cutoffs) if cutoffs else 0

wins = [{"families": {}, "unknown": set(), "truncated": False} for _ in cutoffs]
seen = set()


def when(row):
    ts = row.get("timestamp")
    if not isinstance(ts, str):
        return None
    try:
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def tail(path):
    size = os.path.getsize(path)
    cut = size > MAX_TAIL
    with open(path, "rb") as fh:
        if cut:
            fh.seek(size - MAX_TAIL)
        data = fh.read(MAX_TAIL)
    return data.decode("utf-8", "ignore"), cut


for dirpath, dirnames, filenames in os.walk(root):
    for name in filenames:
        if not name.endswith(".jsonl"):
            continue
        p = os.path.join(dirpath, name)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        # Только обычные файлы: ссылка на /dev/zero читалась бы вечно.
        if not os.path.isfile(p) or os.path.islink(p):
            continue
        if st.st_mtime < earliest:
            continue
        try:
            text, cut = tail(p)
        except OSError:
            continue
        if cut:
            for w in wins:
                w["truncated"] = True
        for line in text.split("\n"):
            if '"usage"' not in line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            t = when(row)
            if t is None or t < earliest:
                continue
            msg = row.get("message")
            if not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            mid = msg.get("id")
            if isinstance(mid, str) and mid:
                if mid in seen:
                    continue
                seen.add(mid)
            model = msg.get("model") or ""
            if model.startswith("<"):
                continue
            low = model.lower()
            fam = next((f for f in FAMILIES if f in low), FALLBACK)
            # Быстрый режим - та же модель по двойной цене, признак лежит
            # в самом usage. Отдельный ключ семейства, как и на маке.
            if usage.get("speed") == "fast":
                fam += "-fast"

            def num(key):
                v = usage.get(key)
                return int(v) if isinstance(v, (int, float)) else 0

            # Часовая запись в кэш стоит вдвое от входа против 1.25 у
            # пятиминутной, а общее поле их не различает: разбивка лежит
            # в usage.cache_creation. Нет разбивки - часовая доля ноль,
            # считается как раньше.
            cc = usage.get("cache_creation")
            w1h = 0
            if isinstance(cc, dict):
                v = cc.get("ephemeral_1h_input_tokens")
                w1h = int(v) if isinstance(v, (int, float)) else 0

            add = (num("input_tokens"), num("output_tokens"),
                   num("cache_creation_input_tokens"), num("cache_read_input_tokens"), 1,
                   w1h)
            for i, cutoff in enumerate(cutoffs):
                if t < cutoff:
                    continue
                acc = wins[i]["families"].setdefault(fam, [0, 0, 0, 0, 0, 0])
                for k in range(6):
                    acc[k] += add[k]
                if model and not any(f in low for f in FAMILIES):
                    wins[i]["unknown"].add(model)

out = []
for w in wins:
    out.append({
        "families": {f: {"input": v[0], "output": v[1], "cache_write": v[2],
                         "cache_read": v[3], "requests": v[4],
                         "cache_write_1h": v[5]}
                     for f, v in w["families"].items()},
        "unknown": sorted(w["unknown"]),
        "truncated": w["truncated"],
    })

# Кто на той стороне работает, а кто ждёт ответа.
#
# Claude Code сам пишет ~/.claude/sessions/<pid>.json на каждую сессию.
# Каталог берём рядом с расшифровками, а не по домашнему пути: человек мог
# указать в настройках свой каталог, и тогда сессии лежат при нём.
#
# Живость проверяем ЗДЕСЬ. Отдавать pid на ту сторону и спрашивать там
# нельзя вовсе: pid с сервера на маке либо не значит ничего, либо значит
# чужой процесс. os.kill(pid, 0) сигнала не посылает, только спрашивает.
sessions = []
sdir = os.path.join(os.path.dirname(root.rstrip("/")), "sessions")
now = datetime.datetime.now().timestamp()
try:
    names = sorted(os.listdir(sdir))
except OSError:
    names = []
for name in names:
    if not name.endswith(".json"):
        continue
    try:
        with open(os.path.join(sdir, name)) as fh:
            rec = json.load(fh)
    except Exception:
        continue
    if not isinstance(rec, dict):
        continue
    pid = rec.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        continue
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        continue          # файл остался от упавшего процесса
    except PermissionError:
        pass              # процесс есть, но чужой - живой
    except Exception:
        continue
    started = rec.get("startedAt")
    if isinstance(started, (int, float)) and now - started / 1000 > 24 * 3600:
        continue          # тот же порог, что и на этой стороне
    # Отдаём только то, что показываем, и ни знака больше: cwd целиком -
    # это имена проектов и заказчиков, а в трее видно последний каталог.
    keep = ("pid", "name", "entrypoint", "status", "tempo",
            "waitingFor", "needs", "statusUpdatedAt", "updatedAt")
    item = {k: rec[k] for k in keep if k in rec}
    cwd = rec.get("cwd")
    item["cwd"] = os.path.basename(cwd.rstrip("/")) if isinstance(cwd, str) else ""
    sessions.append(item)

print(json.dumps({"windows": out, "sessions": sessions}))
"""#
}
