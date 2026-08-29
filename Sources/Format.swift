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

    // «1,2м/2,2м» - потрачено и весь лимит одной парой. Косая черта вместо
    // «из»: в строке меню каждый знак на счету, а смысл тот же.
    static func pair(_ spent: String, _ full: String?) -> String {
        guard let full = full else { return spent }
        return spent + "/" + full
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
        ("{tokens}",     L("токены: потрачено/весь лимит", "tokens: spent/full limit")),
        ("{worst}",      L("самый нагруженный лимит", "the busiest limit")),
        ("{active}",     L("лимит, который упрётся первым", "the limit that hits first")),
        ("{extra}",      L("потрачено сверх лимита", "extra usage spent")),
        ("{extra.pct}",  L("сверх лимита, процент", "extra usage percent")),
        ("{money}",      L("во сколько обошлось окно", "what this window cost")),
        ("{money.limit}",L("во сколько обойдётся весь лимит", "what the full limit is worth")),
    ]

    static func render(_ template: String, usage: Usage,
                       money: MoneyView? = nil, tokens: TokensView? = nil) -> String {
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

        put("{icon}", Fmt.icon(for: usage.worst?.pct ?? 0))
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

        if let w = usage.worst { put("{worst}", "\(w.short) \(w.pct)%") } else { put("{worst}", "") }
        if let a = usage.active { put("{active}", "\(a.short) \(a.pct)%") } else { put("{active}", "") }

        // Знак «≈» ставится здесь, а не в MoneyView: в строке меню он несёт
        // смысл (это оценка), а в отчёте рядом уже есть подпись словами.
        put("{money}", money.map { $0.spent > 0 ? "\u{2248}" + $0.spentText : "" } ?? "")
        put("{money.limit}", money?.fullText.map { "\u{2248}" + $0 } ?? "")
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

        s = collapse(s)
        if s.isEmpty { s = "\(usage.worst?.short ?? "") \(usage.worst?.pct ?? 0)%" }
        if usage.isStale { s = s.isEmpty ? "~" : s + "~" }  // честный признак несвежих цифр
        return s
    }

    // Схлопываем разделители, оставшиеся от пустых макросов: « ·  · », « · »
    // в начале и в конце, двойные пробелы.
    private static func collapse(_ input: String) -> String {
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
