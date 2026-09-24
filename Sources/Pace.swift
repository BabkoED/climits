import Foundation

// Темп окна: тратишь быстрее или медленнее ровного.
//
// ЗАЧЕМ. «57%» само по себе не отвечает на «работать дальше или
// подождать»: 57% за первый час пятичасового окна и 57% за четвёртый -
// противоположные ответы. Приём из CodexBar («Pace: Behind (-42%) ·
// Lasts to reset»): сравнить процент с долей прошедшего окна.
//
// Чем это отличается от прогноза в History. Прогноз берёт наклон по
// своим замерам за последние десятки минут - он точнее, но ему нужны
// замеры, и после запуска его нет. Темп считается сразу из двух чисел,
// которые приходят в каждом ответе, - процента и времени сброса, - и
// длины окна, которая следует из его имени. Первый отвечает «что будет
// при нынешней скорости», второй - «сколько потрачено против ровного».
enum Pace {
    // Длина окна по ключу. Незнакомый ключ - нет темпа: придумывать
    // длину окна, которое завёл Anthropic, нельзя.
    static func windowLength(key: String) -> TimeInterval? {
        if key == "five_hour" { return 5 * 3600 }
        if key == "seven_day" || key.hasPrefix("seven_day_") || key == UsageParser.fableKey {
            return 7 * 86400
        }
        return nil
    }

    struct Reading: Equatable {
        let expected: Int       // сколько было бы при ровной трате, %
        let delta: Int          // процент минус ровный: минус - с запасом
        let lastsToReset: Bool  // при средней скорости окна хватит до сброса
        let hitsAt: Date?       // когда упрёшься при средней скорости окна
    }

    // Пять процентов в обе стороны - «ровно». Меньше - это шум округления
    // процента и минутной точности сброса, и слово «быстрее» на 2% только
    // пугало бы зря.
    static let evenBand = 5

    // window - длина окна из ответа, если провайдер её говорит сам.
    static func reading(key: String, pct: Int, resetsAt: Date?, window: TimeInterval? = nil,
                        now: Date = Date()) -> Reading? {
        guard let len = window ?? windowLength(key: key), len > 0, let r = resetsAt else { return nil }
        let left = r.timeIntervalSince(now)
        guard left > 0, left <= len * 1.05 else { return nil }
        let elapsed = max(0, len - left)
        // Первые пять минут окна - доля прошедшего почти ноль, и любой
        // процент выглядел бы «впереди в тысячу раз». Молчим.
        guard elapsed >= 300 else { return nil }
        let expected = Int((elapsed / len * 100).rounded())
        let delta = pct - expected

        // Средняя скорость по окну: pct за elapsed. Хватит ли её до конца.
        let perSec = Double(pct) / elapsed
        var hits: Date? = nil
        var lasts = true
        // Уже упёрся - «упрёшься в <сейчас>» было бы бессмыслицей (ревью
        // 1.20.0). Время упора неизвестно и не нужно: лимит выбран.
        if pct >= 100 {
            return Reading(expected: expected, delta: delta, lastsToReset: false, hitsAt: nil)
        }
        if perSec > 0 {
            let toFull = Double(max(0, 100 - pct)) / perSec
            if toFull < left {
                lasts = false
                hits = now.addingTimeInterval(toFull)
            }
        }
        return Reading(expected: expected, delta: delta, lastsToReset: lasts, hitsAt: hits)
    }

    // «Темп: с запасом (−42%) · хватит до сброса». Знак минус - настоящий
    // минус (U+2212), а не дефис: у дефиса другая ширина, и в столбике
    // карточек числа разъезжались бы.
    static func text(_ r: Reading, hhmm: (Date) -> String) -> String {
        let signed = r.delta > 0 ? "+\(r.delta)%" : (r.delta < 0 ? "\u{2212}\(-r.delta)%" : "0%")
        let word: String
        if r.delta <= -evenBand {
            word = L("с запасом", "behind")
        } else if r.delta >= evenBand {
            word = L("быстрее ровного", "ahead")
        } else {
            word = L("ровно", "on pace")
        }
        let tail: String
        if r.lastsToReset {
            tail = L("хватит до сброса", "lasts to reset")
        } else if let h = r.hitsAt {
            tail = L("упрёшься в \(hhmm(h))", "runs out at \(hhmm(h))")
        } else {
            tail = L("лимит выбран", "limit used up")
        }
        return L("Темп: ", "Pace: ") + word + " (\(signed)) \u{00B7} " + tail
    }
}
