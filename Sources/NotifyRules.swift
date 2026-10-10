import Foundation

// Правила уведомлений (1.22.0).
//
// До 1.22.0 порог был один на все лимиты: «уведомлять с 80%». Неделе и
// пятичасовому окну нужны разные пороги - неделя на 80% значит «осталось
// полтора дня», окно на 80% значит «осталось полчаса», - а одним числом
// это не скажешь. Теперь порогов сколько угодно, у каждого свой лимит:
// «Когда [неделя] превышает [90]%». Образец - Usage for Claude, его окно
// Антон прислал 10.10.2026.
//
// Файл без AppKit намеренно: здесь решается, слать ли уведомление, и
// ошибка в «один раз на окно» вылезла бы у человека пачкой одинаковых
// сообщений. Notifier.swift на Linux не типизируется вовсе, а этот
// файл проверяется тестами.
struct NotifyRule: Equatable {
    enum Scope: String, CaseIterable {
        case any
        case fiveHour = "five_hour"
        case week = "seven_day"
        case models
        case codex
    }

    var scope: Scope
    var at: Int
    var on: Bool

    // Подходит ли правило этому лимиту. Ключи - как у Bucket: «five_hour»,
    // «seven_day», «seven_day_opus», у Codex - с приставкой «codex_».
    func matches(key: String, isModel: Bool) -> Bool {
        let codex = key.hasPrefix("codex_")
        switch scope {
        case .any: return true
        case .fiveHour: return key == "five_hour"
        case .week: return key == "seven_day"
        case .models: return isModel && !codex
        case .codex: return codex
        }
    }
}

enum NotifyRules {
    static let maxRules = 8

    // «any:80:1;seven_day:90:0» - одной строкой в настройках. Мусор
    // пропускается молча: правка plist руками не должна ронять уведомления
    // целиком из-за одной кривой записи.
    static func parse(_ s: String) -> [NotifyRule] {
        var out: [NotifyRule] = []
        for item in s.split(separator: ";") {
            let f = item.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count == 3,
                  let scope = NotifyRule.Scope(rawValue: f[0]),
                  let at = Int(f[1]) else { continue }
            out.append(NotifyRule(scope: scope, at: clamp(at), on: f[2] == "1"))
        }
        return Array(out.prefix(maxRules))
    }

    static func serialize(_ rules: [NotifyRule]) -> String {
        return rules.prefix(maxRules)
            .map { "\($0.scope.rawValue):\(clamp($0.at)):\($0.on ? 1 : 0)" }
            .joined(separator: ";")
    }

    static func clamp(_ n: Int) -> Int { return max(1, min(100, n)) }

    // Пороги этого лимита: только включённые правила, по возрастанию,
    // без повторов. Пусто - правил на этот лимит нет.
    static func thresholds(key: String, isModel: Bool, rules: [NotifyRule]) -> [Int] {
        let ts = rules.filter { $0.on && $0.matches(key: key, isModel: isModel) }.map { $0.at }
        return Array(Set(ts)).sorted()
    }

    // Решение по одному лимиту на этом обновлении.
    //
    // fired - для какого окна (stamp) какой порог уже сообщён. Сообщаем один
    // раз на окно и порог, и только самый высокий из впервые пройденных:
    // скачок с 70% на 95% через пороги 75 и 90 даёт одно сообщение, а не
    // два подряд. Порог ниже уже сообщённого в этом окне тоже молчит -
    // иначе правило «75%», добавленное на 92%, прислало бы «75%» после «90%».
    //
    // legacyUpTo - переход с 1.21: прежняя версия помнила одно «сообщено в
    // этом окне» на лимит, без порога. Её порог (notifyAt) считается уже
    // сообщённым, иначе сразу после обновления пришло бы то же сообщение
    // второй раз.
    struct Step: Equatable {
        var send: Int?
        var mark: [Int]
        var clear: [Int]
    }

    static func step(pct: Int, stamp: String, thresholds: [Int],
                     fired: [Int: String], legacyUpTo: Int? = nil) -> Step {
        var known = fired
        if let up = legacyUpTo {
            for t in thresholds where t <= up && known[t] == nil { known[t] = stamp }
        }
        let crossed = thresholds.filter { pct >= $0 }
        let fresh = crossed.filter { known[$0] != stamp }
        let alreadyTop = crossed.filter { known[$0] == stamp }.max() ?? 0
        let top = fresh.max()
        let send = (top != nil && top! > alreadyTop) ? top : nil
        // Ушли ниже порога внутри того же окна - взводим заново.
        let clear = thresholds.filter { pct < $0 && fired[$0] == stamp }
        var mark = fresh
        // Порог из перехода записывается явно: иначе он «сообщён» только
        // пока жива старая запись, а её снимет первый же сброс окна.
        if let up = legacyUpTo {
            for t in crossed where t <= up && fired[t] == nil && !mark.contains(t) { mark.append(t) }
        }
        return Step(send: send, mark: mark.sorted(), clear: clear)
    }

    // Подпись лимита в строке правила.
    static func title(_ s: NotifyRule.Scope) -> String {
        switch s {
        case .any: return L("любой лимит", "any limit")
        case .fiveHour: return L("5-часовое окно", "5-hour window")
        case .week: return L("неделя", "week")
        case .models: return L("неделя по моделям", "per-model week")
        case .codex: return "Codex"
        }
    }
}
