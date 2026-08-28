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
