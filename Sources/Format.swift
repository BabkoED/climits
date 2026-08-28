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
    // «2ч 14м», «1д 4ч», «вот-вот». Секунды не показываем никогда: на экране,
    // который обновляется раз в пять минут, они всё равно врут.
    static func left(_ date: Date?) -> String {
        guard let d = date else { return "\u{2014}" }
        let diff = Int(d.timeIntervalSinceNow)
        if diff <= 60 { return L("вот-вот", "any moment") }
        let days = diff / 86400
        let hours = (diff % 86400) / 3600
        let mins = (diff % 3600) / 60
        if days > 0 { return "\(days)\(L("д", "d")) \(hours)\(L("ч", "h"))" }
        if hours > 0 { return String(format: "%d%@ %02d%@", hours, L("ч", "h"), mins, L("м", "m")) }
        return "\(mins)\(L("м", "m"))"
    }

    // «через 2ч 14м» / «сброс вот-вот» - чтобы не получилось «через вот-вот».
    static func resetPhrase(_ date: Date?) -> String {
        guard let d = date else { return L("сброс \u{2014}", "reset \u{2014}") }
        let s = left(d)
        if s == L("вот-вот", "any moment") { return L("сброс вот-вот", "resets any moment") }
        return L("через ", "in ") + s
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
        ("{models}",     L("все модели подряд", "all models in a row")),
        ("{worst}",      L("самый нагруженный лимит", "the busiest limit")),
        ("{active}",     L("лимит, который упрётся первым", "the limit that hits first")),
        ("{extra}",      L("потрачено сверх лимита", "extra usage spent")),
        ("{extra.pct}",  L("сверх лимита, процент", "extra usage percent")),
    ]

    static func render(_ template: String, usage: Usage) -> String {
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

        let models = usage.modelBuckets
            .map { "\($0.short) \($0.pct)%" }
            .joined(separator: " \u{00B7} ")
        put("{models}", models)

        if let w = usage.worst { put("{worst}", "\(w.short) \(w.pct)%") } else { put("{worst}", "") }
        if let a = usage.active { put("{active}", "\(a.short) \(a.pct)%") } else { put("{active}", "") }

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
