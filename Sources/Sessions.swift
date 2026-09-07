import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Кто сейчас работает, а кто ждёт ответа.
//
// ЗАЧЕМ. Процент лимита отвечает на «работать дальше или подождать».
// Это другой вопрос: «не стоит ли агент?». Сессия, упёршаяся в разрешение,
// лимита не тратит вовсе - она тратит время, и в трее этого не было видно
// никак. Час простоя стоит дороже процента лимита.
//
// ОТКУДА. Claude Code сам пишет на каждую свою сессию файл
// ~/.claude/sessions/<pid>.json. Ни сети, ни сокета, ни разбора чужого
// протокола здесь не нужно.
//
// ЧТО ПРОВЕРЕНО, А ЧТО НЕТ (важно, потому что схема разная от запуска
// к запуску одной и той же версии):
//   * [ФАКТ] поля pid, cwd, name, entrypoint, startedAt, kind есть всегда -
//     7 живых файлов, версия CLI 2.1.241;
//   * [ФАКТ] поля status/waitingFor/statusUpdatedAt пишутся УСЛОВНО. В коде
//     CLI это `...e.status!==void 0 && {statusUpdatedAt:r}` - то есть их
//     нет, пока статус не выставлен. У сессий kind=interactive,
//     entrypoint=sdk-cli (боты) он не выставлен ни у одной;
//   * [ПРЕДПОЛОЖЕНИЕ] интерактивный терминал статус выставляет. Проверить
//     это можно только на живом Маке - здесь такого запуска нет.
//
// Поэтому состояний четыре, а не три: «сказано, что простаивает» и «статус
// не сообщён» - разные вещи. Свалить их в одно значит показывать вечное
// «простаивает» там, где мы просто не знаем, и человек будет верить
// индикатору, который ничего не измеряет. Так у codenotch и сделано -
// у них unknown склеен с idle, и на sdk-сессиях их индикатор всегда
// показывает «простаивает».
enum SessionState: String {
    case busy       // работает
    case waiting    // ждёт человека
    case idle       // сказано: простаивает
    case unknown    // статуса в файле нет

    // Порядок важности: в меню сверху то, что требует действия.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .busy:    return 1
        case .idle:    return 2
        case .unknown: return 3
        }
    }

    var word: String {
        switch self {
        case .busy:    return L("работает", "working")
        case .waiting: return L("ждёт меня", "waiting on me")
        case .idle:    return L("простаивает", "idle")
        case .unknown: return L("статус не сообщён", "no status reported")
        }
    }
}

struct AgentSession: Equatable {
    var pid: Int
    var name: String
    var folder: String
    var surface: String        // Terminal, VS Code, Desktop, SDK
    var state: SessionState
    var waitingFor: String?    // чего именно ждёт, если сказано
    var since: Date?           // когда статус сменился
    // Пусто - своя машина, иначе адрес хоста. Именно пусто, а не слово
    // «эта»: слово пришлось бы переводить, а переведённое слово в роли
    // признака ломается ровно в одном языке из двух.
    var machine: String
}

struct SessionSummary: Equatable {
    var busy = 0
    var waiting = 0
    var idle = 0
    var unknown = 0

    var total: Int { return busy + waiting + idle + unknown }

    // Короткая сводка для строки меню и заголовка раздела.
    //
    // Молчит, когда сказать нечего: «работает 0 · ждёт 0» занимает место
    // и не отвечает ни на что. А вот про unknown молчать нельзя, если
    // это ВСЁ, что есть: иначе пустая сводка читается как «никто не
    // работает», хотя правда - «мы не знаем ни про одну».
    var text: String {
        var parts: [String] = []
        if waiting > 0 { parts.append(L("ждёт меня \(waiting)", "waiting \(waiting)")) }
        if busy > 0 { parts.append(L("работает \(busy)", "working \(busy)")) }
        if parts.isEmpty && unknown > 0 && idle == 0 {
            return L("сессий \(unknown), статуса нет", "\(unknown) sessions, no status")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

enum Sessions {

    static var localDir: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    // --- разбор одного файла ------------------------------------------------
    //
    // Разбор намеренно снисходительный: файл пишет чужая программа на своём
    // расписании выпусков, и незнакомое поле не должно стоить нам сессии,
    // которую мы могли показать. Обязательны только pid и cwd - без них
    // это не запись о сессии.
    static func parse(json: [String: Any], machine: String = "") -> AgentSession? {
        guard let pid = intValue(json["pid"]), let cwd = json["cwd"] as? String else { return nil }

        let status = json["status"] as? String
        let tempo = json["tempo"] as? String     // нормализованная форма, когда есть
        let state: SessionState
        switch (tempo, status) {
        case ("blocked", _), (_, "waiting"): state = .waiting
        case ("active", _), (_, "busy"):     state = .busy
        case ("idle", _), (_, "idle"):        state = .idle
        default:
            // Ни того, ни другого. Это НЕ «простаивает» - это «не сказано».
            state = (status == nil && tempo == nil) ? .unknown : .idle
        }

        let folder = (cwd as NSString).lastPathComponent
        let millis = doubleValue(json["statusUpdatedAt"]) ?? doubleValue(json["updatedAt"])

        return AgentSession(
            pid: pid,
            name: (json["name"] as? String) ?? folder,
            folder: folder,
            surface: surface(json["entrypoint"] as? String),
            state: state,
            waitingFor: (json["waitingFor"] as? String) ?? (json["needs"] as? String),
            since: millis.map { Date(timeIntervalSince1970: $0 / 1000) },
            machine: machine)
    }

    // Через что запущено. Отвечает на «где мне искать это окно».
    static func surface(_ entrypoint: String?) -> String {
        switch entrypoint {
        case "claude-desktop", "claude-desktop-3p": return "Desktop"
        case "claude-vscode":                       return "VS Code"
        case "sdk-cli", "sdk":                      return "SDK"
        case nil:                                   return ""
        default:                                    return "Terminal"
        }
    }

    // --- обход каталога -----------------------------------------------------
    //
    // Мёртвые записи отбрасываются здесь, а не в меню: файл остаётся лежать
    // после падения процесса, и без проверки живости трей показывал бы
    // «работает» на сессии, которой нет неделю. Проверка - kill(pid, 0):
    // сигнала не посылает, только спрашивает, есть ли такой процесс.
    //
    // Чужой процесс с тем же pid отличить нельзя: startedAt в файле есть,
    // а времени старта процесса без него нам никто не даёт (procStart на
    // Linux - тики, на macOS - строка ctime; одно и то же поле, разные типы).
    // Поэтому берём поправку на возраст: запись старше суток при живом pid
    // подозрительна, и мы её не показываем.
    static let maxAge: TimeInterval = 24 * 3600

    static func read(dir: URL? = nil, now: Date = Date(),
                     machine: String = "") -> [AgentSession] {
        let d = dir ?? localDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        var out: [AgentSession] = []
        for name in names where name.hasSuffix(".json") {
            let url = d.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let s = parse(json: json, machine: machine),
                  isAlive(pid: s.pid)
            else { continue }
            if let started = doubleValue(json["startedAt"]),
               now.timeIntervalSince(Date(timeIntervalSince1970: started / 1000)) > maxAge {
                continue
            }
            out.append(s)
        }
        return sorted(out)
    }

    // Сначала то, что требует действия, потом по свежести. Порядок
    // фиксирован, чтобы строки не прыгали между открытиями меню.
    static func sorted(_ list: [AgentSession]) -> [AgentSession] {
        return list.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            let ta = a.since?.timeIntervalSince1970 ?? 0
            let tb = b.since?.timeIntervalSince1970 ?? 0
            if ta != tb { return ta > tb }
            return a.pid < b.pid
        }
    }

    static func summary(_ list: [AgentSession]) -> SessionSummary {
        var s = SessionSummary()
        for x in list {
            switch x.state {
            case .busy:    s.busy += 1
            case .waiting: s.waiting += 1
            case .idle:    s.idle += 1
            case .unknown: s.unknown += 1
            }
        }
        return s
    }

    // --- строки для меню ----------------------------------------------------
    //
    // Текст собирается здесь, а не в MenuBar: там AppKit, и здесь это
    // единственная часть раздела, в которой можно ошибиться молча -
    // просчитаться в оговорке или показать «простаивает» там, где статуса
    // нет. Меню только раскладывает готовые строки по пунктам.
    struct SessionLines: Equatable {
        var header = ""
        var rows: [String] = []
        var notes: [String] = []
    }

    // Сколько сессий показываем. Выше этого меню растёт вниз без предела,
    // а ответ на «кто ждёт» уже дан: ждущие стоят первыми.
    static let maxRows = 6

    static func lines(_ list: [AgentSession], nameLimit: Int = 10,
                      remoteHost: String = "", remoteScanAt: Date? = nil) -> SessionLines {
        var out = SessionLines()
        guard !list.isEmpty else { return out }

        let s = summary(list)

        // Если статуса нет НИ У ОДНОЙ - раздел молчит целиком.
        //
        // Проверено живым прогоном: на этой машине 5 живых сессий, у всех
        // пяти статус не выставлен, и раздел выходил из пяти одинаковых
        // строк «статус не сообщён». Раздел, который каждый раз отвечает
        // «не знаю», хуже отсутствующего: место занимает, на свой же
        // вопрос не отвечает, и человек привыкает пролистывать его мимо.
        //
        // Молчать при этом нельзя вообще нигде - иначе выключенная фича
        // выглядит как «никто не ждёт». Поэтому объяснение живёт в
        // `--doctor`: там прямо сказано, что статус не пишет ни одна
        // сессия и раздел будет пуст. Меню показывает только то, на что
        // может ответить; диагностика говорит, почему оно молчит.
        if s.total > 0 && s.unknown == s.total { return out }

        let title = L("Сессии", "Sessions")
        out.header = s.text.isEmpty ? title : title + " \u{00B7} " + s.text

        // Сортируем ЗДЕСЬ, а не надеемся на вызывающего. Обещание раздела -
        // «то, что требует действия, стоит первым», и держать его должно
        // то же место, которое его даёт. Тест это и поймал: список пришёл
        // в порядке чтения каталога, и ждущая сессия стояла второй.
        let ordered = sorted(list)
        let shown = Array(ordered.prefix(maxRows))
        for x in shown {
            // Указатель - только у того, что требует действия. У остальных
            // пробел той же ширины, иначе строки разъезжаются по левому краю.
            let mark = x.state == .waiting ? "\u{25B8} " : "  "
            var line = mark
            // Своя машина - пустая строка, а не слово «эта». Держать
            // здесь ПЕРЕВЕДЁННОЕ слово и сравнивать с ним значит завести
            // ошибку, которая видна только в одном языке: под английской
            // локалью «эта» перестаёт равняться «this», и своя сессия
            // начинает подписываться чужим адресом.
            if !x.machine.isEmpty { line += x.machine + ": " }
            line += Fmt.clip(x.name, nameLimit)
            if !x.surface.isEmpty { line += " \u{00B7} " + x.surface }
            line += " \u{00B7} " + x.state.word
            if x.state == .waiting, let w = x.waitingFor, !w.isEmpty {
                line += ": " + Fmt.clip(w, 24)
            }
            if let t = x.since { line += " \u{00B7} " + Fmt.ago(t) }
            out.rows.append(line)
        }
        if ordered.count > shown.count {
            out.rows.append("  " + L("и ещё \(ordered.count - shown.count)",
                                     "\(ordered.count - shown.count) more"))
        }

        // Оговорки. Молчать про них нельзя: раздел, который показывает
        // «простаивает» на сессии, про которую нам ничего не сказали, -
        // это индикатор, который ничего не измеряет, а выглядит как
        // измеряющий.
        if s.unknown > 0 {
            out.notes.append(L(
                "статус пишут не все запуски: у \(s.unknown) его нет, работает она или стоит - неизвестно",
                "not every launch reports status: \(s.unknown) without it - working or stalled is unknown"))
        }
        if !remoteHost.isEmpty, list.contains(where: { $0.machine == remoteHost }) {
            let age = remoteScanAt.map { " \u{00B7} " + Fmt.ago($0) + L(" назад", " ago") } ?? ""
            out.notes.append(L("\(remoteHost) - по последнему обходу\(age)",
                               "\(remoteHost) - as of the last scan\(age)"))
        }
        return out
    }

    static func isAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        // EPERM - процесс есть, но чужой. Живой.
        return errno == EPERM
    }

    // --- мелочи разбора -----------------------------------------------------
    //
    // JSON от чужой программы отдаёт числа то Int, то Double, то строкой.
    // Свой разбор здесь, а не `as? Int`: один неверный каст стоит сессии.
    static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        return nil
    }

    static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
