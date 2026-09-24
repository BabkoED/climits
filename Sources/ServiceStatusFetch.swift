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
    static let claude = ServiceStatusFetch(
        api: "https://status.claude.com/api/v2/summary.json",
        page: "https://status.claude.com")

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

    init(api: String, page: String, relevant: ((String) -> Bool)? = nil) {
        self.api = api
        self.page = page
        self.relevant = relevant
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
                if let r = self?.relevant { parsed = parsed?.scoped(r) }
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
