import Foundation

// Чтение локальных расшифровок Claude Code: ~/.claude/projects/**/*.jsonl.
//
// Отсюда берутся две вещи:
//   1) оценка расхода, когда API недоступен и кэша нет;
//   2) деньги - сколько бы стоил тот же трафик по прайсу API.
//
// ГЛАВНОЕ ОГРАНИЧЕНИЕ, и его нельзя прятать: здесь лежит только то, что
// происходило НА ЭТОЙ МАШИНЕ. Проценты лимита сервер считает по всему
// аккаунту. Если человек работает с двух машин, локальные токены меньше
// настоящих, и всякий вывод «а сколько всего» будет занижен. Поэтому в
// интерфейсе это всегда помечено как оценка, а не как факт.

struct WindowUsage {
    // Токены по семействам моделей: opus, sonnet, fable, haiku.
    var byFamily: [String: TokenTally] = [:]
    var unknownModels: Set<String> = []

    var totals: TokenTally {
        return byFamily.values.reduce(TokenTally()) { $0 + $1 }
    }

    // Стоимость по прайсу API.
    var cost: Double {
        return byFamily.reduce(0.0) { sum, kv in
            sum + kv.value.cost(Pricing.price(for: kv.key))
        }
    }

    func cost(family: String) -> Double {
        guard let t = byFamily[family] else { return 0 }
        return t.cost(Pricing.price(for: family))
    }

    var isEmpty: Bool { return byFamily.isEmpty }
}

enum Transcripts {
    // Читаем только хвост файла: расшифровки длинных проектов вырастают до
    // сотен мегабайт, а в интересующее нас окно попадает только конец.
    private static let maxTailBytes = 8 * 1024 * 1024

    static var projectsDir: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // Расход за промежуток [since, now].
    static func usage(since: Date, dir: URL? = nil) -> WindowUsage {
        return usage(cutoffs: [since], dir: dir)[0]
    }

    // Несколько окон за один проход по файлам.
    //
    // Окна вложены друг в друга - пятичасовое внутри недельного, - и читать
    // одни и те же сотни мегабайт дважды незачем. Строка попадает во все
    // окна, чья граница её младше.
    static func usage(cutoffs: [Date], dir: URL? = nil) -> [WindowUsage] {
        guard let earliest = cutoffs.min() else { return [] }
        var out = [WindowUsage](repeating: WindowUsage(), count: cutoffs.count)
        let root = dir ?? projectsDir
        let since = earliest
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return out }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            // Файл, не тронутый с начала окна, точно не содержит нужных строк.
            if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let m = v.contentModificationDate, m < since { continue }
            scan(url: url, cutoffs: cutoffs, into: &out)
        }
        return out
    }

    private static func scan(url: URL, cutoffs: [Date], into out: inout [WindowUsage]) {
        let since = cutoffs.min() ?? Date.distantPast
        for line in tail(of: url).split(separator: "\n") {
            // Дешёвый отсев до разбора JSON: строк в файле десятки тысяч,
            // а с расходом - единицы процентов от них.
            guard line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let ts = row["timestamp"] as? String,
                  let when = UsageParser.parseDate(ts), when >= since else { continue }
            guard let message = row["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let model = (message["model"] as? String) ?? ""
            let family = Pricing.family(of: model)

            let add = TokenTally(input: intOf(usage["input_tokens"]),
                                 output: intOf(usage["output_tokens"]),
                                 cacheWrite: intOf(usage["cache_creation_input_tokens"]),
                                 cacheRead: intOf(usage["cache_read_input_tokens"]),
                                 requests: 1)
            for (i, cutoff) in cutoffs.enumerated() where when >= cutoff {
                out[i].byFamily[family] = (out[i].byFamily[family] ?? TokenTally()) + add
                if !model.isEmpty && !Pricing.isKnown(model) { out[i].unknownModels.insert(model) }
            }
        }
    }

    private static func intOf(_ any: Any?) -> Int {
        return Int(jsonNumber(any) ?? 0)
    }

    private static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// Пересчёт процентов в деньги.
//
// Логика такая. Прямо считается только одно - во что обошёлся трафик этой
// машины внутри окна. Дальше единственный шаг догадки: если этот трафик
// израсходовал N процентов лимита, то весь лимит стоит примерно
// «потрачено / (N/100)».
//
// Шаг честный ровно настолько, насколько локальные расшифровки покрывают
// весь расход аккаунта. Поэтому:
//   * при маленьком проценте деление разносит любую погрешность в разы -
//     ниже порога вообще не показываем;
//   * результат везде помечен «≈».
struct MoneyView {
    let spent: Double        // прямой счёт по прайсу
    let fullLimit: Double?   // оценка полного лимита в деньгах
    let partial: Bool        // расшифровки могут не покрывать весь аккаунт

    // Ниже этого процента экстраполяция бессмысленна: при 1% любая
    // неточность умножается на сто.
    static let minPercentForExtrapolation = 5

    static func make(spent: Double, percent: Int, partial: Bool) -> MoneyView {
        guard percent >= minPercentForExtrapolation, spent > 0 else {
            return MoneyView(spent: spent, fullLimit: nil, partial: partial)
        }
        return MoneyView(spent: spent,
                         fullLimit: spent / (Double(percent) / 100.0),
                         partial: partial)
    }

    // Значащие цифры важнее единообразия: это оценка, и «$30.0» читается
    // как ложная точность, а «$139.63» на оценке - как насмешка.
    static func money(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 10 {
            var s = String(format: "%.1f", v)
            if s.hasSuffix(".0") { s.removeLast(2) }
            return "$" + s
        }
        return String(format: "$%.2f", v)
    }

    var spentText: String { return MoneyView.money(spent) }
    var fullText: String? { return fullLimit.map { MoneyView.money($0) } }
}


// Деньги по одному лимиту.
//
// Окно берём от времени сброса назад: сервер сам говорит, когда лимит
// обнулится, и это точнее, чем «последние пять часов от сейчас» - к моменту,
// когда до сброса осталось десять минут, эти два промежутка расходятся почти
// полностью.
enum Money {
    static func duration(of key: String) -> TimeInterval {
        return key == "five_hour" ? 5 * 3600 : 7 * 86400
    }

    static func windowStart(for b: Bucket) -> Date {
        let d = duration(of: b.key)
        if let reset = b.resetsAt { return reset.addingTimeInterval(-d) }
        return Date().addingTimeInterval(-d)
    }

    // Какая часть расшифровок относится к этому лимиту: у модельных - только
    // трафик самой модели, у общих - весь.
    static func spent(for b: Bucket, in window: WindowUsage) -> Double {
        if b.key.hasPrefix("seven_day_") {
            let family = String(b.key.dropFirst("seven_day_".count))
            return window.cost(family: family)
        }
        if b.key == UsageParser.fableKey { return window.cost(family: "fable") }
        return window.cost
    }

    static func view(for b: Bucket, in window: WindowUsage) -> MoneyView {
        return MoneyView.make(spent: spent(for: b, in: window),
                              percent: b.pct,
                              partial: true)
    }
}
