import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Скачивание статуса сервиса. Только сеть - весь разбор в ServiceStatus.
//
// Раз в пять минут, не чаще: инцидент длится десятки минут, и заметить
// его на пять минут позже ничего не стоит, а страница статуса - чужой
// сервер. Опрос идёт по тем же поводам, что и лимиты, поэтому отдельного
// таймера нет - только порог между запросами.
final class ServiceStatusFetch {
    // Адрес - свойство провайдера. Сейчас он один, но формат Statuspage
    // общий у Anthropic и OpenAI, и второй провайдер получит свой объект.
    //
    // Сужен до своего с 1.21.0: claude.ai, Claude Code и API. Без этого
    // точка горела 57 часов из-за сбоя одной Console (ревью 09.10.2026).
    static let claude = ServiceStatusFetch(
        api: "https://status.claude.com/api/v2/summary.json",
        page: "https://status.claude.com",
        relevant: ServiceStatus.claudeRelevant,
        unscopedMajor: true)

    let api: String
    let page: String
    private(set) var current: ServiceStatus?
    private var lastTry: Date?
    private var inFlight = false

    static let gap: TimeInterval = 300
    // Сколько верим последнему ответу, если новые не приходят. Дольше
    // держать точку тревоги нельзя: инцидент мог давно закончиться, а
    // значок продолжал бы пугать тем, чего уже нет.
    static let trust: TimeInterval = 30 * 60
    private static let maxBytes = 2 * 1024 * 1024

    // Какие компоненты страницы относятся к нам. nil - вся страница.
    let relevant: ((String) -> Bool)?
    // Крупный инцидент без списка компонентов - свой? У Anthropic да: так
    // размечены сбои всех моделей сразу. У OpenAI нет: там без компонентов
    // приходят все инциденты подряд. См. ServiceStatus.scoped.
    let unscopedMajor: Bool

    init(api: String, page: String, relevant: ((String) -> Bool)? = nil,
         unscopedMajor: Bool = false) {
        self.api = api
        self.page = page
        self.relevant = relevant
        self.unscopedMajor = unscopedMajor
    }

    // Статус, суженный ровно так, как его покажет значок. Одна функция на
    // опрос, `--doctor` и проверки: разойдись они - отчёт спорил бы с трем.
    func narrow(_ s: ServiceStatus) -> ServiceStatus {
        guard let r = relevant else { return s }
        return s.scoped(r, unscopedMajor: unscopedMajor)
    }

    // Что показывать сейчас. nil - спокойно или не знаем; и то и другое
    // на экране выглядит одинаково - ничем.
    var alarm: ServiceStatus? {
        guard let s = current, !s.isCalm else { return nil }
        guard Date().timeIntervalSince(s.fetchedAt) <= ServiceStatusFetch.trust else { return nil }
        return s
    }

    // Только для снимка в CI: сети там нет, а строку сбоя и точку на
    // кольце нужно увидеть глазами - тестами вёрстку не проверить.
    func injectForShot(_ s: ServiceStatus) {
        current = s
        lastTry = Date()
    }

    func refreshIfDue(_ done: @escaping () -> Void) {
        guard Prefs.showServiceStatus, !inFlight else { return }
        if let t = lastTry, Date().timeIntervalSince(t) < ServiceStatusFetch.gap { return }
        guard let url = URL(string: api) else { return }
        inFlight = true
        lastTry = Date()

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(Prefs.userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            // Не ответили - прежний статус остаётся до срока доверия.
            // Сказать «всё хорошо» по пустому ответу было бы выдумкой.
            var parsed: ServiceStatus?
            if let data = data, data.count <= ServiceStatusFetch.maxBytes,
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                parsed = ServiceStatus.parse(data)
                if let me = self { parsed = parsed.map { me.narrow($0) } }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                guard let p = parsed else { return }
                let changed = p.level != self.current?.level || p.incidents != self.current?.incidents
                self.current = p
                if changed { done() }
            }
        }.resume()
    }
}
