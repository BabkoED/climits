import Foundation

// Прайс API в долларах за миллион токенов.
//
// Зачем это здесь: подписка Claude Code лимитами меряется в процентах, а не
// в деньгах, и вопрос «сколько это стоило бы по счётчику» на них не отвечается.
// Считаем сами - по токенам из локальных расшифровок и по этому прайсу.
//
// ВАЖНО: цены меняются, и захардкоженная таблица однажды начнёт врать молча.
// Поэтому с 1.3 она перекрывается двумя слоями, снизу вверх:
//   1) скачанный прайс LiteLLM - раз в сутки, см. PricingFeed и PricingFetch;
//   2) файл, который правят руками:
//      ~/Library/Application Support/climits/pricing.json
// Формат у обоих слоёв один и тот же. Ручной сильнее скачанного: человек,
// открывший этот файл, знает что-то, чего не знаем ни мы, ни LiteLLM, -
// например, свою корпоративную цену.
//
// Встроенная таблица теперь не основной источник, а последнее дно: то, по
// чему считаем, когда сети не было ни разу. Дата её видна в меню.
struct ModelPrice: Equatable {
    let input: Double          // $ за 1M входных
    let output: Double         // $ за 1M выходных
    var cacheWrite: Double     // запись в кэш на пять минут
    var cacheWrite1h: Double   // запись в кэш на час
    var cacheRead: Double      // чтение из кэша

    // Кэш стоит производные от входа, но записи ДВЕ РАЗНЫХ ЦЕНЫ, и это
    // не мелочь: пятиминутная запись дороже входа в 1.25 раза, часовая -
    // в 2 раза. Чтение дешевле входа в десять раз, срок жизни на него
    // не влияет.
    //
    // Почему это выяснилось только 29.08.2026. Раньше считалось, что запись
    // одна и всегда по 1.25. Проверка на восьми парных прогонах эвалов:
    // реконструкция из токенов давала $4.71 против $5.75, названных самим
    // Claude Code. Подбор множителя дал ровно 2.00, и с ним сумма сошлась
    // до цента. Дальше нашлась и причина - в стенограммах лежит разбивка
    // `usage.cache_creation` на `ephemeral_5m_input_tokens` и
    // `ephemeral_1h_input_tokens`, и весь трафик недели оказался часовым.
    // Ошибка была не в мелочи, а в 10% недельной суммы.
    static func standard(input: Double, output: Double) -> ModelPrice {
        return ModelPrice(input: input, output: output,
                          cacheWrite: input * 1.25, cacheWrite1h: input * 2,
                          cacheRead: input * 0.1)
    }
}

enum Pricing {
    // Прайс Anthropic на 09.10.2026, $ за миллион токенов: страница цен и
    // анонсы Opus 5.5 и Sonnet 5.5 на anthropic.com. По Opus 5.5 с ними
    // совпал и LiteLLM. Семейство считается по самой свежей модели - той,
    // в которой идёт работа.
    //
    // До 1.21.0 здесь стоял прайс 28.08.2026 (Opus 5 $5/$25, чтение кэша
    // 0.1 от входа), и без скачанного прайса неделя выходила на 75% дороже
    // настоящей: $1069 против $611 на расшифровках vps7 (ревью 09.10.2026).
    // Чтение кэша у новых моделей дешевле правила 0.1: у Opus 5.5 и
    // Sonnet 5.5 это $0.20, у Fable 5.1 - $0.25. Поэтому цены ниже заданы
    // целиком, а не множителями.
    static let builtin: [String: ModelPrice] = [
        "opus":   ModelPrice(input: 4,  output: 20, cacheWrite: 5,    cacheWrite1h: 8,  cacheRead: 0.2),
        "fable":  ModelPrice(input: 10, output: 50, cacheWrite: 12.5, cacheWrite1h: 20, cacheRead: 0.25),
        "sonnet": ModelPrice(input: 2,  output: 10, cacheWrite: 2.5,  cacheWrite1h: 4,  cacheRead: 0.2),
        // Claude Code зовёт Haiku 4.5 для служебного - его цена и стоит.
        "haiku":  .standard(input: 1,  output: 5),
        // Быстрый режим - та же модель, но вдвое дороже, и в стенограмме
        // он виден полем `usage.speed`. Доступен только на Opus, поэтому
        // вариант с суффиксом здесь один. У Opus 5.5 это $8/$40, множители
        // кэша те же, что у обычного. Если человек включит /fast, а мы
        // продолжим считать по обычной цене, приложение занизит расход вдвое
        // и не скажет об этом.
        "opus-fast": ModelPrice(input: 8, output: 40, cacheWrite: 10, cacheWrite1h: 16, cacheRead: 0.4),
    ]

    // Суффикс семейства для быстрого режима.
    static let fastSuffix = "-fast"

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
        return supportDir.appendingPathComponent("pricing.json")
    }

    // Кэш скачанного прайса LiteLLM, уже разобранного в нашу форму.
    static var remoteURL: URL {
        return supportDir.appendingPathComponent("pricing-remote.json")
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("climits", isDirectory: true)
    }

    private static var cached: [String: ModelPrice]? = nil
    // Откуда взята цена - для подписи в меню. Без неё «$12» одинаково
    // выглядит и когда прайс свежий, и когда сеть не отвечала месяц.
    private(set) static var remoteStamp: Date? = nil

    // Кладём поверх таблицы то, что нашлось в файле нашего формата.
    // Один разбор на два источника: ручной pricing.json и кэш LiteLLM.
    // Проверки одни и те же намеренно - скачанный файл доверия заслуживает
    // не больше написанного руками, а формат у него в любой момент может
    // поменяться на той стороне.
    private static func apply(_ data: Data, into t: inout [String: ModelPrice]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
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

    // Три слоя, снизу вверх: встроенная таблица, скачанный прайс, ручная
    // правка. Порядок именно такой. Скачанное бьёт встроенное, потому что
    // оно свежее по определению. Ручное бьёт всё, потому что человек, который
    // открыл pricing.json и вписал туда число, знает что-то, чего не знаем
    // ни мы, ни LiteLLM, - например, свою корпоративную цену.
    static func table() -> [String: ModelPrice] {
        if let c = cached { return c }
        var t = builtin
        if let data = try? Data(contentsOf: remoteURL) {
            apply(data, into: &t)
            remoteStamp = PricingFeed.decodeStamp(data).map { Date(timeIntervalSince1970: $0) }
        } else {
            remoteStamp = nil
        }
        if let data = try? Data(contentsOf: overrideURL) { apply(data, into: &t) }
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
        // Точное совпадение проверяем ПЕРВЫМ. Сюда приходят не только имена
        // моделей, но и ключи семейств, в том числе «opus-fast»: деньги
        // считаются по ключам таблицы окна. Без этой строки «opus-fast»
        // свернулось бы в «opus» и надбавка за быстрый режим потерялась бы.
        if let exact = t[model] { return exact }
        let fam = family(of: model)
        if model.hasSuffix(fastSuffix), let base = t[fam] {
            // Скачанный прайс про быстрый режим может не знать. Тогда берём
            // обычную цену этого же семейства, а не запасную: недоучесть
            // надбавку - минус проценты, свалиться на sonnet - минус втрое.
            return base
        }
        return t[fam] ?? t[fallbackFamily] ?? .standard(input: 3, output: 15)
    }

    // Знает ли таблица эту модель на самом деле, или мы подставили запасную.
    // Чем считали - словами, для подписи в меню. Дата важнее слова
    // «LiteLLM»: она отвечает на вопрос «а не устарело ли», а название
    // источника не отвечает ни на что.
    static func originText() -> String {
        _ = table()
        guard let stamp = remoteStamp else {
            return L("прайс встроенный, обновиться не удалось",
                     "built-in prices, no update fetched")
        }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return L("прайс от \(f.string(from: stamp))", "prices as of \(f.string(from: stamp))")
    }

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
    // Часовая запись - ЧАСТЬ cacheWrite, а не добавка к нему. Так сделано
    // намеренно: total и все существующие сложения остаются верными сами
    // по себе, а старые данные без разбивки просто считаются по цене
    // пятиминутной, как и раньше.
    var cacheWrite1h = 0

    var total: Int { return input + output + cacheWrite + cacheRead }

    static func + (a: TokenTally, b: TokenTally) -> TokenTally {
        return TokenTally(input: a.input + b.input,
                          output: a.output + b.output,
                          cacheWrite: a.cacheWrite + b.cacheWrite,
                          cacheRead: a.cacheRead + b.cacheRead,
                          requests: a.requests + b.requests,
                          cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }

    func cost(_ p: ModelPrice) -> Double {
        // Зажимаем: часовая часть не может быть больше всей записи. Если
        // данные разъехались, лучше посчитать по пятиминутной цене, чем
        // получить отрицательное слагаемое и занизить итог.
        let h = min(max(0, cacheWrite1h), max(0, cacheWrite))
        let m5 = cacheWrite - h
        return (Double(input) * p.input
              + Double(output) * p.output
              + Double(m5) * p.cacheWrite
              + Double(h) * p.cacheWrite1h
              + Double(cacheRead) * p.cacheRead) / 1_000_000.0
    }
}
