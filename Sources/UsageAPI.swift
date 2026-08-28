import Foundation

// Сеть и кэш.
//
// Главная мысль этого файла: неудачный запрос - НЕ повод показывать пустоту.
// Пока у нас есть последний успешный ответ и он не совсем древний, честнее
// показать его с пометкой «данные от 14:20», чем значок ошибки. Единственное
// исключение - отвергнутый токен: там нужно действие пользователя, и старые
// цифры это действие только отсрочат.

enum UsageError: Error, LocalizedError {
    case auth(Int)            // 401/403 - нужен перелогин
    case rateLimited          // 429 и нет сохранённых данных
    case offline              // сети нет и нет сохранённых данных
    case http(Int)
    case unparsable
    case badValues
    case keychain(Error)

    var errorDescription: String? {
        switch self {
        case .auth(let c):
            return L("токен отвергнут (HTTP \(c)). Перелогинься: claude",
                     "token rejected (HTTP \(c)). Log in again: claude")
        case .rateLimited:
            return L("слишком часто запрашиваем (HTTP 429), сохранённых данных нет",
                     "rate limited (HTTP 429) and no cached data")
        case .offline:
            return L("нет ответа от api.anthropic.com - проверь сеть",
                     "no response from api.anthropic.com - check the network")
        case .http(let c):
            return L("api.anthropic.com ответил HTTP \(c)",
                     "api.anthropic.com returned HTTP \(c)")
        case .unparsable:
            return L("ответ API не разобрался (структура изменилась?)",
                     "could not parse the API response (schema changed?)")
        case .badValues:
            // Отдельно от unparsable: сказать «структура изменилась», когда
            // в ответе просто нечисловые значения, - это соврать о причине.
            return L("в ответе нечисловые значения - показывать нечего",
                     "the response carries non-numeric values - nothing to show")
        case .keychain(let e):
            return (e as? LocalizedError)?.errorDescription ?? "\(e)"
        }
    }
}

final class UsageAPI {
    static let shared = UsageAPI()

    private let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let queue = DispatchQueue(label: "com.babko.climits.api")

    // Куда складываем последний успешный ответ. Каталог Application Support,
    // а не /tmp: перезагрузка не должна стирать то, что мы покажем при
    // отсутствии сети.
    private var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("climits", isDirectory: true)
    }
    var cacheFile: URL { return dir.appendingPathComponent("usage.json") }

    // Сколько показывать старые данные, если обновиться не удалось.
    let staleMax: TimeInterval = 24 * 3600

    // Нижний порог между запросами. Ниже него не опускается ничто: ни таймер,
    // ни открытие меню. Ручное обновление проходит быстрее, но не мгновенно -
    // иначе двойной клик по «Обновить» это два запроса подряд.
    let minRequestGap: TimeInterval = 60
    let minForcedGap: TimeInterval = 5

    // Пауза после 429 растёт: 5 -> 10 -> 20 -> 40 -> 60 минут, и сбрасывается
    // первым же успешным ответом.
    //
    // Плоские 15 минут были хуже с обеих сторон: при разовом 429 они слишком
    // долго молчат, а при устойчивом - слишком часто долбятся. Заголовок
    // retry-after у этого эндпоинта врёт (claude-code#30930), поэтому расписание
    // ведём своё.
    //
    // Счётчик и срок лежат в настройках, а не в памяти: перезапуск приложения
    // не должен обнулять паузу, иначе выход и запуск превращаются в способ
    // обойти собственную защиту.
    private var strikes: Int {
        get { UserDefaults.standard.integer(forKey: "rl.strikes") }
        set { UserDefaults.standard.set(newValue, forKey: "rl.strikes") }
    }
    private var backoffUntil: Date? {
        get { UserDefaults.standard.object(forKey: "rl.until") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "rl.until") }
    }
    private var lastAttempt: Date? {
        get { UserDefaults.standard.object(forKey: "rl.lastAttempt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "rl.lastAttempt") }
    }

    private func backoffDelay(for strikes: Int) -> TimeInterval {
        return min(300 * pow(2, Double(max(strikes - 1, 0))), 3600)
    }

    // Когда состоится следующая попытка. Показывается в меню: «пробую снова
    // в 14:35» честнее, чем молчаливый значок.
    var nextAttemptAt: Date? {
        guard let until = backoffUntil, until > Date() else { return nil }
        return until
    }

    private func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func mtime(_ u: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        return attrs?[.modificationDate] as? Date
    }

    var cacheAge: TimeInterval? {
        guard let m = mtime(cacheFile) else { return nil }
        return Date().timeIntervalSince(m)
    }

    var inCooldown: Bool {
        return nextAttemptAt != nil
    }

    private func readCache() -> (body: String, at: Date)? {
        guard let m = mtime(cacheFile),
              let s = try? String(contentsOf: cacheFile, encoding: .utf8),
              !s.isEmpty else { return nil }
        return (s, m)
    }

    private func writeCache(_ body: String) {
        ensureDir()
        // Пишем через временный файл: если процесс умрёт на середине записи,
        // мы потеряем обновление, но не то, что уже лежало.
        let tmp = cacheFile.appendingPathExtension("tmp")
        do {
            // Файл создаётся УЖЕ закрытым. Прежний порядок - записать,
            // потом chmod - оставлял содержимое на диске с правами
            // по умолчанию на время между двумя вызовами.
            try? FileManager.default.removeItem(at: tmp)
            _ = FileManager.default.createFile(atPath: tmp.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            try body.write(to: tmp, atomically: false, encoding: .utf8)
            _ = try? FileManager.default.replaceItemAt(cacheFile, withItemAt: tmp,
                                                      options: [.usingNewMetadataOnly])
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private func stale() -> Usage? {
        guard let c = readCache() else { return nil }
        guard Date().timeIntervalSince(c.at) <= staleMax else { return nil }
        return UsageParser.parse(body: c.body, fetchedAt: c.at, isStale: true)
    }

    // ttl - сколько ответ считается свежим. force обходит ttl, но НЕ обходит
    // паузу после 429: ручное обновление не должно превращаться в способ
    // додолбить эндпоинт.
    func fetch(ttl: TimeInterval, force: Bool, completion: @escaping (Result<Usage, UsageError>) -> Void) {
        queue.async {
            let result = self.fetchSync(ttl: ttl, force: force)
            DispatchQueue.main.async { completion(result) }
        }
    }


    private func sanitizeHeader(_ v: String) -> String {
        let cleaned = v.components(separatedBy: CharacterSet(charactersIn: "\r\n\0"))
                       .joined(separator: " ")
                       .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? Prefs.defaultUserAgent : String(cleaned.prefix(200))
    }

    // Один запрос к эндпоинту. Вынесен отдельно, потому что вызывается
    // по разу на каждый кандидат из связки ключей.
    private func request(token: String) -> (code: Int, body: Data?) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // User-Agent настраиваемый - подробности в README, раздел «Про 429».
        // Коротко: ходит мнение, что без «правильного» значения запросы
        // попадают в жёстко лимитируемый бакет. По первоисточникам это
        // не подтверждается, поэтому по умолчанию представляемся честно,
        // а подменить значение можно одной строкой в настройках.
        // Значение приходит из настроек, то есть его набирает человек.
        // Перевод строки в заголовке - это разрыв запроса и приписывание
        // к нему чужих заголовков. Своих прав это никому не добавляет,
        // но испорченный запрос выглядит как загадочная ошибка сети.
        req.setValue(sanitizeHeader(Prefs.userAgent), forHTTPHeaderField: "User-Agent")

        var out: Data? = nil
        var status = 0
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { d, resp, _ in
            out = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }
        task.resume()
        // Ждём чуть дольше сетевого таймаута: если URLSession почему-то
        // не вызовет обработчик, лучше отпустить поток, чем повесить всё.
        _ = sem.wait(timeout: .now() + 15)
        return (status, out)
    }

    func fetchSync(ttl: TimeInterval, force: Bool) -> Result<Usage, UsageError> {
        if !force, let c = readCache(), Date().timeIntervalSince(c.at) < ttl {
            if let u = UsageParser.parse(body: c.body, fetchedAt: c.at, isStale: false) {
                return .success(u)
            }
        }

        if inCooldown {
            if let u = stale() { return .success(u) }
            return .failure(.rateLimited)
        }

        // Нижний порог между обращениями к сети.
        let gap = force ? minForcedGap : minRequestGap
        if let last = lastAttempt, Date().timeIntervalSince(last) < gap {
            if let u = stale() { return .success(u) }
        }
        lastAttempt = Date()

        // Кандидатов может быть несколько: в связке ключей нередко лежит
        // не одна запись Claude Code, и первая по счёту вполне может быть
        // битой - об этом сообщил живой пользователь, у которого security
        // стабильно отдавал именно кривую. Перебираем по очереди, но только
        // пока сервер отвечает 401/403: на любой другой ответ останавливаемся,
        // иначе каждая сетевая неурядица превращалась бы в веер запросов.
        let tokens = Keychain.candidates()
        if tokens.isEmpty {
            do { _ = try Keychain.token() }          // бросит внятную причину
            catch { return .failure(.keychain(error)) }
            return .failure(.auth(401))
        }

        var body: Data? = nil
        var code = 0
        for tok in tokens {
            let r = request(token: tok.value)
            body = r.body
            code = r.code
            if code != 401 && code != 403 { break }
        }

        switch code {
        case 200:
            guard let d = body, let s = String(data: d, encoding: .utf8), !s.isEmpty else {
                return .failure(.unparsable)
            }
            guard let u = UsageParser.parse(body: s, fetchedAt: Date(), isStale: false) else {
                // Ответ пришёл, но разобрать нечего. Кэш не портим: пусть
                // лучше показываются прежние цифры, чем ничего.
                let low = s.lowercased()
                let nonNumeric = low.contains("nan") || low.contains("inf")
                return .failure(nonNumeric ? .badValues : .unparsable)
            }
            writeCache(s)
            strikes = 0
            backoffUntil = nil
            return .success(u)

        case 429:
            strikes += 1
            backoffUntil = Date().addingTimeInterval(backoffDelay(for: strikes))
            if let u = stale() { return .success(u) }
            return .failure(.rateLimited)

        case 401, 403:
            // Тут старые цифры показывать нельзя: проблема требует действия.
            return .failure(.auth(code))

        case 0:
            if let u = stale() { return .success(u) }
            return .failure(.offline)

        default:
            if let u = stale() { return .success(u) }
            return .failure(.http(code))
        }
    }
}
