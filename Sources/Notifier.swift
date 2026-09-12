import AppKit
import UserNotifications

// Уведомление при подходе к порогу.
//
// Два правила, без которых уведомления быстро начинают раздражать и их
// выключают навсегда:
//   1) сообщаем один раз на пересечение, а не каждые пять минут, пока
//      процент держится выше порога;
//   2) после сброса лимита взводим заново - иначе за неделю сообщение
//      придёт один раз и больше никогда.
enum Notifier {
    private static var authorized: Bool? = nil

    // Ключ запоминается по лимиту: пятичасовое и недельное окно оповещают
    // независимо друг от друга.
    private static func firedKey(_ key: String) -> String { return "notified." + key }

    static func check(_ usage: Usage) {
        guard Prefs.notifyEnabled else { return }
        // По несвежим цифрам не оповещаем. Иначе после суток без сети
        // приходит сообщение о пороге, пройденном двадцать часов назад,
        // и выглядит это как срабатывание сейчас.
        guard !usage.isStale else { return }

        let threshold = Prefs.notifyAt
        let d = UserDefaults.standard

        for b in usage.buckets {
            let key = firedKey(b.key)
            // Запоминаем не «оповещали ли», а ДЛЯ КАКОГО окна оповещали.
            // Взвод по просадке ниже порога не работал: пока приложение
            // не видело просадку - а его могли не запускать сутки - новое
            // окно оставалось без предупреждения вовсе.
            let stamp = b.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "no-reset"
            let firedFor = d.string(forKey: key)

            if b.pct >= threshold {
                if firedFor != stamp {
                    d.set(stamp, forKey: key)
                    send(title: L("Лимит на исходе", "Limit running out"),
                         // В уведомлении «через» уместно: оно приходит само,
                         // без шкалы рядом, и «1д 3ч» без предлога читается
                         // как длительность, а не как остаток.
                         body: "\(b.long): \(b.pct)% \u{00B7} "
                             + L("через ", "in ") + Fmt.untilReset(b.resetsAt))
                }
            } else if firedFor == stamp {
                // Ушли ниже порога внутри того же окна - взводим заново.
                d.removeObject(forKey: key)
            }
        }
    }

    // Сессия крутится на месте - сказать, не дожидаясь, пока откроют меню.
    //
    // ЗАЧЕМ ОТДЕЛЬНО ОТ ЛИМИТОВ. Сторож, о котором узнаёшь только открыв
    // меню, ловит кручение тогда же, когда его поймал бы и человек, -
    // то есть не раньше. А цена как раз во времени: сессия тратит лимит
    // и деньги всё время, пока её не трогают.
    //
    // ПОЧЕМУ ЭТО НЕ ЗАВАЛИТ УВЕДОМЛЕНИЯМИ. Реплей по 286 сессиям дал три
    // тревоги - примерно одну на сотню. Отдельного порога тут не нужно:
    // правило само по себе редкое, а лишний порог на редком событии
    // означает, что единственный настоящий случай тоже не дойдёт.
    //
    // САМО ПРАВИЛО - в LoopNotice, и это не разделение ради красоты:
    // здесь AppKit, а значит на машине разработчика этот файл не
    // типизируется вовсе, и ошибка в «сообщать один раз» вылезла бы
    // сорока одинаковыми уведомлениями подряд у человека. Там она
    // закрыта тестами.
    private static let loopKeys = "notified.loop.keys"

    static func checkLoops(_ sessions: [AgentSession]) {
        guard Prefs.notifyEnabled, Prefs.watchLoops else { return }
        let d = UserDefaults.standard

        // Что помним. Список ключей держим отдельно: пройтись по всему
        // домену настроек ради своих записей нельзя, а забывать исчезнувшие
        // сессии надо - иначе переиспользованный pid унаследует отпечаток
        // и заглушит настоящую тревогу.
        var known: [String: String] = [:]
        for k in (d.stringArray(forKey: loopKeys) ?? []) {
            if let v = d.string(forKey: k) { known[k] = v }
        }

        let plan = LoopNotice.plan(sessions, known: known)
        for k in plan.forget {
            d.removeObject(forKey: k)
            known.removeValue(forKey: k)
        }
        for item in plan.send {
            d.set(item.stamp, forKey: item.key)
            known[item.key] = item.stamp
            send(title: item.title, body: item.body)
        }
        d.set(Array(known.keys).sorted(), forKey: loopKeys)
    }

    private static func send(title: String, body: String) {
        // Центр уведомлений спрашивается лениво, при первом же поводе:
        // приложение, которое просит разрешение на старте, ничего ещё
        // не показав, разрешение обычно и не получает.
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
    }
}
