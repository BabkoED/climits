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
//   * [ФАКТ] интерактивный запуск статус ВЫСТАВЛЯЕТ - подтверждено на Маке
//     Антона 07.09.2026: `--doctor` показал «2 живых: простаивает 1, без
//     статуса 1». То есть раздел не пустой и не бесполезный: одна сессия
//     назвала своё состояние, вторая (запуск через SDK) промолчала.
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

    // Ключ к расшифровке этой сессии. Пусто у сессий, которые идут на
    // стороне Anthropic (запуск с --sdk-url): у них локального файла нет
    // вовсе, и ни занятия, ни кручения по ним не узнать.
    var sessionID: String = ""

    // Над чем работает - последний запрос человека. Пусто, если
    // расшифровки нет или показ выключен.
    var activity: String = ""

    // Крутится на месте. nil - не крутится или судить не по чему.
    var loop: LoopAlert?
    // Пусто - своя машина, иначе адрес хоста. Именно пусто, а не слово
    // «эта»: слово пришлось бы переводить, а переведённое слово в роли
    // признака ломается ровно в одном языке из двух.
    var machine: String

    // Сколько памяти держит эта сессия: в ОЗУ и в свопе, мегабайтами.
    //
    // ЗАЧЕМ ЭТО ЗДЕСЬ. Гибернация простаивающих сессий на сервере работает
    // автоматически (выдавливание страниц раз в минуту, порог час), но
    // увидеть её работу было НЕГДЕ. Отсюда и родилось желание кнопки
    // «усыпить»: механизм есть, а обратной связи нет. Своп в строке и
    // есть эта обратная связь - у обработанной сессии он больше ОЗУ.
    // Заодно станет видно, если автоматика однажды встанет: сейчас узнать
    // об этом неоткуда вовсе.
    //
    // Ноль означает «не измерили», а не «нуль байт»: на macOS своп по
    // процессу не отдаётся вовсе, и рисовать там «0 в свопе» было бы
    // ложью про систему, а не про сессию.
    var rssMB: Int = 0
    var swapMB: Int = 0

    // «113 МБ», «113+262 МБ». Пусто, если мерить не удалось.
    var memoryText: String {
        guard rssMB > 0 else { return "" }
        if swapMB > 0 { return "\(rssMB)+\(swapMB) " + L("МБ", "MB") }
        return "\(rssMB) " + L("МБ", "MB")
    }
}

struct SessionSummary: Equatable {
    var busy = 0
    var waiting = 0
    var idle = 0
    var unknown = 0

    var rssMB = 0
    var swapMB = 0

    var total: Int { return busy + waiting + idle + unknown }

    // Сколько держат все вместе. Отвечает на «что грузит память сейчас»
    // одним числом, и ему место в заголовке раздела: там есть ширина.
    //
    // Гигабайты от 1024 МБ, иначе «1712 МБ» не читается порядком величины -
    // а вопрос именно про порядок: влезет ещё одна сессия или нет.
    var memoryText: String {
        guard rssMB > 0 else { return "" }
        func gb(_ mb: Int) -> String {
            if mb < 1024 { return "\(mb) " + L("МБ", "MB") }
            let s = String(format: "%.1f", Double(mb) / 1024)
            return L(s.replacingOccurrences(of: ".", with: ","), s) + L(" ГБ", " GB")
        }
        if swapMB > 0 {
            return gb(rssMB) + L(" + ", " + ") + gb(swapMB) + L(" в свопе", " swapped")
        }
        return gb(rssMB)
    }

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

// Память машины целиком: сколько занято и сколько осталось.
//
// ЗАЧЕМ РЯДОМ С СЕССИЯМИ. Сумма по сессиям отвечает на «сколько держат
// они», но не на «сколько ещё можно». Второе - это про машину, и без него
// первое не с чем сравнить: 1 ГБ на сервере с 4 ГБ и на маке с 32 - разные
// новости.
struct MachineMemory: Equatable {
    var totalMB = 0
    var availableMB = 0      // 0 - не измеряли (см. ниже про macOS)
    var swapTotalMB = 0
    var swapUsedMB = 0

    var isEmpty: Bool { return totalMB == 0 }

    // «ОЗУ занято 2,6 из 3,8 ГБ · своп 1,7 из 6,9 ГБ».
    //
    // Заполняется ТОЛЬКО с удалённой машины: там и бывают сложности с
    // памятью, а на маке её обычно много. Ветка без availableMB осталась
    // на случай, если /proc/meminfo на той стороне отдаст не всё.
    var text: String {
        guard totalMB > 0 else { return "" }
        func gb(_ mb: Int) -> String {
            let s = String(format: "%.1f", Double(mb) / 1024)
            return L(s.replacingOccurrences(of: ".", with: ","), s)
        }
        var s = L("ОЗУ ", "RAM ")
        if availableMB > 0 {
            s += L("занято \(gb(totalMB - availableMB)) из \(gb(totalMB)) ГБ",
                   "\(gb(totalMB - availableMB)) of \(gb(totalMB)) GB used")
        } else {
            s += L("всего \(gb(totalMB)) ГБ", "\(gb(totalMB)) GB total")
        }
        if swapTotalMB > 0 {
            s += L(" \u{00B7} своп \(gb(swapUsedMB)) из \(gb(swapTotalMB)) ГБ",
                   " \u{00B7} swap \(gb(swapUsedMB)) of \(gb(swapTotalMB)) GB")
        }
        return s
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
            sessionID: (json["sessionId"] as? String) ?? "",
            activity: (json["activity"] as? String) ?? "",
            loop: loopAlert(json),
            machine: machine)
    }

    // Тревога о кручении, если её посчитала та сторона.
    //
    // Своя машина сюда ничего не кладёт - там детектор гоняется по живой
    // расшифровке в enrich(). Удалённая считает у себя и присылает готовый
    // итог: гонять детектор здесь значило бы тянуть по ssh хвосты
    // расшифровок вместо трёх чисел.
    static func loopAlert(_ json: [String: Any]) -> LoopAlert? {
        guard let d = json["loop"] as? [String: Any],
              let tool = d["tool"] as? String,
              let count = intValue(d["count"]), count > 0
        else { return nil }
        return LoopAlert(tool: tool, count: count, what: (d["what"] as? String) ?? "")
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

    // ЗАМЕРА ПАМЯТИ НА СТОРОНЕ ПРИЛОЖЕНИЯ ЗДЕСЬ НЕТ - и это решение,
    // а не пробел.
    //
    // Слово Антона 07.09.2026: на маке это не нужно, там у людей памяти
    // много; сложности с памятью бывают на удалённых серверах. Значит
    // мерить локально незачем вовсе - а вместе с замером ушли и запуск
    // `ps`, и `sysctl`, и разбор их вывода. Числа приезжают только с той
    // стороны, где они что-то значат: их считает питон в RemoteScan,
    // читая /proc той машины.
    //
    // rssMB/swapMB у сессии и MachineMemory при этом остались: заполняет
    // их ответ сервера.

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

    // Дочитать по расшифровкам то, чего нет в файле сессии: над чем
    // работает и не крутится ли на месте.
    //
    // ОТДЕЛЬНЫМ ШАГОМ, а не внутри read(), по двум причинам. Первая:
    // read() читает десяток файлов по полкилобайта, а это - по полмегабайта
    // хвоста на сессию, и включаться оно должно по галочке, а не всегда.
    // Вторая: так его видно в тестах - на вход список, на выход список,
    // без файловой системы в середине для тех полей, что уже заполнены.
    //
    // Удалённых сессий здесь нет: у них machine непустой, а расшифровки
    // лежат на той машине. Их считает питон на той стороне и присылает
    // готовым - см. loopAlert().
    static func enrich(_ list: [AgentSession], watchLoops: Bool, showActivity: Bool,
                       now: Date = Date(), roots: [URL]? = nil) -> [AgentSession] {
        guard watchLoops || showActivity else { return list }
        return list.map { s in
            guard s.machine.isEmpty, !s.sessionID.isEmpty else { return s }
            var out = s
            if watchLoops { out.loop = Loops.check(sessionID: s.sessionID, now: now, roots: roots) }
            if showActivity, out.activity.isEmpty {
                out.activity = Activity.of(sessionID: s.sessionID, roots: roots) ?? ""
            }
            return out
        }
    }

    // Сначала то, что требует действия, потом по свежести. Порядок
    // фиксирован, чтобы строки не прыгали между открытиями меню.
    static func sorted(_ list: [AgentSession]) -> [AgentSession] {
        return list.sorted { a, b in
            // Крутящаяся идёт выше всех, даже выше ждущей. Ждущая стоит
            // бесплатно и дождётся; эта тратит лимит и деньги всё время,
            // пока её не видно.
            let la = a.loop != nil, lb = b.loop != nil
            if la != lb { return la }
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
            s.rssMB += x.rssMB
            s.swapMB += x.swapMB
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

    // Предел ШИРИНЫ строки, в знаках.
    //
    // Поймано на снимке из CI: строка «budget-app · Terminal · waiting on
    // me: write permission · 4m» вышла шире всех строк лимитов, и меню
    // раздвинулось под неё. Ровно этот рост ширины от содержимого был
    // закрыт в 1.6.2, и заводить его заново с другой стороны нельзя.
    // И имя проекта, и текст просьбы приходят снаружи - значит ширина
    // без предела задаётся чужой программой, а не нами.
    static let maxLine = 46

    // Предел длины ИМЕНИ сессии - свой, а не общий с колонкой лимитов.
    //
    // Там 10 знаков, потому что имена моделей короткие и стоят в колонке.
    // Здесь имя человек задаёт сам командой `/rename` в Claude Code, и
    // десяти знаков на осмысленное название не хватает: «Тариф Альфы»
    // обрезалось до «Тариф Аль…». Строка сессии не колонка, ширину её
    // держит maxLine.
    static let nameLimit = 22

    // Меньше этого просьбу не показываем вовсе: огрызок в три знака -
    // шум, а не сведения.
    static let minWaitingFor = 6

    // Сборка одной строки под предел ширины.
    //
    // Порядок жертв неочевиден, поэтому он здесь и закреплён тестами:
    // первым уходит «через что запущено» целиком, потом урезается текст
    // просьбы, и только в самом конце страдает возраст.
    //
    // Возраст стоит выше просьбы намеренно. «Ждёт 4м» и «ждёт 2ч»
    // требуют разного, а текст просьбы всё равно придётся читать в самом
    // окне - строка меню только зовёт туда. Первая версия ставила их
    // наоборот, и длинная просьба вытесняла возраст; поймал тест.
    // memory показывается ВМЕСТО «чего ждёт», а не рядом.
    //
    // Они отвечают на разные вопросы, и никогда на оба сразу: у ждущей
    // сессии важно, чего она хочет от меня, у остальных - сколько памяти
    // они держат. Показать оба значит раздвинуть меню под строку, в
    // которой половина всегда лишняя.
    static func composeLine(mark: String, machine: String, name: String,
                            surface: String, state: String,
                            waitingFor: String?, age: String,
                            memory: String = "",
                            activity: String = "",
                            loop: LoopAlert? = nil) -> String {
        var head = mark
        if !machine.isEmpty { head += machine + ": " }
        head += name

        let surfacePart = surface.isEmpty ? "" : " \u{00B7} " + surface

        // Пустое состояние - это «статус не сообщён», и слов на него не
        // тратится вовсе.
        //
        // Поймано на снимке из CI: «no status reported» занимало 18 знаков,
        // и у СЕРВЕРНОЙ сессии память в строку уже не влезала - то есть
        // именно там, где своп важнее всего. Отсутствие слова само по себе
        // и есть ответ «мы не знаем», а объясняет его оговорка под списком.
        var tail = ""
        if !state.isEmpty {
            tail = " \u{00B7} " + state
            // Возраст прижат к состоянию без разделителя: «ждёт меня 4м» -
            // это один ответ, а «ждёт меня · 4м» читается как два.
            if !age.isEmpty { tail += " " + age }
        } else if !age.isEmpty {
            tail = " \u{00B7} " + age
        }

        // ХВОСТ СТРОКИ - РОВНО ОДНА ЗАМЕТКА, И ВОТ ПОЧЕМУ ИМЕННО ЭТА.
        //
        // Место в строке одно, а сказать хочется четыре вещи. Порядок здесь
        // не по важности вообще, а по тому, какая из них отвечает на вопрос
        // «что мне с этой сессией делать прямо сейчас»:
        //
        //   1. крутится    - единственное, что требует вмешаться немедленно:
        //                    сессия тратит лимит и не двигается;
        //   2. чего ждёт   - требует меня, но она хотя бы не жжёт лимит;
        //   3. память      - про машину, а не про задачу; приезжает только
        //                    с удалённой стороны, где память и бывает узкой;
        //   4. над чем     - ничего не требует, просто отвечает «какая это
        //                    из шести одинаковых work-NN».
        //
        // Четвёртое стоит последним и вытесняется первыми тремя - и это
        // правильно: у локальных сессий память не меряется вовсе, значит
        // хвост у них свободен, и занятие займёт пустое место, а не
        // чужое. Ничего из того, что было в строке раньше, не подвинулось.
        struct Note { var text: String; var sep: String; var clippable: Bool }
        let note: Note? = {
            if let l = loop { return Note(text: l.text, sep: " \u{00B7} ", clippable: false) }
            if let w = waitingFor, !w.isEmpty { return Note(text: w, sep: ": ", clippable: true) }
            if !memory.isEmpty { return Note(text: memory, sep: " \u{00B7} ", clippable: false) }
            if !activity.isEmpty { return Note(text: activity, sep: " \u{00B7} ", clippable: true) }
            return nil
        }()

        // Место под заметку бронируется ДО того, как решается судьба
        // «через что»: иначе «Terminal» занимает ровно те знаки, на
        // которых должно стоять, чего сессия хочет. Первая версия
        // считала в обратном порядке - объявленный порядок жертв
        // расходился с тем, что делал код, и поймал это тест.
        //
        // Обрезаемой заметке брони хватает минимальной: остаток она
        // доберёт сама. Необрезаемой нужна вся её длина сразу - «113+26»
        // вместо «113+262 МБ» это неверное число, а не сокращённое,
        // и то же верно про «Bash ×4».
        let needsRoom: Int = {
            guard let n = note else { return 0 }
            return n.clippable ? minWaitingFor + n.sep.count : n.sep.count + n.text.count
        }()
        let withSurface = head + surfacePart + tail
        var line = withSurface.count + needsRoom <= maxLine ? withSurface : head + tail

        if let n = note {
            let room = maxLine - line.count - n.sep.count
            if n.clippable {
                if room >= minWaitingFor { line += n.sep + Fmt.clip(n.text, room) }
            } else if room >= n.text.count {
                line += n.sep + n.text
            }
        }
        return Fmt.clip(line, maxLine)
    }

    static func lines(_ list: [AgentSession], nameLimit: Int = nameLimit,
                      remoteScanAt: Date? = nil,
                      machines: [String: MachineMemory] = [:]) -> SessionLines {
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
        //
        // НО молчать только когда сказать нечего СОВСЕМ. Раздел отвечает
        // теперь на два вопроса, и второй - «что грузит память» - от
        // статуса не зависит вовсе. Поймано живым прогоном: на сервере
        // все сессии без статуса, и раздел молчал вместе с числами
        // памяти, ради которых его и расширяли.
        if s.total > 0 && s.unknown == s.total && s.rssMB == 0 { return out }

        let title = L("Сессии", "Sessions")
        var head = s.text.isEmpty ? title : title + " \u{00B7} " + s.text
        // Общая память - в заголовок: он и так подписью, ширина там есть,
        // а вопрос «влезет ли ещё одна сессия» именно про сумму.
        if !s.memoryText.isEmpty { head += " \u{00B7} " + s.memoryText }
        out.header = head

        // Сортируем ЗДЕСЬ, а не надеемся на вызывающего. Обещание раздела -
        // «то, что требует действия, стоит первым», и держать его должно
        // то же место, которое его даёт. Тест это и поймал: список пришёл
        // в порядке чтения каталога, и ждущая сессия стояла второй.
        let ordered = sorted(list)
        let shown = Array(ordered.prefix(maxRows))
        for x in shown {
            // Указатель - только у того, что требует действия. У остальных
            // пробел той же ширины, иначе строки разъезжаются по левому краю.
            // Своя машина - пустая строка, а не слово «эта». Держать
            // здесь ПЕРЕВЕДЁННОЕ слово и сравнивать с ним значит завести
            // ошибку, которая видна только в одном языке: под английской
            // локалью «эта» перестаёт равняться «this», и своя сессия
            // начинает подписываться чужим адресом.
            out.rows.append(composeLine(
                // Указатель и у крутящейся: она требует того же, что и
                // ждущая, - чтобы на неё посмотрели. Разница в том, что
                // ждущая стоит бесплатно, а эта тратит.
                mark: (x.state == .waiting || x.loop != nil) ? "\u{25B8} " : "  ",
                machine: x.machine,
                name: Fmt.clip(x.name, nameLimit),
                surface: x.surface,
                state: x.state == .unknown ? "" : x.state.word,
                waitingFor: x.state == .waiting ? x.waitingFor : nil,
                age: x.since.map { Fmt.ago($0) } ?? "",
                memory: x.memoryText,
                activity: x.activity,
                loop: x.loop))
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
            // Короче некуда без потери смысла: длинная оговорка была самой
            // широкой строкой в меню - шире, чем сами строки сессий.
            out.notes.append(L("\(s.unknown) без статуса: работает или стоит - неизвестно",
                               "\(s.unknown) without status: working or stalled unknown"))
        }
        // Память машины - после списка сессий: сумма по сессиям отвечает
        // «сколько держат они», а это - «сколько ещё можно». Без второго
        // первое не с чем сравнить.
        //
        // Только удалённых машин. Своя не показывается намеренно - см.
        // комментарий у отсутствующего замера выше.
        //
        // Порядок по имени хоста, а не по словарю: иначе строки прыгали бы
        // между открытиями меню.
        for host in machines.keys.sorted() {
            if let m = machines[host], !m.isEmpty {
                out.notes.append(host + ": " + m.text)
            }
        }

        // Оговорка про свежесть - ОДНА на все машины, а не на каждую:
        // обход у них общий, и повторять её N раз значит занять N строк
        // одним и тем же фактом.
        let hosts = Set(list.map { $0.machine }).subtracting([""]).sorted()
        if !hosts.isEmpty {
            let age = remoteScanAt.map { " \u{00B7} " + Fmt.ago($0) + L(" назад", " ago") } ?? ""
            let names = hosts.joined(separator: ", ")
            out.notes.append(L("\(names) - по последнему обходу\(age)",
                               "\(names) - as of the last scan\(age)"))
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
