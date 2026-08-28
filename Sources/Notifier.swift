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
        let threshold = Prefs.notifyAt
        let d = UserDefaults.standard

        for b in usage.buckets {
            let key = firedKey(b.key)
            let already = d.bool(forKey: key)
            if b.pct >= threshold {
                if !already {
                    d.set(true, forKey: key)
                    send(title: L("Лимит на исходе", "Limit running out"),
                         body: L("\(b.long): \(b.pct)% \(Fmt.resetPhrase(b.resetsAt))",
                                 "\(b.long): \(b.pct)% \(Fmt.resetPhrase(b.resetsAt))"))
                }
            } else if already {
                // Ушли ниже порога - значит окно сбросилось, взводим снова.
                d.set(false, forKey: key)
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
