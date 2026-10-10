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
    // top - самый высокий порог, о котором уже сообщили в ЭТОМ окне лимита
    // (0 - ни о каком). Одного числа хватает на всё:
    //   * сообщаем, только когда пройден порог выше сообщённого: скачок
    //     с 70% на 95% через пороги 75 и 90 даёт одно сообщение, о 90;
    //   * порог не выше сообщённого молчит - в том числе добавленный или
    //     опущенный правкой правила посреди окна. Первая версия помнила
    //     пороги поштучно, и правка «90 -> 85» после сработавших 90 давала
    //     второе сообщение в том же окне (ревью 10.10.2026);
    //   * процент упал ниже сообщённого внутри окна - взводим заново с того
    //     порога, что пройден сейчас. Правка правила при этом взвода не
    //     даёт: смотрим на процент, а не на список порогов.
    struct Step: Equatable {
        var send: Int?
        var top: Int
    }

    static func step(pct: Int, thresholds: [Int], top: Int) -> Step {
        let crossed = thresholds.filter { pct >= $0 }.max() ?? 0
        if crossed > top { return Step(send: crossed, top: crossed) }
        if pct < top { return Step(send: nil, top: crossed) }
        return Step(send: nil, top: top)
    }

    // Запись «окно|порог» в настройках: какой порог сообщён и для какого
    // окна. Запись чужого окна читается нулём - новое окно, новый счёт.
    static func record(stamp: String, top: Int) -> String { return stamp + "|\(top)" }

    static func top(from record: String?, stamp: String) -> Int {
        guard let r = record, let bar = r.lastIndex(of: "|"),
              String(r[r.startIndex..<bar]) == stamp,
              let n = Int(r[r.index(after: bar)...]) else { return 0 }
        return n
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
