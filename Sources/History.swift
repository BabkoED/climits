import Foundation

// История процентов и темп.
//
// Зачем отдельный файл, если расход уже считается по расшифровкам. Затем,
// что расшифровки отвечают на «сколько токенов и денег», а на вопрос
// «упрусь ли я в лимит раньше, чем он сбросится» они не отвечают вовсе:
// размер лимита неизвестен, и делить одно на другое мы больше не пытаемся.
//
// Зато процент приходит от сервера каждые пять минут, и у него есть
// производная. Два замера - «было 40%, стало 52% за час» - дают темп
// 12% в час, а до сотни отсюда четыре часа. Ни одного предположения о
// размере лимита в этой арифметике нет: проценты делятся на проценты.
//
// Замеры хранятся в Application Support рядом с кэшем. Файл маленький -
// восемь суток по замеру раз в пять минут это около двух тысяч строк.
struct PctSample: Equatable {
    let at: Date
    let key: String     // какой лимит: five_hour, seven_day, ...
    let pct: Int
}

enum History {
    // Сколько держим. Больше недели бессмысленно: недельное окно к этому
    // моменту уже сбросилось, а пятичасовое - полтора десятка раз.
    static let keepFor: TimeInterval = 8 * 86400
    // Меньше четверти часа наблюдения - не темп, а шум: между двумя
    // соседними замерами процент часто не меняется вовсе, и наклон
    // получается либо нулевым, либо отвесным.
    static let minSpan: TimeInterval = 900
    // Падение процента - это сброс окна, а не отрицательный расход.
    // Два пункта допуска на округление сервером.
    static let resetDrop = 2

    static var fileURL: URL {
        return Pricing.supportDir.appendingPathComponent("history.json")
    }

    // --- чистая арифметика, её и проверяем ---------------------------------

    // Замеры одного лимита ПОСЛЕ последнего сброса окна.
    //
    // Без этого шага темп считался бы через границу окна: «было 90%, стало
    // 5%» дало бы отрицательный наклон и вывод «расход идёт назад».
    static func currentSegment(_ samples: [PctSample], key: String) -> [PctSample] {
        let mine = samples.filter { $0.key == key }.sorted { $0.at < $1.at }
        var start = 0
        for i in 1..<max(1, mine.count) where mine[i].pct + resetDrop < mine[i - 1].pct {
            start = i
        }
        return Array(mine[start...])
    }

    // Процентов в час. nil - «пока не знаю», и это честный ответ:
    // наблюдения слишком коротки или процент не растёт.
    static func rate(_ samples: [PctSample], key: String) -> Double? {
        let seg = currentSegment(samples, key: key)
        guard let first = seg.first, let last = seg.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minSpan else { return nil }
        let gain = Double(last.pct - first.pct)
        guard gain > 0 else { return nil }
        return gain / (span / 3600.0)
    }

    // Когда упрёмся в сотню при таком темпе.
    static func hitsFull(pct: Int, rate: Double?, now: Date = Date()) -> Date? {
        guard let rate = rate, rate > 0, pct < 100 else { return nil }
        let hours = Double(100 - pct) / rate
        // Больше двух недель вперёд - это не прогноз, а деление на почти
        // ноль. Показывать «упрёшься 12 сентября» по темпу 0.3% в час
        // значит выдавать шум за предсказание.
        guard hours < 24 * 14 else { return nil }
        return now.addingTimeInterval(hours * 3600)
    }

    // Что из этого следует человеку: успеет окно сброситься раньше, чем
    // упрёмся, или нет. Главный вопрос ровно этот, а не сама дата.
    static func beatsReset(hit: Date?, reset: Date?) -> Bool? {
        guard let hit = hit, let reset = reset else { return nil }
        return hit >= reset
    }

    static func prune(_ samples: [PctSample], now: Date = Date()) -> [PctSample] {
        return samples.filter { now.timeIntervalSince($0.at) <= keepFor }
    }

    // --- хранение ----------------------------------------------------------

    static func decode(_ data: Data) -> [PctSample] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let t = jsonNumber(row["t"]),
                  let key = row["k"] as? String,
                  let p = jsonNumber(row["p"]) else { return nil }
            return PctSample(at: Date(timeIntervalSince1970: t), key: key, pct: Int(p))
        }
    }

    static func encode(_ samples: [PctSample]) -> Data? {
        let rows = samples.map { ["t": $0.at.timeIntervalSince1970, "k": $0.key, "p": $0.pct] as [String: Any] }
        return try? JSONSerialization.data(withJSONObject: rows)
    }

    static func load() -> [PctSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return decode(data)
    }

    // Дописываем замер. Молча: история - вспомогательная вещь, и падение
    // записи не повод показывать человеку ошибку про лимиты.
    static func record(_ fresh: [PctSample], now: Date = Date()) {
        guard !fresh.isEmpty else { return }
        let old = load()
        // Один и тот же ответ приходит по нескольку раз: кэш отдаёт его
        // и таймеру, и открытию меню, и ⌘R. Отметка времени у них общая -
        // это время ОТВЕТА, а не запроса, - поэтому дубли ловятся по паре
        // «лимит + секунда». Без этого файл растёт втрое, а наклон считается
        // по десятку точек в одной и той же секунде.
        var seen = Set(old.map { "\($0.key)@\(Int($0.at.timeIntervalSince1970))" })
        var add: [PctSample] = []
        for s in fresh {
            let id = "\(s.key)@\(Int(s.at.timeIntervalSince1970))"
            if seen.contains(id) { continue }
            seen.insert(id)
            add.append(s)
        }
        guard !add.isEmpty else { return }
        let all = prune(old + add, now: now)
        guard let data = encode(all) else { return }
        try? FileManager.default.createDirectory(at: Pricing.supportDir,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
