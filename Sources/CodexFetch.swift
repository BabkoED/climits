import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Запрос лимитов Codex. Только сеть и файл входа - разбор в CodexUsage.
//
// Порядок тот же, что у Claude, но короче: один источник, без кэша на
// диске. Последний удачный ответ держится в памяти и показывается с
// подписью «данные от», если следующий не пришёл.
final class CodexAPI {
    static let shared = CodexAPI()

    private(set) var usage: Usage?
    private(set) var plan: String?
    private(set) var lastError: String?
    private var lastTry: Date?
    private var inFlight = false
    // Пауза после 429 - растёт, как у Claude: эндпоинт чужой и защищается.
    private var backoffUntil: Date?
    private var strikes = 0

    static let url = "https://chatgpt.com/backend-api/wham/usage"
    // Только то, чем пользуется Codex: Codex Web, Codex API, CLI, VS Code
    // extension (имена со страницы на 24.09.2026). Остальное OpenAI - не наше.
    static let status = ServiceStatusFetch(
        api: "https://status.openai.com/api/v2/summary.json",
        page: "https://status.openai.com",
        relevant: { n in
            let x = n.lowercased()
            return x.contains("codex") || x == "cli" || x.contains("vs code")
        })

    // Только для снимка в CI.
    func injectForShot(_ u: Usage, plan p: String?) {
        usage = u
        plan = p
        lastError = nil
        lastTry = Date()
    }

    func refreshIfDue(ttl: TimeInterval, force: Bool = false, _ done: @escaping () -> Void) {
        guard Prefs.codexEnabled, !inFlight else { return }
        if let b = backoffUntil, Date() < b { return }
        if !force, let t = lastTry, Date().timeIntervalSince(t) < ttl { return }
        lastTry = Date()

        guard let data = try? Data(contentsOf: CodexAuth.path()),
              let tok = CodexAuth.parse(data) else {
            lastError = L("нет входа в Codex - запусти codex и войди", "not logged in to Codex - run codex")
            done()
            return
        }
        guard let url = URL(string: CodexAPI.url) else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer " + tok.value, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Prefs.userAgent, forHTTPHeaderField: "User-Agent")
        if let a = tok.account { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        inFlight = true

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = (code == 200 ? data : nil).flatMap { CodexUsageParser.parse($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                switch code {
                case 200 where parsed != nil:
                    self.usage = parsed!.usage
                    self.plan = parsed!.plan
                    self.lastError = nil
                    self.strikes = 0
                    self.backoffUntil = nil
                case 200:
                    self.lastError = L("ответ Codex не разобран", "Codex answer not understood")
                case 401, 403:
                    // Токен протух. Обновлять его сами не берёмся: файлом
                    // владеет Codex, и запись в чужой файл входа - это
                    // шанс разлогинить саму программу.
                    self.lastError = L("вход в Codex истёк - запусти codex", "Codex login expired - run codex")
                    // Пауза и здесь: протухший токен иначе уходил бы на
                    // chatgpt.com каждую минуту, пока человек не войдёт.
                    // Файл входа перечитывается после паузы - новый вход
                    // подхватится сам.
                    self.backoffUntil = Date().addingTimeInterval(15 * 60)
                case 429:
                    self.strikes += 1
                    self.backoffUntil = Date().addingTimeInterval(min(3600, 120 * pow(2, Double(self.strikes))))
                    self.lastError = L("Codex попросил не частить", "Codex asked to slow down")
                case 0:
                    self.lastError = L("Codex не ответил", "Codex did not answer")
                default:
                    self.lastError = "Codex HTTP \(code)"
                }
                done()
            }
        }.resume()
    }
}
