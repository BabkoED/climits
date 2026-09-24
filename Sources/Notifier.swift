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
        let windows = usage.buckets.map {
            ResetNotice.Window(key: $0.key, pct: $0.pct, resetsAt: $0.resetsAt, isModel: $0.isModel)
        }

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
                    // Окно сменилось с прошлого предупреждения. Если старое
                    // кончилось досрочно, его «лимит снова есть» стоит на
                    // время, которого больше нет, - снимаем.
                    if ResetNotice.stale(oldStamp: firedFor) { cancelReset(b.key) }
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
                // Сообщать о сбросе окна, в которое не упёрлись, незачем.
                d.removeObject(forKey: key)
                cancelReset(b.key)
            } else if ResetNotice.stale(oldStamp: firedFor) {
                // Окно сбросили досрочно, а процент ниже порога: старое
                // сообщение пришло бы в прошлое время сброса и соврало.
                d.removeObject(forKey: key)
                cancelReset(b.key)
            }

            // «Лимит снова есть» - сверяется с текущим положением на
            // КАЖДОМ обновлении, а не ставится раз навсегда: неделя могла
            // упереться уже после предупреждения о пятичасовом окне, и
            // тогда «можно работать» стало бы враньём (ревью 24.09.2026).
            if d.string(forKey: key) == stamp {
                planReset(b, among: windows)
            }
        }
    }

    private static func sigKey(_ key: String) -> String { return "resetsig." + key }

    // Поставить, заменить или снять «лимит снова есть» для этого лимита.
    // Подпись (окно + мешает ли что-то) помнится, чтобы не переставлять
    // одно и то же на каждом обновлении.
    private static func planReset(_ b: Bucket, among windows: [ResetNotice.Window]) {
        let d = UserDefaults.standard
        guard Prefs.notifyReset else { return }
        let me = windows.first { $0.key == b.key }
            ?? ResetNotice.Window(key: b.key, pct: b.pct, resetsAt: b.resetsAt, isModel: b.isModel)
        let blocked = ResetNotice.blocked(me, among: windows)
        let stamp = b.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "no-reset"
        let sig = stamp + (blocked ? "#blocked" : "#open")
        guard d.string(forKey: sigKey(b.key)) != sig else { return }
        d.set(sig, forKey: sigKey(b.key))
        if blocked {
            cancelReset(b.key, keepSig: true)
        } else if let after = ResetNotice.delay(resetsAt: b.resetsAt) {
            let t = ResetNotice.text(long: b.long)
            send(title: t.title, body: t.body, id: ResetNotice.id(b.key), after: after)
        }
    }

    private static func cancelReset(_ key: String, keepSig: Bool = false) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [ResetNotice.id(key)])
        if !keepSig { UserDefaults.standard.removeObject(forKey: sigKey(key)) }
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

    static func checkLoops(_ all: [AgentSession]) {
        guard Prefs.notifyEnabled, Prefs.watchLoops else { return }
        // «Скрыть личное» касается и уведомлений: баннер на демонстрации
        // экрана виден так же, как меню (ревью 24.09.2026 - имя из
        // `/rename` уходило в баннер). Ключ тревоги - машина и pid, они
        // обезличиванием не трогаются, так что «сказать один раз» держится.
        let sessions = Prefs.privacyMode ? Sessions.anonymized(all) : all
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

    // Снять все поставленные «лимит снова есть» - галочку выключили.
    // prefix - снять только лимиты одного провайдера (выключили Codex).
    static func cancelResets(prefix: String = "") {
        // И подписи тоже: иначе после повторного включения сообщение не
        // встало бы заново - подпись сказала бы «уже стоит».
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("resetsig." + prefix) {
            d.removeObject(forKey: k)
        }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map { $0.identifier }.filter { $0.hasPrefix("reset." + prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // id и after - для отложенного сообщения. Тот же id заменяет прежнее,
    // а не ставит второе рядом.
    private static func send(title: String, body: String,
                             id: String? = nil, after: TimeInterval? = nil) {
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
            let trigger = after.map {
                UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false)
            }
            let req = UNNotificationRequest(identifier: id ?? UUID().uuidString,
                                            content: content, trigger: trigger)
            center.add(req, withCompletionHandler: nil)
        }
    }
}
