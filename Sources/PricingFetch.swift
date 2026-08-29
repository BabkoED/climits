import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Скачивание прайса. Только сеть и файл - весь разбор в PricingFeed.
//
// Раз в сутки, а не при каждом обновлении трея: цены меняются объявлениями,
// а трей перерисовывается каждые пять минут. Промах на сутки здесь стоит
// копейки в подписи, а лишний запрос раз в пять минут - это чужой сервер
// и наш же 429.
enum PricingFetch {
    static let interval: TimeInterval = 24 * 3600
    // Тот же порядок величины, что и весь файл LiteLLM. Больше - значит
    // по адресу лежит уже не прайс, и разбирать это в памяти незачем.
    private static let maxBytes = 32 * 1024 * 1024

    private static var inFlight = false

    static func isStale() -> Bool {
        guard let stamp = Pricing.remoteStamp else { return true }
        return Date().timeIntervalSince(stamp) > interval
    }

    // Молчаливая по замыслу: не вышло - остаёмся на прежнем прайсе, а то,
    // что он прежний, видно по дате в меню. Ронять на человека уведомление
    // «не скачался прайс» значит требовать действия там, где действия нет.
    static func refreshIfStale(_ done: (() -> Void)? = nil) {
        _ = Pricing.table()          // подтягивает remoteStamp с диска
        guard isStale(), !inFlight else { return }
        guard let url = URL(string: PricingFeed.sourceURL) else { return }
        inFlight = true

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(Prefs.userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { inFlight = false }
            guard let data = data, data.count <= maxBytes,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let table = PricingFeed.parse(data)
            // Пустой разбор - это не «цен нет», это «формат уехал».
            // Записать пустоту значило бы стереть рабочий кэш и остаться
            // со встроенной таблицей, ничего об этом не сказав.
            guard !table.isEmpty else { return }
            guard let out = PricingFeed.encode(table, at: Date().timeIntervalSince1970) else { return }
            try? FileManager.default.createDirectory(at: Pricing.supportDir,
                                                     withIntermediateDirectories: true)
            try? out.write(to: Pricing.remoteURL, options: .atomic)
            Pricing.reload()
            DispatchQueue.main.async { done?() }
        }.resume()
    }
}
