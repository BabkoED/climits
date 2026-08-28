import Foundation
#if canImport(Security)
import Security
#endif

// Чтение токена Claude Code из системной связки ключей.
//
// Почему через /usr/bin/security, а не через SecItemCopyMatching: доступ к
// записи выдан приложению Claude Code, и обращение к ней из чужого бинарника
// подняло бы диалог «разрешить доступ» либо просто вернуло errSecAuthFailed.
// Утилита security подписана Apple и штатно спрашивает разрешение один раз,
// после чего работает молча. Тот же путь используют и Claude Code, и оба
// известных мне сторонних индикатора лимитов.
//
// Токен никуда не пишется и не логируется: он живёт только в памяти процесса
// и уходит единственным заголовком Authorization на api.anthropic.com.

struct KeychainToken {
    let value: String
    let expiresAt: Date?   // nil, если в записи нет поля expiresAt

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return exp < Date()
    }
}

enum KeychainError: Error, LocalizedError {
    case notFound
    case unparsable(previewRedacted: String)
    case expired(Date?)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return L("не нашёл токен в связке ключей. Залогинься один раз: claude",
                     "no token in the keychain. Log in once: claude")
        case .unparsable:
            return L("запись в связке ключей есть, но токен из неё не читается",
                     "keychain entry found, but the token cannot be parsed")
        case .expired(let when):
            let tail: String
            if let w = when {
                let f = DateFormatter()
                f.dateFormat = "dd.MM HH:mm"
                tail = " (" + f.string(from: w) + ")"
            } else {
                tail = ""
            }
            return L("токен истёк\(tail). Запусти 'claude' в терминале - он обновит токен сам",
                     "token expired\(tail). Run 'claude' in a terminal to refresh it")
        }
    }
}

struct Keychain {
    static let service = "Claude Code-credentials"

    // Запуск внешней команды с перехватом stdout. Возвращает nil, если
    // команда не нашлась или завершилась с ошибкой.
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        // Читаем ДО waitUntilExit: security dump-keychain выдаёт заметный
        // объём, и на полном буфере трубы процесс встал бы намертво, а мы
        // ждали бы его завершения. Классический дедлок.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Сырое содержимое записи: обычно JSON вида
    //   {"claudeAiOauth":{"accessToken":"...","expiresAt":1770000000000,...}}
    // но на части сборок там лежит сам токен без обёртки.
    static func rawEntry(account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let a = account { args.insert(contentsOf: ["-a", a], at: 1) }
        guard let s = run("/usr/bin/security", args), !s.isEmpty else { return nil }
        return s
    }

    static func parse(_ raw: String) -> KeychainToken? {
        // JSON: сначала вложенный claudeAiOauth, потом плоский accessToken.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let node = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
            if let tok = node["accessToken"] as? String, !tok.isEmpty {
                var exp: Date? = nil
                // expiresAt приходит в МИЛЛИСЕКУНДАХ. Делить обязательно:
                // без деления дата уезжает в 57-й тысячный год и проверка
                // «истёк ли токен» становится бессмысленной.
                if let ms = jsonNumber(node["expiresAt"]) {
                    exp = Date(timeIntervalSince1970: ms / 1000.0)
                }
                return KeychainToken(value: tok, expiresAt: exp)
            }
        }
        // Не JSON - считаем, что это сам токен.
        if !raw.contains("{") {
            return KeychainToken(value: raw, expiresAt: nil)
        }
        return nil
    }

    // Имена учётных записей всех записей с нашим service.
    //
    // Через SecItemCopyMatching, а не разбором вывода `security dump-keychain`:
    // здесь запрашиваются АТРИБУТЫ, а не сам секрет, и такой запрос не поднимает
    // диалог авторизации и не требует прав на содержимое. Разбор dump-keychain
    // остаётся запасным путём - он медленный, зависит от формата вывода,
    // и на части систем сам показывает диалог.
    //
    // Сам секрет всё равно читается через /usr/bin/security (см. readEntry):
    // тогда ACL на записи принадлежит подписанному Apple бинарнику,
    // и пользовательское «всегда разрешать» переживает пересборки приложения.
    static func duplicateAccounts() -> [String] {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
            if !accounts.isEmpty { return Array(Set(accounts)).sorted() }
        }
#endif
        return accountsFromDump()
    }

    // Запасной путь: разбор `security dump-keychain`.
    private static func accountsFromDump() -> [String] {
        guard let dump = run("/usr/bin/security", ["dump-keychain"]) else { return [] }
        var accounts: [String] = []
        var acct: String? = nil
        var svce: String? = nil
        func flush() {
            if svce == service, let a = acct, !a.isEmpty, !accounts.contains(a) {
                accounts.append(a)
            }
            acct = nil; svce = nil
        }
        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("class:") { flush() }
            if let v = blobValue(l, key: "acct") { acct = v }
            if let v = blobValue(l, key: "svce") { svce = v }
        }
        flush()
        return accounts
    }

    // Разбор строки вида:  "acct"<blob>="user@example.com"
    private static func blobValue(_ line: String, key: String) -> String? {
        let marker = "\"\(key)\"<blob>=\""
        guard let start = line.range(of: marker) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.range(of: "\"") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    // Все пригодные записи, самая свежая первой.
    //
    // Нужно из-за реального случая от пользователя: в связке лежат две записи
    // Claude Code, одна битая, и `security -w` отдаёт именно битую. Симптом
    // при этом какой угодно - и «токен не читается», и «токен истёк», и
    // честный HTTP 401 на живой с виду токен. Поэтому список кандидатов
    // строится один раз, а разбираться, который из них рабочий, приходится
    // уже по ответу сервера.
    static func candidates() -> [KeychainToken] {
        var found: [KeychainToken] = []
        var seen = Set<String>()

        func add(_ raw: String?) {
            guard let r = raw, let t = parse(r), !seen.contains(t.value) else { return }
            seen.insert(t.value)
            found.append(t)
        }

        add(rawEntry())
        for acct in duplicateAccounts() { add(rawEntry(account: acct)) }

        // Живые вперёд, а внутри каждой группы - у кого срок дальше.
        // Запись без expiresAt считаем живой: на части сборок поля просто нет,
        // и отбрасывать её было бы хуже, чем попробовать.
        return found.sorted { a, b in
            if a.isExpired != b.isExpired { return !a.isExpired }
            return (a.expiresAt ?? .distantFuture) > (b.expiresAt ?? .distantFuture)
        }
    }

    // Основная точка входа: лучший из кандидатов или ошибка с понятной причиной.
    static func token() throws -> KeychainToken {
        let all = candidates()
        if let best = all.first, !best.isExpired { return best }
        if let newest = all.first { throw KeychainError.expired(newest.expiresAt) }
        // Кандидатов нет вовсе: либо записи нет, либо она не разбирается.
        guard let raw = rawEntry() else { throw KeychainError.notFound }
        throw KeychainError.unparsable(previewRedacted: redact(raw))
    }

    // Для --doctor: показать СТРОЕНИЕ записи, не печатая ни одного значения.
    //
    // Прежняя версия печатала первые 300 байт с заменой длинных
    // последовательностей на <REDACTED>. Это опасная схема: токены бывают
    // в base64url, где встречаются знаки вне класса символов, и тогда длинная
    // строка распадается на короткие куски, каждый из которых замену
    // не проходит. Часть секрета утекала бы в вывод, который человек
    // спокойно копирует в чат.
    //
    // Поэтому теперь печатаются только имена ключей. Для ответа на вопрос
    // «что вообще лежит в записи» этого достаточно, а утечь тут нечему.
    static func redact(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "не JSON, " + String(s.count) + " байт" }

        func keys(_ d: [String: Any], prefix: String = "") -> [String] {
            var out: [String] = []
            for k in d.keys.sorted() {
                let path = prefix.isEmpty ? k : prefix + "." + k
                if let nested = d[k] as? [String: Any] {
                    out += keys(nested, prefix: path)
                } else {
                    out.append(path)
                }
            }
            return out
        }
        return keys(obj).joined(separator: "  ")
    }
}
