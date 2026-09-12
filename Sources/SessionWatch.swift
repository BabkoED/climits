import Foundation

// Не застряла ли сессия.
//
// ЗАЧЕМ. Раздел сессий отвечает на «кто ждёт меня» и «что грузит память».
// Есть третье состояние, которого не видно ни там, ни там: сессия работает
// без остановки и не двигается. Статус у неё честный - busy, память
// обычная, процент лимита капает. Снаружи это неотличимо от работы, а
// стоит дороже простоя: простаивающая сессия не тратит ничего, крутящаяся
// тратит и лимит, и деньги, и время человека, который её не трогает,
// потому что «она же занята».
//
// ОТКУДА ПРАВИЛО. Идея взята у caprock (caprock.dev, прочитано 12.09.2026):
// повтор одного и того же инструмента с почти одинаковым вводом за
// несколько минут. Их калибровка гласит, что шум дают повторные чтения,
// и читающие инструменты надо исключить.
//
// У НАС ЛОЖНЯК ДРУГОЙ, и это выяснилось только прогоном по своей истории.
// Реплей 286 сессий, 14 329 вызовов инструментов, 12.09.2026:
//
//   правило                                    тревог   из них по делу
//   3 повтора за 5 мин, все инструменты           17     примерно треть
//   3 повтора за 5 мин, только изменяющие         11     примерно половина
//   то же + СОВПАДАЮЩИЙ вывод                      3     все три
//
// Повторные чтения у нас почти не шумят - отпечаток берётся с точной
// команды, а дважды одинаковый `cat` за пять минут редок. Зато шумит
// то, чего у них в списке нет вовсе: ОПРОС ФОНОВОЙ РАБОТЫ. `cat
// /tmp/replay.log` три раза подряд - это не застрявший агент, это
// ожидание долгого прогона, нормальная работа.
//
// Отличить их можно ровно одним способом: посмотреть на вывод. У ждущего
// он меняется - прогон пишет новые строки. У застрявшего он побайтово тот
// же. Поэтому условие здесь ДВОЙНОЕ, и второе важнее первого.
//
// Порог оставлен на трёх повторах, а не на четырёх: с проверкой вывода
// четвёрка не даёт ни одной тревоги на всей истории, то есть выключает
// детектор совсем.
//
// ЧЕГО ЭТОТ ЗАМЕР НЕ ДОКАЗЫВАЕТ. История состоит из сессий, которые
// человек вёл: настоящее зацикливание в ней редкость, потому что его
// прерывали руками. Три тревоги на 286 сессий - это оценка ЛОЖНЫХ
// срабатываний (их мало), а не полноты. Сколько зацикливаний детектор
// пропустит, эта выборка сказать не может вовсе.
struct LoopAlert: Equatable {
    var tool: String
    var count: Int
    var what: String            // команда или путь, коротко

    // «крутится: Bash ×4». Инструмент назван, потому что «крутится ×4»
    // не говорит, где смотреть.
    var text: String {
        return L("крутится: ", "looping: ") + tool + " \u{00D7}\(count)"
    }
}

enum Loops {

    // Три одинаковых вызова за пять минут при одинаковом выводе.
    // Числа не подобраны на глаз - см. таблицу реплея выше.
    static let repeats = 3
    static let window: TimeInterval = 300

    // Хвост файла, который читаем. Замер 12.09.2026 по шести самым
    // большим расшифровкам (7,8-22 МБ): десять минут работы занимают
    // от 22 до 190 КБ. Полмегабайта покрывает пятиминутное окно
    // с запасом больше чем вдвое даже в самой плотной сессии.
    static let tailBytes = 512 * 1024

    // Инструменты, которые что-то МЕНЯЮТ.
    //
    // Bash здесь, хотя половина его вызовов - чтение (cat, grep, ls).
    // Разбирать команду и решать, читающая она или нет, значит заводить
    // список исключений, который врёт на первом же `python3 -c`. Проверка
    // вывода снимает это лучше любого списка: читающая команда, повторённая
    // с тем же результатом, - такое же кручение на месте, как и всё
    // остальное.
    static let mutating: Set<String> = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"]

    // --- разбор ---------------------------------------------------------

    // Один вызов инструмента с привязанным выводом.
    struct Call: Equatable {
        var at: Date
        var tool: String
        var sig: UInt64          // отпечаток ввода
        var what: String         // что показать человеку
        var result: UInt64?      // отпечаток вывода, nil - не нашли
    }

    // Свой хеш, а не hashValue.
    //
    // У Swift hashValue засеивается случайно при каждом запуске: внутри
    // одного прохода он сравнивается верно, но тест, записавший ожидаемое
    // число, развалится на следующем запуске. Здесь FNV-1a - он одинаков
    // всегда, и поведение детектора воспроизводится.
    static func hash(_ s: Substring) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    static func hash(_ s: String) -> UInt64 { return hash(s[...]) }

    // Отпечаток ввода. Разный для разных инструментов: у правки значение
    // имеет файл и то, что ищем, у команды - сама команда.
    static func inputSignature(tool: String, input: [String: Any]) -> (sig: UInt64, what: String) {
        func str(_ k: String) -> String { return (input[k] as? String) ?? "" }
        switch tool {
        case "Bash":
            let cmd = str("command")
            return (hash(String(cmd.prefix(400))), cmd)
        case "Edit", "MultiEdit":
            let p = str("file_path")
            return (hash(p + "|" + String(str("old_string").prefix(200))), p)
        case "Write", "NotebookEdit":
            let p = p_of(input)
            return (hash(p + "|" + String(str("content").prefix(200))), p)
        default:
            let all = input.keys.sorted().map { "\($0)=\(input[$0] ?? "")" }.joined(separator: "|")
            return (hash(String(all.prefix(400))), all)
        }
    }

    private static func p_of(_ input: [String: Any]) -> String {
        return (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
    }

    // Отпечаток вывода.
    //
    // Берём stdout и stderr - это то, что меняется у идущего прогона.
    // Остальные поля ответа (interrupted, isImage) одинаковы всегда и
    // отличать ими нечего. Если формат другой - хешируем что есть.
    static func resultSignature(_ any: Any?) -> UInt64? {
        guard let any = any else { return nil }
        if let d = any as? [String: Any] {
            let out = (d["stdout"] as? String) ?? ""
            let err = (d["stderr"] as? String) ?? ""
            if !out.isEmpty || !err.isEmpty { return hash(out + "\u{0000}" + err) }
            // Не Bash: ответ правки или чтения. Ключи в стабильном порядке,
            // иначе один и тот же ответ давал бы разные отпечатки.
            let flat = d.keys.sorted().map { "\($0)=\(d[$0] ?? "")" }.joined(separator: "|")
            return hash(String(flat.prefix(2000)))
        }
        return hash(String(String(describing: any).prefix(2000)))
    }

    // Разбор расшифровки в список вызовов.
    //
    // Один проход: вызовы лежат в строках ассистента, ответы - в следующих
    // строках человека, связаны через tool_use_id. Ответ всегда ПОЗЖЕ
    // вызова, поэтому привязываем вторым проходом по накопленной карте,
    // а не пытаемся угадать порядок.
    static func parse(_ text: String, since: Date) -> [Call] {
        var calls: [Call] = []
        var index: [String: Int] = [:]          // tool_use_id -> место в calls
        var results: [String: UInt64] = [:]

        for line in text.split(separator: "\n") {
            let isCall = line.contains("\"tool_use\"")
            let isResult = line.contains("\"toolUseResult\"")
            guard isCall || isResult else { continue }
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]]

            if isResult {
                guard let sig = resultSignature(row["toolUseResult"]) else { continue }
                for b in content ?? [] where (b["type"] as? String) == "tool_result" {
                    if let id = b["tool_use_id"] as? String { results[id] = sig }
                }
                continue
            }

            guard let ts = row["timestamp"] as? String,
                  let when = UsageParser.parseDate(ts), when >= since,
                  let content = content
            else { continue }

            for b in content where (b["type"] as? String) == "tool_use" {
                guard let tool = b["name"] as? String else { continue }
                let input = (b["input"] as? [String: Any]) ?? [:]
                let (sig, what) = inputSignature(tool: tool, input: input)
                if let id = b["id"] as? String { index[id] = calls.count }
                calls.append(Call(at: when, tool: tool, sig: sig, what: what, result: nil))
            }
        }

        for (id, place) in index {
            if let r = results[id], place < calls.count { calls[place].result = r }
        }
        return calls
    }

    // --- само правило ----------------------------------------------------

    static func check(_ calls: [Call]) -> LoopAlert? {
        // Группируем по отпечатку ввода, идём по времени.
        var history: [UInt64: [Call]] = [:]
        var best: LoopAlert?

        for c in calls.sorted(by: { $0.at < $1.at }) {
            guard mutating.contains(c.tool) else { continue }
            var seen = (history[c.sig] ?? []).filter { c.at.timeIntervalSince($0.at) <= window }
            seen.append(c)
            history[c.sig] = seen
            guard seen.count >= repeats else { continue }

            // Вывод обязан совпасть у всех, у кого он вообще известен.
            // Меньше двух известных - судить не по чему: молчим, а не
            // угадываем. Тревога без основания дороже пропущенной.
            let known = seen.compactMap { $0.result }
            guard known.count >= 2, Set(known).count == 1 else { continue }

            // Берём самый длинный повтор: если крутятся два места сразу,
            // называть надо то, которое крутится сильнее.
            if best == nil || seen.count > best!.count {
                best = LoopAlert(tool: c.tool, count: seen.count, what: c.what)
            }
        }
        return best
    }

    // --- чтение файла ----------------------------------------------------

    // Где лежит расшифровка этой сессии.
    //
    // ИМЯ ФАЙЛА РАВНО sessionId - проверено 12.09.2026 на всех живых
    // сессиях и на четырёх самых свежих файлах: в каждом ровно один
    // sessionId, и он же в имени. В памяти у меня было записано обратное
    // («совпали 2 из 7») - запись была неверной: те пять сессий запущены
    // с --sdk-url, то есть идут НА СТОРОНЕ Anthropic, и локальной
    // расшифровки у них нет вовсе. Это не расхождение имён, а отсутствие
    // файла, и для таких сессий детектор молчит по делу.
    //
    // Каталог проекта из cwd не вычисляем: правило замены «/» на «-»
    // ломается на путях с дефисами и с точкой, а искать по имени файла
    // во всех проектах - один listdir на десяток каталогов.
    static func transcript(sessionID: String, roots: [URL]? = nil) -> URL? {
        guard !sessionID.isEmpty else { return nil }
        let fm = FileManager.default
        for root in roots ?? Transcripts.localRoots() {
            guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for p in projects {
                let candidate = p.appendingPathComponent(sessionID + ".jsonl")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    static func tail(of url: URL, bytes: Int = tailBytes) -> String {
        guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              rv.isRegularFile == true, rv.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let want = Int(min(size, UInt64(bytes)))
        guard want > 0 else { return "" }
        try? handle.seek(toOffset: size - UInt64(want))
        guard let data = try? handle.read(upToCount: want) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // Проверка одной сессии. nil - не крутится, файла нет или судить не по чему.
    static func check(sessionID: String, now: Date = Date(), roots: [URL]? = nil) -> LoopAlert? {
        guard let url = transcript(sessionID: sessionID, roots: roots) else { return nil }
        // Файл, не тронутый в пределах окна, крутиться не может по
        // определению: последний вызов старше окна.
        if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let m = v.contentModificationDate, now.timeIntervalSince(m) > window { return nil }
        let calls = parse(tail(of: url), since: now.addingTimeInterval(-window))
        return check(calls)
    }
}

// Над чем сессия работает.
//
// ЗАЧЕМ. Имя сессии отвечает на «какая это», но не на «что она делает».
// Без переименования командой `/rename` имя выводится из каталога, и все
// рабочие чаты выглядят как «work-81», «work-99» - различить их в списке
// нельзя вовсе.
//
// ОТКУДА. Claude Code пишет в расшифровку строку `last-prompt` с последним
// запросом человека дословно. Это ЛУЧШИЙ ответ, чем у caprock: они
// показывают, какой файл агент трогает сейчас («resizing the dashboard»),
// то есть пересказ действия. Запрос человека говорит, ЗАЧЕМ сессия
// существует, и он же - то, что человек сам вспомнит, увидев строку.
//
// Брать тему из содержания разговора я раньше считал невозможным: в памяти
// было записано, что sessionId не совпадает с именем файла расшифровки.
// Запись оказалась неверной - см. оговорку у Loops.transcript.
enum Activity {

    // Сколько знаков отдаём. Строка меню и так делится между именем,
    // состоянием и возрастом; всё, что длиннее, обрежется на показе,
    // а на удалённой машине ещё и поедет по ssh впустую.
    static let limit = 60

    // Последний запрос человека в этой сессии.
    //
    // Ищем с КОНЦА: строка `last-prompt` переписывается на каждый новый
    // запрос, и в хвосте их несколько. Нужна последняя, а не первая
    // найденная - иначе трей покажет позапрошлую задачу и будет врать
    // тем убедительнее, чем дольше идёт сессия.
    static func lastPrompt(_ text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"last-prompt\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (row["type"] as? String) == "last-prompt",
                  let p = row["lastPrompt"] as? String
            else { continue }
            // Схлопываем ЛЮБЫЕ пробельные подряд, а не только переводы
            // строк. Поймано сверкой с питоном удалённой стороны: там
            // `" ".join(p.split())`, то есть схлопывается всё, а здесь
            // рвались только переводы - и двойной пробел внутри запроса
            // давал строку на знак длиннее. Одна и та же сессия
            // подписывалась бы по-разному в зависимости от того, с какой
            // машины на неё смотрят, а из-за сдвига обрезки расходился
            // ещё и хвост.
            let one = p.split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return one.isEmpty ? nil : String(one.prefix(limit))
        }
        return nil
    }

    static func of(sessionID: String, roots: [URL]? = nil) -> String? {
        guard let url = Loops.transcript(sessionID: sessionID, roots: roots) else { return nil }
        return lastPrompt(Loops.tail(of: url))
    }
}
