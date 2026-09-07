import Foundation

// Форматирование: сколько осталось, шкала, подстановка макросов.

// Уровень тревоги: 0 спокойно, 1 внимание, 2 тревога.
// Здесь, а не в Palette: этим пользуется и терминальный режим, где AppKit нет.
// Severity от сервера главнее наших порогов - пороги мы выдумали, а severity
// считает тот, кто считает и сам лимит.
func styleLevel(percent: Int, severity: String) -> Int {
    switch severity.lowercased() {
    case "critical": return 2
    case "warning":  return 1
    default: break
    }
    if percent >= Prefs.alertAt { return 2 }
    if percent >= Prefs.warnAt { return 1 }
    return 0
}

enum Fmt {
    // «2ч 14м», «1д 4ч», «~1м». Секунды не показываем никогда: на экране,
    // который обновляется раз в пять минут, они всё равно врут.
    //
    // Последняя минута - «~1м», а не «вот-вот»: тильда говорит ровно то же
    // самое, но числом, а по числу можно решать, успеваешь ты дописать
    // запрос или нет.
    //
    // Дробь ОТБРАСЫВАЕТСЯ, а не округляется: это остаток, и завышать его
    // нельзя. «1м» при 119 секундах - правда с запасом в свою пользу,
    // «2м» - обещание минуты, которой нет.
    static func left(_ date: Date?) -> String {
        guard let d = date else { return "\u{2014}" }
        let secs = Int(d.timeIntervalSinceNow)
        if secs < 60 { return L("~1м", "~1m") }
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        if days > 0 { return "\(days)\(L("д", "d")) \(hours)\(L("ч", "h"))" }
        if hours > 0 { return String(format: "%d%@ %02d%@", hours, L("ч", "h"), mins, L("м", "m")) }
        return "\(mins)\(L("м", "m"))"
    }

    // Сколько прошло: «3м», «1ч 20м», «2д 4ч». Зеркало left, и намеренно
    // не через него: там дробь отбрасывается в свою пользу, потому что это
    // ОСТАТОК и завышать его нельзя. Здесь наоборот - это возраст, и
    // занижать его нельзя: сессия, которая ждёт «59с», должна называться
    // минутой, а не нулём. Одна функция на оба случая округляла бы одну
    // из двух сторон неверно.
    static func ago(_ date: Date) -> String {
        let secs = max(0, Int(-date.timeIntervalSinceNow))
        if secs < 60 { return L("<1м", "<1m") }
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        if days > 0 { return "\(days)\(L("д", "d")) \(hours)\(L("ч", "h"))" }
        if hours > 0 { return String(format: "%d%@ %02d%@", hours, L("ч", "h"), mins, L("м", "m")) }
        return "\(mins)\(L("м", "m"))"
    }

    // Голый отсчёт до сброса: «2ч 14м», «~1м». Слова «через» здесь нет
    // намеренно - строка стоит рядом со шкалой лимита, и что это остаток,
    // видно из места. Слово занимало знак, который нужнее цифрам.
    // Там, где места много и контекста нет - в уведомлении, - «через»
    // приписывается на месте.
    static func untilReset(_ date: Date?) -> String {
        guard let d = date else { return "\u{2014}" }
        return left(d)
    }

    // «пн 03:00» - когда именно. Полезно для недельных окон: «через 4д 2ч»
    // само по себе не говорит, попадёт сброс на рабочий день или на выходной.
    static func clock(_ date: Date?) -> String {
        guard let d = date else { return "" }
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: d)
        return weekdayShort(wd) + " " + hhmm(d)
    }

    // Формат времени берём у системы, а не зашиваем «HH:mm»: у половины мира
    // часы двенадцатичасовые, и жёсткий формат там читается как ошибка.
    static func hhmm(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f.string(from: date)
    }

    // 1_234_567 -> «1,2м», 1_739_000_000 -> «1,7млрд». В меню важно оценить
    // порядок, а не пересчитать до штуки.
    //
    // Ступень «млрд» обязательна: без неё недельный расход у активного
    // аккаунта - обычно за миллиард токенов - показывался бы четырёхзначным
    // «1617,3м». Это не ошибка в счёте, но читается как она: сама идея
    // «компактной записи» перестаёт работать ровно там, где нужнее всего.
    //
    // Разделитель дробной части берётся по языку: «1.2м» в русской строке
    // читается как опечатка, а не как число.
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000_000 {
            let s = String(format: "%.1f", Double(n) / 1_000_000_000)
            return L(s.replacingOccurrences(of: ".", with: ","), s) + L("млрд", "B")
        }
        if n >= 1_000_000 {
            let s = String(format: "%.1f", Double(n) / 1_000_000)
            return L(s.replacingOccurrences(of: ".", with: ","), s) + L("м", "M")
        }
        if n >= 1_000 { return "\(n / 1000)" + L("к", "K") }
        return "\(n)"
    }

    // Столбики за последние дни: «▁▃█▂▁▄▇».
    //
    // Зачем: «≈$12 за окно» не отвечает на вопрос, который человек задаёт
    // на самом деле, - это много или как обычно. Без базы для сравнения
    // любая цифра читается как тревожная.
    //
    // Высота считается от МАКСИМУМА недели, а не от какого-то абсолюта:
    // абсолюта здесь нет и быть не может, лимит в токенах никто не публикует.
    // График отвечает только на «как относительно своих же дней».
    //
    // Ноль рисуется точкой, а не самым низким столбиком: «ничего» и
    // «немного» - разные ответы, а нижний блок Unicode выглядит как
    // «немного».
    static func spark(_ values: [Int]) -> String {
        let glyphs = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}",
                      "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
        guard let top = values.max(), top > 0 else {
            return String(repeating: "\u{00B7}", count: values.count)
        }
        return values.map { v -> String in
            guard v > 0 else { return "\u{00B7}" }
            // Округляем вверх: день с одним запросом должен быть виден
            // хоть чем-то, иначе график врёт про пустой день.
            let idx = Int(ceil(Double(v) / Double(top) * Double(glyphs.count))) - 1
            return glyphs[max(0, min(glyphs.count - 1, idx))]
        }.joined()
    }

    // Подписи дней под столбиками: «пн вт ср чт пт сб вс».
    static func dayLetters(_ dates: [Date], calendar: Calendar = .current) -> String {
        return dates.map { d -> String in
            let wd = calendar.component(.weekday, from: d)
            return String(weekdayShort(wd).prefix(1))
        }.joined()
    }

    static func bar(_ pct: Int, width: Int? = nil) -> String {
        let w = width ?? Prefs.barWidth
        let p = max(0, min(100, pct))
        // Округляем, а не отбрасываем: при 14 клетках 6% отбрасыванием дают
        // пустую шкалу, и «немного» выглядит как «ничего».
        let filled = Int((Double(p) / 100.0 * Double(w)).rounded())
        return String(repeating: Prefs.barFilled, count: max(0, min(w, filled)))
             + String(repeating: Prefs.barEmpty, count: max(0, w - filled))
    }

    // Заливка нарисованной полоски - в точках, а не в клетках шрифта.
    //
    // Живёт здесь, рядом со шкалой из знаков, и без AppKit: это единственная
    // арифметика капсулы, и единственное в ней место, где можно ошибиться
    // молча. Рисование проверить нечем, а это - проверяется тестом.
    //
    // Ноль - это ровно ноль, пустая капсула: «ничего» и «немного» должны
    // выглядеть по-разному, иначе полоска врёт в самую спокойную сторону.
    // А любой ненулевой процент занимает не меньше minVisible (толщины
    // полоски): 1% от 50 точек - это полточки, то есть невидимо, и
    // начавшееся окно выглядело бы как нетронутое.
    static func fillWidth(pct: Int, total: Double, minVisible: Double) -> Double {
        let p = max(0, min(100, pct))
        if p == 0 { return 0 }
        let want = total * Double(p) / 100.0
        return max(min(minVisible, total), min(total, want))
    }

    // Кружок отражает САМЫЙ нагруженный лимит, даже если в тексте показан
    // не он: так видно, что стоит заглянуть в меню, а строка остаётся короткой.
    static func icon(for pct: Int) -> String {
        let parts = Prefs.iconSet.split(separator: ",").map(String.init)
        let glyphs = parts.count >= 3 ? parts : ["\u{25D4}", "\u{25D1}", "\u{25D5}"]
        if pct >= Prefs.alertAt { return glyphs[2] }
        if pct >= Prefs.warnAt { return glyphs[1] }
        return glyphs[0]
    }

    // Ширина строки в ЗНАКАХ, с учётом того, что в меню стоит моноширинный
    // шрифт. Swift считает символы, а не байты, поэтому кириллица здесь
    // колонки не разъезжает - в отличие от printf в шелле.
    static func pad(_ s: String, _ width: Int) -> String {
        let n = s.count
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }

    static func padLeft(_ s: String, _ width: Int) -> String {
        let n = s.count
        return n >= width ? s : String(repeating: " ", count: width - n) + s
    }

    // Обрезка имени лимита до разумной длины.
    //
    // Зачем. Колонка имени в меню считается по САМОМУ ДЛИННОМУ из пришедших
    // имён, и верхней границы у неё не было. А имя приходит снаружи: либо
    // из ключа API (`seven_day_<модель>`), либо готовым заголовком. Как
    // назовут следующую модель, решаем не мы — и длинное имя молча растянуло
    // бы меню на пол-экрана. Считано 06.09.2026: имя в 12 знаков даёт 383 pt
    // вместо 340, в 24 знака — около 470 pt при разумных 250–320.
    //
    // Обрезаем по знакам, а не по байтам: в «Неделя» шесть знаков, а не
    // двенадцать. Многоточие одним символом, чтобы не съедать три клетки.
    static func clip(_ s: String, _ max: Int) -> String {
        guard max > 1, s.count > max else { return s }
        return String(s.prefix(max - 1)) + "\u{2026}"
    }
}

// Числа вёрстки кольца - здесь, а не в рисовалке.
//
// Приём взят у codenotch (`NSLayout` + `NotchLayoutTests`), и он стоит того
// по нашей же причине: Мака под рукой нет, собрать и посмотреть нельзя.
// Пока размеры сидят внутри AppKit-файла, они не проверяются здесь ничем -
// AppKit на Linux не типизируется вовсе. Вынесенные в чистый файл, они
// становятся утверждениями, которые ловит run-tests.sh.
//
// Рисовалка (RingBar) отсюда только читает и сама ничего не считает.
enum Layout {
    // Диаметр кольца - от высоты заглавной буквы, а не в точках: человек,
    // поднявший шрифт трея, ждёт, что кольцо вырастет вместе с цифрами.
    // Коэффициент больше единицы намеренно: круг той же высоты, что буква,
    // выглядит мельче её - у буквы есть вертикальные штрихи во всю высоту,
    // у круга во всю высоту только одна точка.
    // Замер по снимку из CI: при 1.22 и шрифте 13 кольцо выходило 11 точек -
    // мельче, чем весят цифры рядом, и дуга в нём не читалась вовсе.
    // Строка меню даёт 22 точки, и занимать их стоит.
    static let ringDiameterOfCapHeight: Double = 1.6

    // Толщина обода - доля диаметра. Тоньше 1.5 точки на не-Retina
    // экране кольцо пропадает, поэтому есть и нижняя граница в точках.
    // 0.22 давало обод в треть диаметра: не кольцо, а бублик с зазубриной.
    // Тонкий обод читается как шкала, толстый - как заливка.
    static let ringStrokeOfDiameter: Double = 0.16
    static let ringStrokeMin: Double = 1.5

    // Просвет между кольцом и первой цифрой.
    static let ringGap: Double = 3

    // Наименьшая заметная дуга, в градусах. Без неё 1% - это волосок в
    // пару пикселей: он читается как грязь на экране, а не как «уже начал».
    // Тот же приём, что у полоски (Fmt.fillWidth с minVisible).
    static let ringMinSweep: Double = 14

    // Сколько дуги занимает процент. 0 - пусто, 100 - полный круг.
    static func ringSweep(pct: Int) -> Double {
        return Fmt.fillWidth(pct: pct, total: 360, minVisible: ringMinSweep)
    }

    // Выше строки меню кольцо не растёт. Потолок константой, а не запросом
    // к NSStatusBar.system.thickness: этот вызов отсюда не проверить ничем,
    // а строка меню - 22 точки на всех макбуках, включая Retina. Ошибиться
    // тут можно только в одну сторону, и она безопасная - кольцо чуть
    // меньше строки вместо кольца, срезанного её краем. Без потолка шрифт
    // трея, поднятый до 28, давал диаметр 24 - больше строки.
    static let ringMaxDiameter: Double = 18

    static func ringDiameter(capHeight: Double) -> Double {
        let want = (capHeight * ringDiameterOfCapHeight).rounded()
        return max(8, min(ringMaxDiameter, want))
    }

    static func ringStroke(diameter: Double) -> Double {
        return max(ringStrokeMin, (diameter * ringStrokeOfDiameter * 2).rounded() / 2)
    }
}

// Сборка строки для трея из шаблона.
//
// Пустые макросы (модель, которой нет в тарифе; деньги при выключенном
// перерасходе) схлопываются вместе с соседним разделителем - иначе в строке
// оставались бы висящие « · » на пустом месте.
enum BarTitle {
    static let macros: [(String, String)] = [
        ("{icon}",       L("кружок загрузки", "load dot")),
        ("{5h}",         L("процент текущего окна", "current window percent")),
        ("{5h.left}",    L("сколько до сброса окна", "time left in window")),
        ("{5h.reset}",   L("когда сброс: пн 03:00", "reset clock: Mon 03:00")),
        ("{7d}",         L("недельный кап, процент", "weekly cap percent")),
        ("{7d.left}",    L("сколько до конца недели", "time left this week")),
        ("{opus}",       L("Opus за неделю", "Opus this week")),
        ("{sonnet}",     L("Sonnet за неделю", "Sonnet this week")),
        ("{fable}",      L("Fable за неделю", "Fable this week")),
        ("{haiku}",      L("Haiku за неделю", "Haiku this week")),
        ("{models}",     L("все модели подряд: O, S, F", "all models in a row: O, S, F")),
        ("{tokens}",     L("токены за окно", "tokens this window")),
        ("{worst}",      L("самый нагруженный лимит", "the busiest limit")),
        ("{worst.left}", L("до сброса у него", "time left on it")),
        ("{active}",     L("лимит, который упрётся первым", "the limit that hits first")),
        ("{active.left}",L("до сброса у него", "time left on it")),
        ("{active.reset}",L("когда он сбросится: пн 03:00", "when it resets: Mon 03:00")),
        ("{extra}",      L("потрачено сверх лимита", "extra usage spent")),
        ("{extra.pct}",  L("сверх лимита, процент", "extra usage percent")),
        ("{money}",      L("во сколько обошлось окно", "what this window cost")),
        ("{sessions}",   L("кто работает и кто ждёт меня", "who is working and who waits")),
    ]

    // iconGlyph - чем нарисовать {icon}. Пусто означает «не знаком»: в
    // режиме кольца кружок рисуется картинкой рядом со строкой, а из самой
    // строки макрос должен исчезнуть вместе со своим разделителем. Отдавать
    // сюда картинку нельзя - здесь строка, и её же показывает предпросмотр
    // настроек и `--doctor`.
    static func render(_ template: String, usage: Usage,
                       money: MoneyView? = nil, tokens: TokensView? = nil,
                       sessions: SessionSummary? = nil,
                       iconGlyph: String? = nil) -> String {
        var s = template

        func put(_ macro: String, _ value: String) {
            guard s.contains(macro) else { return }
            s = s.replacingOccurrences(of: macro, with: value)
        }
        func pctText(_ b: Bucket?) -> String {
            guard let b = b else { return "" }
            return "\(b.pct)%"
        }

        let session = usage.session
        let weekly = usage.bucket("seven_day")

        put("{icon}", iconGlyph ?? Fmt.icon(for: usage.worst?.pct ?? 0))
        // Сессии в строке трея выключены по умолчанию: место там занято
        // процентом и отсчётом, они отвечают на «работать или подождать».
        // Кому нужнее «не стоит ли агент» - галочка в настройках.
        put("{sessions}", sessions.map { $0.text } ?? "")
        put("{5h}", pctText(session))
        put("{5h.left}", session?.resetsAt != nil ? Fmt.left(session?.resetsAt) : "")
        put("{5h.reset}", Fmt.clock(session?.resetsAt))
        put("{7d}", pctText(weekly))
        put("{7d.left}", weekly?.resetsAt != nil ? Fmt.left(weekly?.resetsAt) : "")

        for name in ["opus", "sonnet", "haiku", "fable"] {
            let key = name == "fable" ? UsageParser.fableKey : "seven_day_" + name
            let b = usage.bucket(key) ?? usage.bucket("seven_day_" + name)
            put("{" + name + "}", pctText(b))
        }

        // В строке меню модель - одна буква: «O 81% · S 12%». Полное имя
        // съедает половину ширины трея, а различить их хватает буквы.
        let models = usage.modelBuckets
            .map { "\($0.tiny) \($0.pct)%" }
            .joined(separator: " \u{00B7} ")
        put("{models}", models)

        // Время до сброса у «того, который упрётся первым» - отдельным
        // макросом, а не частью {active}.
        //
        // Иначе строка «7д 62% 2д 23ч» получается только у того, кому
        // подошёл именно такой порядок и такой разделитель, а всем
        // остальным - никак. Разделять их - работа шаблона, наше дело
        // дать оба куска.
        //
        // Само по себе это заметно на недельном лимите: «7д 62%» не
        // отвечает, шесть часов до сброса или три дня, а решение
        // «работать дальше или подождать» держится ровно на этом.
        if let w = usage.worst {
            put("{worst}", "\(w.short) \(w.pct)%")
            put("{worst.left}", w.resetsAt != nil ? Fmt.left(w.resetsAt) : "")
        } else {
            put("{worst}", "")
            put("{worst.left}", "")
        }
        if let a = usage.active {
            put("{active}", "\(a.short) \(a.pct)%")
            put("{active.left}", a.resetsAt != nil ? Fmt.left(a.resetsAt) : "")
            put("{active.reset}", Fmt.clock(a.resetsAt))
        } else {
            put("{active}", "")
            put("{active.left}", "")
            put("{active.reset}", "")
        }

        // Знак «≈» ставится здесь, а не в MoneyView: в строке меню он несёт
        // смысл - счёт идёт по нашему прайсу и только по видимым машинам,
        // а в отчёте рядом уже есть подпись словами.
        put("{money}", money.map { $0.spent > 0 ? $0.spentMarked : "" } ?? "")
        put("{tokens}", tokens.map { $0.isEmpty ? "" : $0.text } ?? "")

        let e = usage.extra
        put("{extra}", (e.enabled && e.usedMinor != nil) ? e.usedText : "")
        put("{extra.pct}", e.percent != nil ? "\(e.percent!)%" : "")

        // Неизвестные макросы убираем, чтобы в трее не висело «{foo}».
        //
        // \w, а не [a-zA-Z0-9_]: в ICU это буквы любого алфавита. С латинским
        // диапазоном опечатка кириллицей - «{процент}» - оставалась в строке
        // меню как есть, и человек видел фигурные скобки вместо цифры.
        if let re = try? NSRegularExpression(pattern: "\\{[\\w.]+\\}") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: "")
        }

        s = tidy(s)
        if s.isEmpty { s = "\(usage.worst?.short ?? "") \(usage.worst?.pct ?? 0)%" }
        if usage.isStale { s = s.isEmpty ? "~" : s + "~" }  // честный признак несвежих цифр
        return s
    }

    // Схлопываем разделители, оставшиеся от пустых макросов: « ·  · », « · »
    // в начале и в конце, двойные пробелы.
    //
    // Не private: тем же самым чистится шаблон, из которого галочка убрала
    // свой макрос. Две разные чистки разошлись бы - в строке меню пусто
    // схлопывалось бы, а в поле настроек оставалось висеть « · ».
    static func tidy(_ input: String) -> String {
        var s = input
        let rules: [(String, String)] = [
            ("[ \t]+", " "),
            ("(\u{00B7}[ ]*){2,}", "\u{00B7} "),
            ("^[ \u{00B7}]+", ""),
            ("[ \u{00B7}]+$", ""),
            (" +\u{00B7} +", " \u{00B7} "),
        ]
        for (pattern, repl) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                            withTemplate: repl)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// Галочки как конструктор шаблона.
//
// Пока «свой формат» выключен, галочки собирают строку с нуля - это
// поведение осталось. Когда включён, они правят ТУ строку, которая уже
// написана: тик добавляет свой макрос, снятие убирает. До этого любая
// галочка выключала «свой формат» и затирала написанное целиком - то есть
// человек, собравший строку руками, терял её от одного случайного клика.
enum TemplateEdit {
    // Какие макросы стоят за галочкой. Пара «{5h} {5h.left}» - это
    // действительно пара: время без процента в строке меню читается как
    // отдельное число неизвестно про что.
    static func macros(for key: String, withLeft: Bool) -> [String] {
        switch key {
        case "showIcon":    return ["{icon}"]
        case "showSession": return withLeft ? ["{5h}", "{5h.left}"] : ["{5h}"]
        case "showWeekly":  return withLeft ? ["{7d}", "{7d.left}"] : ["{7d}"]
        case "showModels":  return ["{models}"]
        case "showExtra":   return ["{extra}"]
        case "showWorst":   return withLeft ? ["{worst}", "{worst.left}"] : ["{worst}"]
        case "showActive":  return withLeft ? ["{active}", "{active.left}"] : ["{active}"]
        // Часы сброса цепляются к тому окну, что уже есть в строке. Своего
        // места у них нет: «пн 03:00» в отрыве от процента не говорит, чей
        // это сброс.
        case "showResetClock": return ["{5h.reset}"]
        case "showExtraPct": return ["{extra.pct}"]
        // Деньги, токены и история в строку меню не идут по отдельному
        // правилу - см. Prefs.defaultTemplateFromCheckboxes.
        default:            return []
        }
    }

    static func contains(_ macro: String, in template: String) -> Bool {
        return template.contains(macro)
    }

    // Добавляем в конец, кроме кружка: он слева от всего по смыслу -
    // это индикатор, а не число.
    static func add(_ macros: [String], to template: String) -> String {
        var s = template
        for m in macros where !contains(m, in: s) {
            if m == "{icon}" {
                s = s.isEmpty ? m : m + " " + s
            } else if s.isEmpty {
                s = m
            } else if macros.count > 1, m.hasSuffix(".left}") {
                // Время идёт вплотную к своему проценту, без разделителя:
                // «57% 5м · 92% 1д3ч» читается как два окна, а
                // «57% · 5м · 92% · 1д3ч» - как четыре числа подряд.
                s += " " + m
            } else {
                s += " \u{00B7} " + m
            }
        }
        return BarTitle.tidy(s)
    }

    static func remove(_ macros: [String], from template: String) -> String {
        var s = template
        for m in macros { s = s.replacingOccurrences(of: m, with: "") }
        return BarTitle.tidy(s)
    }
}
