import Foundation

// Разбор ответа api.anthropic.com/api/oauth/usage.
//
// Эндпоинт НЕ документирован: это то, что Claude Code запрашивает для своей
// команды /usage. Форма ответа уже менялась и, скорее всего, изменится снова,
// поэтому здесь сознательно нет ни Codable, ни жёсткой схемы: Codable падает
// целиком от одного переименованного поля, а нам нужно, чтобы приложение
// продолжало показывать хоть что-то.
//
// Разбор идёт двумя путями:
//   1) массив "limits" - новая форма (kind/percent/resets_at/is_active);
//   2) объекты верхнего уровня (five_hour, seven_day, seven_day_opus, ...) -
//      прежняя форма.
// Что найдётся, то и берём. Пока живы оба - живы и мы.

struct Bucket {
    let key: String        // машинный ключ, для настроек и макросов
    let short: String      // «5ч», «Opus»
    let long: String       // «5-часовое окно», «Неделя, Opus»
    let percent: Double    // 0..100
    let resetsAt: Date?
    let isActive: Bool
    let rank: Int          // порядок в списке

    var pct: Int { return Int(percent) }   // как в /usage: отбрасываем дробь
}

struct Extra {
    let enabled: Bool
    let usedMinor: Double?
    let limitMinor: Double?
    let exponent: Int
    let currency: String
    let percentGiven: Double?

    // Процент расхода сверх лимита.
    //
    // Полагаться на присланное utilization нельзя: при заданном лимите оно
    // всё равно может прийти null, и тогда $168 из $200 - это 84% - выглядели
    // бы спокойным нулём и зелёным цветом. Поэтому если поля нет, считаем сами.
    // Единицы у used и limit одинаковые (минорные), они сокращаются.
    var percent: Int? {
        if let p = percentGiven { return Int(p) }
        guard let u = usedMinor, let l = limitMinor, l > 0 else { return nil }
        return Int(u / l * 100.0)
    }

    var symbol: String {
        switch currency.uppercased() {
        case "USD": return "$"
        case "EUR": return "\u{20AC}"
        case "RUB": return "\u{20BD}"
        default: return currency.uppercased() + " "
        }
    }

    // Минорные единицы в основную валюту.
    //
    // ВАЖНО: API отдаёт суммы в МИНОРНЫХ единицах, а множитель лежит рядом:
    //   "spend": {"used": {"amount_minor": 13963, "exponent": 2}}
    // 13963 при exponent=2 - это $139.63, а не $13963. На этом легко
    // завысить расход ровно в сто раз.
    func money(_ minor: Double?) -> String {
        guard let m = minor else { return "\u{2014}" }
        let divisor = pow(10.0, Double(exponent))
        // String(format:) без локали печатает точку в любой системе. Это
        // важно: локализованное форматирование дало бы «$139,63», и сумма
        // читалась бы как разряды тысяч.
        return symbol + String(format: "%.\(exponent)f", m / divisor)
    }

    var usedText: String { return money(usedMinor) }
    var limitText: String { return money(limitMinor) }
}

struct Usage {
    let buckets: [Bucket]
    let extra: Extra
    let fetchedAt: Date
    let isStale: Bool
    let rawBody: String

    var worst: Bucket? {
        return buckets.max(by: { $0.percent < $1.percent })
    }

    // «Текущее» окно. Обычно это five_hour, но полагаться на это имя нельзя:
    // длительность окна задаёт Anthropic и уже однажды меняла. Если знакомого
    // ключа нет - берём то окно, которое сбросится раньше всех: оно и есть
    // ближайшее к пользователю.
    var session: Bucket? {
        if let b = buckets.first(where: { $0.key == "five_hour" }) { return b }
        let dated = buckets.filter { $0.resetsAt != nil }
        return dated.min(by: { $0.resetsAt! < $1.resetsAt! }) ?? buckets.first
    }

    // Лимит, который упрётся первым: сначала то, что API само назвало
    // активным, иначе просто самый нагруженный.
    var active: Bucket? {
        return buckets.first(where: { $0.isActive }) ?? worst
    }

    func bucket(_ key: String) -> Bucket? {
        return buckets.first(where: { $0.key == key })
    }

    // Недельные лимиты по моделям, в порядке отображения.
    var modelBuckets: [Bucket] {
        return buckets.filter { $0.key.hasPrefix("seven_day_") || $0.key == UsageParser.fableKey }
    }
}

struct UsageParser {
    // Замеченное, но не подтверждённое официально имя поля для Fable.
    // В реальных ответах оно приходило с utilization=0 и resets_at=null ровно
    // тогда, когда Claude Code показывал «Fable · 0% used · You haven't used
    // Fable yet». Если Anthropic начнёт присылать нормальное имя - ветка
    // станет не нужна, но без неё Fable в трее не виден вообще.
    static let fableKey = "nimbus_quill"

    static func parse(body: String, fetchedAt: Date, isStale: Bool) -> Usage? {
        guard let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        var buckets = parseLimitsArray(root)
        if buckets.isEmpty { buckets = parseTopLevel(root) }
        if buckets.isEmpty { return nil }

        buckets.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.short < b.short
        }

        return Usage(buckets: buckets,
                     extra: parseExtra(root),
                     fetchedAt: fetchedAt,
                     isStale: isStale,
                     rawBody: body)
    }

    // ---- путь 1: массив "limits" -------------------------------------------
    private static func parseLimitsArray(_ root: [String: Any]) -> [Bucket] {
        guard let list = root["limits"] as? [[String: Any]], !list.isEmpty else { return [] }
        var out: [Bucket] = []
        for item in list {
            // Имя лимита может лежать под разными ключами - берём первое,
            // которое есть. Так же и с процентом.
            let key = firstString(item, ["kind", "type", "name", "id", "scope"])
                ?? firstString(item, ["title"]) ?? "limit\(out.count)"
            guard let pct = firstNumber(item, ["percent", "utilization", "used_percent", "pct"])
            else { continue }
            let reset = firstString(item, ["resets_at", "reset_at", "resets"]).flatMap(parseDate)
            let active = (item["is_active"] as? Bool) ?? false
            // Человеческое имя, если API его прислало, иначе выводим из ключа.
            let title = firstString(item, ["title", "display_name", "label"])
            let model = firstString(item, ["model", "model_name"])
            out.append(makeBucket(key: normalizeKey(key, model: model),
                                  percent: pct,
                                  resetsAt: reset,
                                  isActive: active,
                                  titleFromAPI: title))
        }
        return out
    }

    // ---- путь 2: объекты верхнего уровня -----------------------------------
    //
    // Фильтр здесь неочевидный, и каждое его условие оплачено ошибкой:
    //   * процент обязателен - иначе в список попадали служебные объекты того
    //     же ответа ("spend" - это деньги, а не проценты) и рисовались
    //     бессмысленными шкалами на нуле;
    //   * время сброса тоже обязательно - по той же причине;
    //   * НО кроме недельных лимитов по моделям: модель, которой ещё не
    //     пользовались, приходит с 0% и без окна сброса, а показать её надо,
    //     иначе непонятно, есть она в тарифе или нет.
    private static func parseTopLevel(_ root: [String: Any]) -> [Bucket] {
        var out: [Bucket] = []
        for (key, value) in root {
            if key == "extra_usage" || key == "spend" || key == "limits" { continue }
            guard let obj = value as? [String: Any] else { continue }
            guard let pct = firstNumber(obj, ["utilization", "percent", "used_percent"])
            else { continue }
            let reset = firstString(obj, ["resets_at", "reset_at"]).flatMap(parseDate)
            let exempt = key.hasPrefix("seven_day_") || key == fableKey
            if reset == nil && !exempt { continue }
            out.append(makeBucket(key: key,
                                  percent: pct,
                                  resetsAt: reset,
                                  isActive: (obj["is_active"] as? Bool) ?? false,
                                  titleFromAPI: nil))
        }
        return out
    }

    // Приводим имена из массива limits к тем же ключам, что на верхнем уровне,
    // чтобы настройки и макросы работали одинаково в обеих формах ответа.
    private static func normalizeKey(_ raw: String, model: String?) -> String {
        let k = raw.lowercased().replacingOccurrences(of: "-", with: "_")
        if let m = model?.lowercased(), !m.isEmpty {
            if k.contains("seven") || k.contains("week") {
                return "seven_day_" + modelFamily(m)
            }
        }
        if k == "five_hour" || k.contains("five_hour") || k.contains("5h") || k == "session" {
            return "five_hour"
        }
        if k == "seven_day" || k == "weekly" || k == "week" { return "seven_day" }
        return k
    }

    // «claude-opus-4-6-20260115» -> «opus». Версии и даты в названии нам не
    // нужны: в трее должно стоять короткое имя семейства.
    private static func modelFamily(_ m: String) -> String {
        for family in ["opus", "sonnet", "haiku", "fable"] {
            if m.contains(family) { return family }
        }
        return m
    }

    private static func makeBucket(key: String, percent: Double, resetsAt: Date?,
                                   isActive: Bool, titleFromAPI: String?) -> Bucket {
        var short = key
        var long = titleFromAPI ?? key
        var rank = 2

        switch key {
        case "five_hour":
            short = L("5ч", "5h")
            long = L("5-часовое окно", "5-hour window")
            rank = 0
        case "seven_day":
            short = L("7д", "7d")
            long = L("Неделя, всего", "Week, total")
            rank = 1
        case fableKey:
            short = "Fable"
            long = L("Неделя, Fable", "Week, Fable")
            rank = 2
        default:
            if key.hasPrefix("seven_day_") {
                let m = String(key.dropFirst("seven_day_".count))
                short = m.prefix(1).uppercased() + m.dropFirst()
                long = L("Неделя, ", "Week, ") + short
            } else if titleFromAPI == nil {
                short = key.replacingOccurrences(of: "_", with: " ")
                long = short
            } else {
                short = long
            }
        }
        return Bucket(key: key, short: short, long: long, percent: percent,
                      resetsAt: resetsAt, isActive: isActive, rank: rank)
    }

    // ---- деньги ------------------------------------------------------------
    private static func parseExtra(_ root: [String: Any]) -> Extra {
        let eu = root["extra_usage"] as? [String: Any] ?? [:]
        let spend = root["spend"] as? [String: Any] ?? [:]

        var used: Double? = nil
        var limit: Double? = nil
        var exponent: Int? = nil
        var currency: String? = nil

        // Сначала блок spend: там единицы названы явно.
        if let u = spend["used"] as? [String: Any] {
            used = firstNumber(u, ["amount_minor", "amount", "minor"])
            exponent = firstNumber(u, ["exponent", "decimal_places"]).map { Int($0) }
            currency = firstString(u, ["currency", "currency_code"])
        }
        if let l = spend["limit"] as? [String: Any] {
            limit = firstNumber(l, ["amount_minor", "amount", "minor"])
        }
        // Затем extra_usage - прежняя форма того же самого.
        if used == nil { used = firstNumber(eu, ["used_credits", "used", "amount_minor"]) }
        if limit == nil { limit = firstNumber(eu, ["monthly_limit", "limit", "limit_minor"]) }
        if exponent == nil { exponent = firstNumber(eu, ["decimal_places", "exponent"]).map { Int($0) } }
        if currency == nil { currency = firstString(eu, ["currency", "currency_code"]) }

        // Последняя попытка: поискать те же имена где угодно в документе.
        // Форма ответа меняется, а имена полей пока переживают переезды.
        if used == nil { used = deepNumber(root, ["amount_minor", "used_credits"]) }
        if exponent == nil { exponent = deepNumber(root, ["exponent", "decimal_places"]).map { Int($0) } }
        if currency == nil { currency = deepString(root, ["currency", "currency_code"]) }

        let enabled: Bool
        if let b = eu["is_enabled"] as? Bool { enabled = b }
        else if let b = spend["is_enabled"] as? Bool { enabled = b }
        else { enabled = used != nil }

        return Extra(enabled: enabled,
                     usedMinor: used,
                     limitMinor: limit,
                     exponent: exponent ?? 2,
                     currency: currency ?? "USD",
                     percentGiven: firstNumber(eu, ["utilization", "percent"]))
    }

    // ---- мелкие помощники --------------------------------------------------
    static func firstString(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    static func firstNumber(_ d: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            if let v = Keychain.numeric(d[k]) { return v }
        }
        return nil
    }

    // Поиск в глубину: обходим весь документ и берём первое совпадение по
    // имени ключа. Нужно ровно для одного случая - когда поле переехало
    // в новый контейнер, а называется по-прежнему.
    static func deepNumber(_ any: Any, _ keys: [String]) -> Double? {
        if let d = any as? [String: Any] {
            for k in keys { if let v = Keychain.numeric(d[k]) { return v } }
            for (_, v) in d { if let r = deepNumber(v, keys) { return r } }
        }
        if let a = any as? [Any] {
            for v in a { if let r = deepNumber(v, keys) { return r } }
        }
        return nil
    }

    static func deepString(_ any: Any, _ keys: [String]) -> String? {
        if let d = any as? [String: Any] {
            for k in keys { if let s = d[k] as? String, !s.isEmpty { return s } }
            for (_, v) in d { if let r = deepString(v, keys) { return r } }
        }
        if let a = any as? [Any] {
            for v in a { if let r = deepString(v, keys) { return r } }
        }
        return nil
    }

    // ISO8601 с дробными долями секунды и без них, плюс форма со смещением.
    // ISO8601DateFormatter без .withFractionalSeconds молча возвращает nil на
    // «2026-08-28T09:00:00.123Z», поэтому пробуем оба набора настроек.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Совсем запасной путь: секунды эпохи числом в строке.
        if let secs = Double(s), secs > 1_000_000_000 {
            return Date(timeIntervalSince1970: secs > 1_000_000_000_000 ? secs / 1000 : secs)
        }
        return nil
    }
}
