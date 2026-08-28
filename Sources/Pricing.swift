import Foundation

// Прайс API в долларах за миллион токенов.
//
// Зачем это здесь: подписка Claude Code лимитами меряется в процентах, а не
// в деньгах, и вопрос «сколько это стоило бы по счётчику» на них не отвечается.
// Считаем сами - по токенам из локальных расшифровок и по этому прайсу.
//
// ВАЖНО: цены меняются, и захардкоженная таблица однажды начнёт врать молча.
// Поэтому она перекрывается файлом, который можно править руками:
//     ~/Library/Application Support/climits/pricing.json
// Формат тот же, что у значений по умолчанию ниже. Что не указано в файле -
// берётся из встроенной таблицы.
struct ModelPrice: Equatable {
    let input: Double        // $ за 1M входных
    let output: Double       // $ за 1M выходных
    var cacheWrite: Double   // запись в кэш
    var cacheRead: Double    // чтение из кэша

    // Кэш обычно стоит производные от входа: запись дороже в 1.25 раза
    // (пятиминутный срок жизни), чтение дешевле в десять раз.
    static func standard(input: Double, output: Double) -> ModelPrice {
        return ModelPrice(input: input, output: output,
                          cacheWrite: input * 1.25, cacheRead: input * 0.1)
    }
}

enum Pricing {
    // Прайс Anthropic на 28.08.2026, $ за миллион токенов.
    // У Sonnet 5 до 31.08.2026 действует вводная цена $2/$10 - здесь стоит
    // обычная, чтобы таблица не начала занижать со следующей недели.
    static let builtin: [String: ModelPrice] = [
        "opus":   .standard(input: 5,  output: 25),
        "fable":  .standard(input: 10, output: 50),
        "sonnet": .standard(input: 3,  output: 15),
        "haiku":  .standard(input: 1,  output: 5),
    ]

    // Неизвестная модель: считаем по Sonnet и честно помечаем это в отчёте.
    // Ноль был бы хуже - он молча занижает итог.
    static let fallbackFamily = "sonnet"

    // Цена за миллион токенов: неотрицательная, конечная, не абсурдная.
    // Верхняя граница с большим запасом - она отсекает опечатку в разрядах,
    // а не осмысленное подорожание.
    private static func sane(_ v: Double?) -> Double? {
        guard let v = v, v.isFinite, v >= 0, v <= 100_000 else { return nil }
        return v
    }

    static var overrideURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("climits/pricing.json")
    }

    private static var cached: [String: ModelPrice]? = nil

    static func table() -> [String: ModelPrice] {
        if let c = cached { return c }
        var t = builtin
        if let data = try? Data(contentsOf: overrideURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (family, value) in obj {
                guard let d = value as? [String: Any],
                      let i = jsonNumber(d["input"]),
                      let o = jsonNumber(d["output"]) else { continue }
                // Файл правит человек, и в нём может оказаться что угодно:
                // отрицательное число, ноль, «nan», значение на порядки
                // больше правдоподобного. Молча принять такое - значит
                // показать бессмыслицу как расчёт. Ограничиваем разумным
                // диапазоном и отбрасываем непригодное.
                guard let vi = sane(i), let vo = sane(o) else { continue }
                var p = ModelPrice.standard(input: vi, output: vo)
                if let cw = sane(jsonNumber(d["cache_write"])) { p.cacheWrite = cw }
                if let cr = sane(jsonNumber(d["cache_read"])) { p.cacheRead = cr }
                t[family.lowercased()] = p
            }
        }
        cached = t
        return t
    }

    static func reload() { cached = nil }

    // «claude-opus-5», «Claude Opus 4.6» -> «opus»
    static func family(of model: String) -> String {
        let m = model.lowercased()
        for f in ["fable", "opus", "sonnet", "haiku"] where m.contains(f) { return f }
        return fallbackFamily
    }

    static func price(for model: String) -> ModelPrice {
        let t = table()
        return t[family(of: model)] ?? t[fallbackFamily] ?? .standard(input: 3, output: 15)
    }

    // Знает ли таблица эту модель на самом деле, или мы подставили запасную.
    static func isKnown(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["fable", "opus", "sonnet", "haiku"].contains { m.contains($0) }
    }
}

// Счётчик токенов одного разговора или окна.
struct TokenTally: Equatable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0
    var requests = 0

    var total: Int { return input + output + cacheWrite + cacheRead }

    static func + (a: TokenTally, b: TokenTally) -> TokenTally {
        return TokenTally(input: a.input + b.input,
                          output: a.output + b.output,
                          cacheWrite: a.cacheWrite + b.cacheWrite,
                          cacheRead: a.cacheRead + b.cacheRead,
                          requests: a.requests + b.requests)
    }

    func cost(_ p: ModelPrice) -> Double {
        return (Double(input) * p.input
              + Double(output) * p.output
              + Double(cacheWrite) * p.cacheWrite
              + Double(cacheRead) * p.cacheRead) / 1_000_000.0
    }
}
