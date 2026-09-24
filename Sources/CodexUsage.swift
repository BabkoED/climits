import Foundation

// Лимиты Codex (OpenAI) - второй провайдер.
//
// ЗАЧЕМ. Антон 24.09.2026: «у climits может быть много провайдеров. Это
// мы пока только клод используем. Вдруг когда-то и кодекс проверим». Раз
// так, место под второго провайдера закладывается сейчас, пока в коде
// один, - а не когда придётся растаскивать Claude из каждой функции.
//
// ОТКУДА. Так же, как делает CodexBar (MIT) и сама программа Codex:
//   токен  - ~/.codex/auth.json (или $CODEX_HOME/auth.json), поле
//            tokens.access_token, рядом tokens.account_id;
//   запрос - GET https://chatgpt.com/backend-api/wham/usage,
//            Authorization: Bearer, ChatGPT-Account-Id;
//   ответ  - rate_limit.primary_window / secondary_window:
//            used_percent, reset_at (секунды эпохи), limit_window_seconds.
// Эндпоинт не документирован - ровно как у Claude. Поэтому разбор
// терпимый: одно переименованное поле гасит один лимит, а не весь показ.
//
// ЧЕГО НЕТ. Живой проверки: Codex у Антона не стоит, и разбор сверен
// только с формой ответа из тестов CodexBar. Новые версии Codex умеют
// держать вход в связке ключей вместо файла - такой вход здесь не виден,
// раздел просто не появится.
enum CodexAuth {
    static func path(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    // «Стоит» - это есть ВХОД ПО ПОДПИСКЕ, а не просто файл. У того, кто
    // работает в Codex по ключу API, в auth.json лежит OPENAI_API_KEY, а
    // tokens пуст: лимитов подписки у него нет, и раздел с вечным «нет
    // входа» менял бы ему меню ни за что (ревью 1.20.0).
    static var installed: Bool {
        guard let d = try? Data(contentsOf: path()) else { return false }
        return parse(d) != nil
    }

    struct Token {
        let value: String
        let account: String?
    }

    // Токен НЕ пишется ни в лог, ни на экран. Отсюда он уходит только
    // в заголовок запроса к тому же OpenAI, которому и принадлежит.
    static func parse(_ data: Data) -> Token? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = root["tokens"] as? [String: Any] else { return nil }
        let tok = (t["access_token"] as? String) ?? (t["accessToken"] as? String) ?? ""
        guard !tok.isEmpty else { return nil }
        let acc = (t["account_id"] as? String) ?? (t["accountId"] as? String)
        return Token(value: tok, account: (acc?.isEmpty ?? true) ? nil : acc)
    }
}

enum CodexUsageParser {
    // Имя окна по его длине: «5 часов», «неделя». Длину говорит ответ, и
    // сочинять имя по ключу («primary») значило бы показать слово API.
    static func names(seconds: Double) -> (short: String, long: String) {
        let h = Int((seconds / 3600).rounded())
        if h == 168 { return (L("7д", "7d"), L("неделя", "week")) }
        if h >= 24 && h % 24 == 0 { return (L("\(h / 24)д", "\(h / 24)d"), L("\(h / 24) дн.", "\(h / 24) days")) }
        if h >= 1 { return (L("\(h)ч", "\(h)h"), L("\(h) ч", "\(h) h")) }
        return (L("окно", "window"), L("окно", "window"))
    }

    private static func date(_ w: [String: Any], now: Date) -> Date? {
        if let t = jsonNumber(w["reset_at"]) ?? jsonNumber(w["resets_at"]) {
            // Секунды, но на всякий случай и миллисекунды: число больше
            // 10^11 секундами - это 5000-й год.
            return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
        }
        if let s = jsonNumber(w["reset_after_seconds"]) { return now.addingTimeInterval(s) }
        return nil
    }

    private static func bucket(_ w: [String: Any]?, key: String, prefix: String,
                               rank: Int, scoped: Bool, now: Date) -> Bucket? {
        guard let w = w, let pct = jsonNumber(w["used_percent"]) else { return nil }
        let len = jsonNumber(w["limit_window_seconds"])
        let n: (short: String, long: String) = len.map { names(seconds: $0) }
            ?? (short: L("окно", "window"), long: L("окно", "window"))
        var b = Bucket(key: key, short: n.short, long: prefix + n.long,
                       percent: max(0, min(1000, pct)), resetsAt: date(w, now: now),
                       isActive: false, rank: rank, severity: "normal")
        b.window = len
        b.scoped = scoped
        if scoped {
            // В виде строками короткое имя - единственное, что различает
            // лимиты, и «5ч» у модельного совпадало с общим (снимок
            // 1.20.0-c). Берём хвост названия модели: «...-Codex-Spark» -
            // «Spark», и приписываем окно, если оно не пятичасовое.
            let full = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            // Хвост после последнего дефиса - только если это слово: у
            // «GPT-5» хвост «5» читался бы как «5 часов».
            let last = full.split(separator: "-").last.map(String.init) ?? full
            let tail = last.contains(where: { $0.isLetter }) ? last : full
            let short = String(tail.prefix(8))
            b = Bucket(key: b.key, short: n.short == L("5ч", "5h") ? short : short + " " + n.short,
                       long: b.long, percent: b.percent, resetsAt: b.resetsAt,
                       isActive: false, rank: rank, severity: "normal",
                       window: len, scoped: true)
        }
        return b
    }

    struct Answer {
        let usage: Usage
        let plan: String?
    }

    static func parse(_ data: Data, at now: Date = Date()) -> Answer? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var buckets: [Bucket] = []
        let rl = root["rate_limit"] as? [String: Any]
        if let b = bucket(rl?["primary_window"] as? [String: Any], key: "codex_primary",
                          prefix: "Codex, ", rank: 0, scoped: false, now: now) { buckets.append(b) }
        if let b = bucket(rl?["secondary_window"] as? [String: Any], key: "codex_secondary",
                          prefix: "Codex, ", rank: 1, scoped: false, now: now) { buckets.append(b) }
        // Лимиты по моделям (GPT-5.3-Codex-Spark и подобные). Битый элемент
        // выпадает сам, соседей не трогает.
        for (i, x) in ((root["additional_rate_limits"] as? [[String: Any]]) ?? []).enumerated() {
            let name = (x["limit_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "model \(i + 1)"
            let r = x["rate_limit"] as? [String: Any]
            if let b = bucket(r?["primary_window"] as? [String: Any], key: "codex_m\(i)_p",
                              prefix: name + ", ", rank: 2, scoped: true, now: now) { buckets.append(b) }
            if let b = bucket(r?["secondary_window"] as? [String: Any], key: "codex_m\(i)_s",
                              prefix: name + ", ", rank: 2, scoped: true, now: now) { buckets.append(b) }
        }
        guard !buckets.isEmpty else { return nil }
        let plan = (root["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let extra = Extra(enabled: false, usedMinor: nil, limitMinor: nil, exponent: 2,
                          currency: "USD", percentGiven: nil)
        let body = String(data: data, encoding: .utf8) ?? ""
        return Answer(usage: Usage(buckets: buckets, extra: extra, fetchedAt: now,
                                   isStale: false, rawBody: body),
                      plan: plan)
    }
}
