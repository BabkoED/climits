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
        var memory = MachineMemory()
        // Разговоры той машины. Ключ - готовое ИМЯ у тех, кого покажут,
        // и путь у остальных: имя читает та сторона, потому что её файлов
        // у мака нет вовсе. Мак отличает одно от другого по ведущей косой
        // черте и второй раз имя искать не идёт.
        var projects: [String: WindowUsage] = [:]
    }

    // Довод для удалённого шелла.
    //
    // Одинарные кавычки, потому что внутри них шелл не трогает вообще
    // ничего: ни «;», ни «$», ни пробел. Единственное, что нельзя
    // поставить внутрь, - сама одинарная кавычка, и её классический
    // приём закрывает: закрыть строку, добавить экранированную кавычку,
    // открыть снова.
    //
    // Тильда - исключение, и намеренное. «~/.claude/projects» в кавычках
    // перестаёт быть домашним каталогом и становится папкой с именем «~»,
    // которой нет. Путь, начинающийся с «~/», квотируется с первого
    // знака после неё: тильда остаётся шеллу, остальное защищено.
    static func shellQuote(_ s: String) -> String {
        func wrap(_ x: String) -> String {
            return "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if s == "~" { return s }
        if s.hasPrefix("~/") {
            return "~/" + wrap(String(s.dropFirst(2)))
        }
        return wrap(s)
    }

    // Доводы скрипта - готовые к склейке шеллом на той стороне.
    //
    // Отдельной функцией, потому что проверять надо именно её: ошибка
    // здесь не роняет ничего, она превращает ответ сервера в пустой,
    // и в меню это выглядит как «на сервере ничего не происходит».
    static func scriptArgs(cutoffs: [Date], wantActivity: Bool,
                           projectsWindow: Int, path: String) -> [String] {
        let raw = cutoffs.map { String(Int($0.timeIntervalSince1970)) }
            + ["flags:activity=\(wantActivity ? 1 : 0);pwin=\(projectsWindow)",
               path.isEmpty ? "~/.claude/projects" : path]
        return raw.map { shellQuote($0) }
    }

    // Сколько ждём. Обход сотни мегабайт на той стороне - это секунды, но
    // на холодном кэше файловой системы бывает и полминуты.
    static let timeout: TimeInterval = 60

    // Синхронный вызов: гонять его можно только с фоновой очереди.
    static func usage(host: String, path: String, cutoffs: [Date],
                      wantActivity: Bool = false,
                      projectsWindow: Int = -1) -> Result<Answer, Failure> {
        // Адрес, начинающийся с дефиса, ssh примет за свой ключ. Пробел
        // внутри - это уже не адрес, а попытка дописать аргументов.
        guard !host.isEmpty, !host.hasPrefix("-"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return .failure(.badHost(host)) }

        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ClearAllForwardings=yes", "-T",
                    host, "/usr/bin/env", "python3", "-"]

        // ДОВОДЫ СКРИПТА КВОТИРУЮТСЯ, И ЭТО НЕ ПЕРЕСТРАХОВКА.
        //
        // ssh НЕ передаёт аргументы массивом, как Process. Он склеивает
        // их пробелами в одну строку и отдаёт шеллу пользователя на той
        // стороне. Значит всякий спецсимвол шелла в доводе - это разрыв
        // команды, а не знак в строке.
        //
        // Поймано живьём 12.09.2026, и сломал это я сам в 1.12.0: довод
        // «flags:activity=0;pwin=-1» шелл на сервере разрывал по «;».
        // Питону доставалось «flags:activity=0» последним доводом, он
        // принимал его за каталог расшифровок - и честно отвечал пустотой:
        // ни сессий, ни денег со второй машины. Выглядело это не как
        // ошибка, а как «на сервере ничего не происходит».
        //
        // Здесь же закрывается то, что до сих пор стояло в комментарии
        // неверно: «путь уезжает доводом, поэтому пробел внутри остаётся
        // пробелом». Не остаётся - путь с пробелом разваливался на два
        // довода ровно так же, просто никто такой не настраивал.
        args += scriptArgs(cutoffs: cutoffs, wantActivity: wantActivity,
                           projectsWindow: projectsWindow, path: path)

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
                if var s = Sessions.parse(json: item, machine: host) {
                    // Мерил их тот же скрипт на той стороне: pid оттуда
                    // здесь ничего не значит, и /proc у нас своё.
                    s.rssMB = Sessions.intValue(item["rss_mb"]) ?? 0
                    s.swapMB = Sessions.intValue(item["swap_mb"]) ?? 0
                    live.append(s)
                }
            }
        }
        var mem = MachineMemory()
        if let m = root["memory"] as? [String: Any] {
            mem.totalMB = Sessions.intValue(m["total"]) ?? 0
            mem.availableMB = Sessions.intValue(m["available"]) ?? 0
            mem.swapTotalMB = Sessions.intValue(m["swap_total"]) ?? 0
            let free = Sessions.intValue(m["swap_free"]) ?? 0
            mem.swapUsedMB = max(0, mem.swapTotalMB - free)
        }
        // Разговоры - тоже необязательная часть: их не будет, если разбивку
        // не просили. Пустой словарь и «не просили» тут одно и то же.
        var projects: [String: WindowUsage] = [:]
        if let items = root["projects"] as? [String: [String: Any]] {
            for (dir, fams) in items {
                var w = WindowUsage()
                for (family, any) in fams {
                    guard let v = any as? [String: Any] else { continue }
                    w.byFamily[family] = TokenTally(
                        input: Int(jsonNumber(v["input"]) ?? 0),
                        output: Int(jsonNumber(v["output"]) ?? 0),
                        cacheWrite: Int(jsonNumber(v["cache_write"]) ?? 0),
                        cacheRead: Int(jsonNumber(v["cache_read"]) ?? 0),
                        requests: Int(jsonNumber(v["requests"]) ?? 0),
                        cacheWrite1h: Int(jsonNumber(v["cache_write_1h"]) ?? 0))
                }
                if !w.isEmpty { projects[dir] = w }
            }
        }
        return .success(Answer(windows: out, sessions: Sessions.sorted(live),
                               memory: mem, projects: projects))
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

# Разбор доводов.
#
# Границы окон идут числами, как и раньше. Настройки приехали позже и
# добавлены отдельным доводом «flags:...», а не новой позицией: позиция
# сломала бы старую версию скрипта молча, а незнакомый довод она просто
# не увидит - числами он не притворяется.
cutoffs = []
flags = {}
for a in sys.argv[1:-1]:
    if a.startswith("flags:"):
        for kv in a[6:].split(";"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                flags[k] = v
        continue
    try:
        cutoffs.append(int(a))
    except ValueError:
        pass
want_activity = flags.get("activity") == "1"
# Номер окна, которое разносим по проектам. -1 - не разносить вовсе.
projects_window = int(flags.get("pwin", "-1"))
root = os.path.expanduser(sys.argv[-1])
earliest = min(cutoffs) if cutoffs else 0
projects = {}

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
                # Разбивка по разговорам - только по заказанному окну.
                # Ключ - путь файла: один файл это ровно один разговор.
                # Имя ему подберём ниже, и только тем, кого покажут.
                if i == projects_window:
                    pacc = projects.setdefault(p, {})
                    fam_acc = pacc.setdefault(fam, [0, 0, 0, 0, 0, 0])
                    for k in range(6):
                        fam_acc[k] += add[k]

# Имена разговоров - тем, кто попадёт в показ.
#
# Читает ТА сторона, а не мак: файлов этой машины у мака нет вовсе.
# Правило то же, что в Transcripts.chatTitle: своё имя из `custom-title`
# важнее, первый запрос - запасной. Голова и хвост по 64 КБ: своё имя
# лежит в конце, первый запрос в начале, а целиком файл бывает
# двадцатимегабайтным.
#
# Имён берём с запасом (10 против пяти показываемых): топ здесь считается
# по расходу ЭТОЙ машины, а показывается общий по всем - разговор, шестой
# тут, в общем списке может оказаться третьим.
# Размеры кусков посчитаны, а не взяты круглыми - см. оговорку у
# Transcripts.chatTitle. Коротко: первый запрос лежит не в начале файла,
# медиана отступа 63 КБ, и на 64 КБ имя находилось у половины файлов.
# Живой прогон это и показал: имена нашлись у 2 разговоров из 10.
TITLE_TAIL = 64 * 1024
TITLE_HEAD = 256 * 1024
TITLE_HEAD_RETRY = 1024 * 1024
TITLE_TOP = 10


def chat_title(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > TITLE_TAIL:
                fh.seek(size - TITLE_TAIL)
            tail = fh.read(TITLE_TAIL).decode("utf-8", "ignore")
            for line in reversed(tail.split("\n")):
                if '"custom-title"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if row.get("type") == "custom-title":
                    t = (row.get("customTitle") or "").strip()
                    if t:
                        return t
            # Вторая ступень - только если в первой не нашлось и файл
            # вообще длиннее первой.
            for want in (TITLE_HEAD, TITLE_HEAD_RETRY):
                if want > TITLE_HEAD and size <= TITLE_HEAD:
                    break
                fh.seek(0)
                head = fh.read(want).decode("utf-8", "ignore")
                for line in head.split("\n"):
                    if '"last-prompt"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except Exception:
                        continue
                    if row.get("type") == "last-prompt":
                        t = " ".join((row.get("lastPrompt") or "").split())
                        if t:
                            return t
    except Exception:
        pass
    return None


def _weight(fams):
    # Порядок, а не деньги: прайс живёт на маке. Выхлоп - самая дорогая
    # часть счёта, и для сортировки внутри одной машины его довольно.
    return sum(v[1] * 5 + v[0] + v[2] for v in fams.values())


named_projects = {}
for path, fams in sorted(projects.items(), key=lambda kv: -_weight(kv[1]))[:TITLE_TOP]:
    name = chat_title(path)
    if name:
        # Ключ-имя мак отличает от ключа-пути по ведущей косой черте
        # и второй раз имя искать не идёт.
        named_projects[name] = fams
        projects[path] = None
for path, fams in projects.items():
    if fams is not None:
        named_projects[path] = fams
projects = named_projects

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

# --- сторож кручения и занятие сессии ---------------------------------------
#
# Зеркало Loops/Activity из SessionWatch.swift. Числа и правило те же:
# три одинаковых вызова изменяющего инструмента за пять минут ПРИ
# СОВПАДАЮЩЕМ выводе. Обоснование и таблица реплея - там же, дублировать
# их здесь незачем, а расходиться этим двум нельзя.
LOOP_REPEATS = 3
LOOP_WINDOW = 300
LOOP_TAIL = 512 * 1024
LOOP_TOOLS = ("Bash", "Edit", "Write", "MultiEdit", "NotebookEdit")
ACTIVITY_LIMIT = 60


def _sig(tool, inp):
    if not isinstance(inp, dict):
        return tool, ""
    if tool == "Bash":
        cmd = str(inp.get("command") or "")
        return tool + "|" + cmd[:400], cmd
    if tool in ("Edit", "MultiEdit"):
        p = str(inp.get("file_path") or "")
        return tool + "|" + p + "|" + str(inp.get("old_string") or "")[:200], p
    if tool in ("Write", "NotebookEdit"):
        p = str(inp.get("file_path") or inp.get("notebook_path") or "")
        return tool + "|" + p + "|" + str(inp.get("content") or "")[:200], p
    return tool + "|" + json.dumps(inp, sort_keys=True)[:400], ""


def _result_sig(res):
    if not isinstance(res, dict):
        return str(res)[:2000] if res is not None else None
    out = res.get("stdout")
    err = res.get("stderr")
    if isinstance(out, str) or isinstance(err, str):
        return (out or "") + "\x00" + (err or "")
    return json.dumps(res, sort_keys=True, default=str)[:2000]


def watch_session(sid, projects_root):
    """Хвост расшифровки этой сессии: крутится ли и над чем работает."""
    path = None
    try:
        for proj in os.listdir(projects_root):
            p = os.path.join(projects_root, proj, sid + ".jsonl")
            if os.path.isfile(p):
                path = p
                break
    except OSError:
        return {}
    if path is None:
        return {}
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > LOOP_TAIL:
                fh.seek(size - LOOP_TAIL)
            text = fh.read(LOOP_TAIL).decode("utf-8", "ignore")
    except OSError:
        return {}

    edge = datetime.datetime.now().timestamp() - LOOP_WINDOW
    calls = []
    results = {}
    activity = None
    for line in text.split("\n"):
        if '"toolUseResult"' in line:
            try:
                row = json.loads(line)
            except Exception:
                continue
            content = (row.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            sig = _result_sig(row.get("toolUseResult"))
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    tid = b.get("tool_use_id")
                    if tid:
                        results[tid] = sig
            continue
        if '"tool_use"' not in line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        t = when(row)
        if t is None or t < edge:
            continue
        content = (row.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            tool = b.get("name") or ""
            if tool not in LOOP_TOOLS:
                continue
            key, what = _sig(tool, b.get("input") or {})
            calls.append([t, tool, key, what, b.get("id")])

    # Ищем С КОНЦА: строка last-prompt переписывается на каждый новый
    # запрос, и в хвосте их несколько. Нужна последняя, иначе трей покажет
    # позапрошлую задачу и будет врать тем убедительнее, чем дольше сессия.
    if want_activity:
        for line in reversed(text.split("\n")):
            if '"last-prompt"' not in line:
                continue
            try:
                row = json.loads(line)
            except Exception:
                continue
            if isinstance(row, dict) and row.get("type") == "last-prompt":
                p = row.get("lastPrompt")
                if isinstance(p, str) and p.strip():
                    activity = " ".join(p.split())[:ACTIVITY_LIMIT]
                    break

    loop = None
    hist = {}
    for t, tool, key, what, tid in sorted(calls, key=lambda c: c[0]):
        seen = [x for x in hist.get(key, []) if t - x[0] <= LOOP_WINDOW]
        seen.append((t, results.get(tid)))
        hist[key] = seen
        if len(seen) < LOOP_REPEATS:
            continue
        known = [r for (_, r) in seen if r is not None]
        # Меньше двух известных выводов - судить не по чему. Тревога без
        # основания дороже пропущенной.
        if len(known) < 2 or len(set(known)) != 1:
            continue
        if loop is None or len(seen) > loop["count"]:
            loop = {"tool": tool, "count": len(seen), "what": what[:80]}
    return {"loop": loop, "activity": activity}


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

    # Не крутится ли эта сессия на месте, и над чем она работает.
    #
    # Считается ЗДЕСЬ, а не на маке: детектору нужен хвост расшифровки,
    # полмегабайта на сессию. Тянуть их по ssh ради трёх чисел нельзя -
    # обход и так идёт по сети. Сюда уезжает готовый итог.
    #
    # Правило то же, что на маке, и держать их одинаковыми обязательно:
    # разойдись они - одна и та же сессия считалась бы крутящейся с одной
    # машины и здоровой с другой, и понять, которая права, было бы нельзя.
    sid = rec.get("sessionId")
    if isinstance(sid, str) and sid:
        info = watch_session(sid, root)
        if info.get("loop"):
            item["loop"] = info["loop"]
        if want_activity and info.get("activity"):
            item["activity"] = info["activity"]
    # Память: и в ОЗУ, и в свопе. Своп здесь важнее ОЗУ - у сессии,
    # которую обработала гибернация, он больше, и это единственный
    # способ увидеть снаружи, что она работает.
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    item["rss_mb"] = int(line.split()[1]) // 1024
                elif line.startswith("VmSwap:"):
                    item["swap_mb"] = int(line.split()[1]) // 1024
    except Exception:
        pass
    cwd = rec.get("cwd")
    item["cwd"] = os.path.basename(cwd.rstrip("/")) if isinstance(cwd, str) else ""
    sessions.append(item)

# Память машины на той стороне: сумма по сессиям без неё не с чем сравнить.
mem = {}
try:
    with open("/proc/meminfo") as fh:
        want = {"MemTotal:": "total", "MemAvailable:": "available",
                "SwapTotal:": "swap_total", "SwapFree:": "swap_free"}
        for line in fh:
            f = line.split()
            if len(f) >= 2 and f[0] in want:
                mem[want[f[0]]] = int(f[1]) // 1024
except Exception:
    pass

print(json.dumps({
    "windows": out,
    "sessions": sessions,
    "memory": mem,
    "projects": {name: {f: {"input": v[0], "output": v[1], "cache_write": v[2],
                            "cache_read": v[3], "requests": v[4],
                            "cache_write_1h": v[5]}
                        for f, v in fams.items()}
                 for name, fams in projects.items()},
}))
"""#
}
