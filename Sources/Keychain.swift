import Foundation

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
                if let ms = numeric(node["expiresAt"]) {
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

    // Числовое поле, которое может приехать числом или строкой.
    static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }

    // Имена учётных записей всех записей с нашим service.
    //
        // Зачем это нужно: в связке ключей нередко лежит несколько записей с
    // одинаковым именем - следы прошлых установок Claude Code. Команда
    // `security ... -w` отдаёт ПЕРВУЮ попавшуюся, и это вполне может быть
    // протухшая запись, тогда как рабочая лежит рядом. Один и тот же симптом:
    // /usage внутри Claude Code показывает цифры, а индикатор в трее говорит
    // «токен истёк».
    static func duplicateAccounts() -> [String] {
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

    // Основная точка входа: живой токен или ошибка с понятной причиной.
    static func token() throws -> KeychainToken {
        guard let raw = rawEntry() else { throw KeychainError.notFound }
        guard let first = parse(raw) else {
            throw KeychainError.unparsable(previewRedacted: redact(raw))
        }
        if !first.isExpired { return first }

        // Первая запись просрочена - перебираем дубликаты и берём самую
        // свежую по expiresAt. Разбор всей связки заметно медленнее, поэтому
        // делаем это только здесь, а не при каждом запросе.
        var best: KeychainToken? = nil
        for acct in duplicateAccounts() {
            guard let r = rawEntry(account: acct), let t = parse(r) else { continue }
            guard let exp = t.expiresAt else { continue }
            if let b = best, let bexp = b.expiresAt, bexp >= exp { continue }
            best = t
        }
        if let b = best, !b.isExpired { return b }
        throw KeychainError.expired(first.expiresAt)
    }

    // Для --doctor: показать структуру записи, не раскрывая секретов.
    // Любая длинная последовательность букв и цифр - это потенциально токен.
    static func redact(_ s: String) -> String {
        let head = String(s.prefix(300))
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9_.-]{16,}") else { return head }
        return re.stringByReplacingMatches(
            in: head, range: NSRange(head.startIndex..., in: head), withTemplate: "<REDACTED>")
    }
}
