import Foundation

// Разбор прайса LiteLLM.
//
// Зачем это вообще есть. В Pricing.swift лежит таблица цен, вбитая руками,
// и рядом с ней честное предупреждение: «цены меняются, и захардкоженная
// таблица однажды начнёт врать молча». Молча - здесь ключевое слово.
// Приложение не упадёт и не покажет ошибку, оно просто станет считать деньги
// по позапрошлому прайсу, и узнать об этом будет неоткуда.
//
// LiteLLM держит машиночитаемый прайс на все модели всех провайдеров и
// правит его в день объявления цен. Берём оттуда, а встроенную таблицу
// оставляем запасным дном: сети нет, формат поменялся, ответ невнятный -
// считаем как раньше. Класс ошибки при этом уходит целиком: устареть молча
// теперь может только то, что мы не смогли скачать, и об этом видно по дате.
//
// Файл БЕЗ сети намеренно - в нём только разбор. Сеть живёт в PricingFetch,
// который в проверках не участвует: URLSession на Linux тянет отдельный
// модуль, а разбор JSON, где и прячутся настоящие ошибки, гоняется здесь
// на любой машине.
enum PricingFeed {
    static let sourceURL =
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

    // Из ключа модели вынимаем версию: «claude-opus-4-1-20250805» -> 4.1,
    // «claude-3-5-sonnet-20241022» -> 3.5, «claude-opus-5» -> 5.0.
    //
    // Нужно, чтобы выбрать одну цену на семейство. Взять максимум по цене
    // нельзя - у Opus 4 было $15/$75, у Opus 5 стало $5/$25, и максимум
    // выбрал бы прошлогоднюю модель, завысив счёт втрое. Минимум так же
    // ошибётся в другую сторону. Верен только порядок версий.
    //
    // Дату из хвоста отбрасываем по длине: восемь цифр - это 20250805,
    // а не версия. Номера версий длиннее двух цифр не бывают.
    static func version(of key: String) -> Double? {
        var nums: [Int] = []
        var digits = ""
        func flush() {
            defer { digits = "" }
            guard !digits.isEmpty, digits.count <= 2, let n = Int(digits) else { return }
            nums.append(n)
        }
        for ch in key {
            if ch.isNumber { digits.append(ch) } else { flush() }
        }
        flush()
        guard let major = nums.first else { return nil }
        // Вторая группа - минорная версия, если она есть. «4-1» -> 4.1,
        // «4-5» -> 4.5. Больше двух групп не бывает, лишнее игнорируем.
        if nums.count >= 2, nums[1] < 10 { return Double(major) + Double(nums[1]) / 10.0 }
        return Double(major)
    }

    // Какое семейство описывает ключ. Возвращаем nil, а не «sonnet по
    // умолчанию»: здесь запасной вариант был бы вреден - неизвестная модель
    // молча переписала бы цену сонета.
    static func family(ofKey key: String) -> String? {
        let k = key.lowercased()
        for f in ["fable", "opus", "sonnet", "haiku"] where k.contains(f) { return f }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // Цена за миллион токенов из цены за токен. Проверка та же, что у
    // ручного файла: неотрицательная, конечная, не абсурдная.
    private static func perMillion(_ any: Any?) -> Double? {
        guard let v = number(any), v.isFinite, v >= 0 else { return nil }
        let m = v * 1_000_000
        return m <= 100_000 ? m : nil
    }

    // Разбор всего файла в нашу таблицу: семейство -> цена.
    //
    // Берём только записи самого Anthropic. У Bedrock и Vertex те же модели
    // лежат отдельными ключами и по своим ценам - считать по ним расход
    // подписки Claude Code значит показать чужой счёт.
    static func parse(_ data: Data) -> [String: ModelPrice] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var best: [String: (version: Double, price: ModelPrice)] = [:]
        for (key, value) in obj {
            guard let d = value as? [String: Any] else { continue }
            guard (d["litellm_provider"] as? String)?.lowercased() == "anthropic" else { continue }
            guard !key.contains("/") else { continue }
            guard let fam = family(ofKey: key) else { continue }
            guard let input = perMillion(d["input_cost_per_token"]),
                  let output = perMillion(d["output_cost_per_token"]),
                  input > 0, output > 0 else { continue }
            let ver = version(of: key) ?? 0
            if let have = best[fam], have.version >= ver { continue }
            var p = ModelPrice.standard(input: input, output: output)
            if let cw = perMillion(d["cache_creation_input_token_cost"]) { p.cacheWrite = cw }
            if let cr = perMillion(d["cache_read_input_token_cost"]) { p.cacheRead = cr }
            best[fam] = (ver, p)
        }
        var out: [String: ModelPrice] = [:]
        for (fam, v) in best { out[fam] = v.price }
        return out
    }

    // Наш собственный файл кэша: та же форма, что у ручного pricing.json,
    // плюс отметка времени. Держим разобранное, а не исходник LiteLLM:
    // тот весит мегабайты и почти весь про чужих провайдеров.
    static func encode(_ table: [String: ModelPrice], at stamp: Double) -> Data? {
        var obj: [String: Any] = ["_fetched_at": stamp]
        for (fam, p) in table {
            obj[fam] = ["input": p.input, "output": p.output,
                        "cache_write": p.cacheWrite, "cache_read": p.cacheRead]
        }
        return try? JSONSerialization.data(withJSONObject: obj)
    }

    static func decodeStamp(_ data: Data) -> Double? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return number(obj["_fetched_at"])
    }
}
