import AppKit
import CryptoKit

// Обновление приложения из релизов GitHub.
//
// ЗАЧЕМ. Приложение раздаётся файлом, и до сих пор обновление означало
// «скачай, распакуй, перетащи». Это ровно тот шаг, который не делают:
// у человека остаётся версия, в которой уже починили то, на что он жалуется.
//
// ЧЕМ ЭТО ОТЛИЧАЕТСЯ ОТ «СКАЧАЛ САМ». Ничем, кроме одного: сумму архива
// здесь проверяет программа, а не человек. Она лежит в тексте релиза, её
// печатает сборка на macOS у GitHub, и сверяется она ДО распаковки. Без этой
// сверки автообновление было бы дырой шире той, что оно закрывает: любой,
// кто сумеет подсунуть ответ на запрос, подсунул бы и приложение.
//
// ЧЕГО ЗДЕСЬ НЕТ. Никакого фонового скачивания и молчаливой подмены: тихая
// проверка только ставит строку в меню. Качает и заменяет - нажатие.
final class Updater {
    static let shared = Updater()
    private init() {}

    private let latestURL = URL(string: "https://api.github.com/repos/BabkoED/climits/releases/latest")!
    private let assetName = "climits.zip"
    private let lastCheckKey = "updateLastCheck"
    private static let quietGap: TimeInterval = 24 * 3600

    private var busy = false

    struct Release {
        let version: String       // «1.2.0», без «v»
        let tag: String
        let zip: URL
        let sha256: String?
        let notes: String
    }

    // --- проверка ------------------------------------------------------------
    //
    // silent: только вернуть версию, если она новее. Иначе - разговор
    // с человеком, включая «у тебя и так последняя».
    func check(silent: Bool, completion: @escaping (String?) -> Void) {
        if busy { return }
        if silent {
            let last = Prefs.d.object(forKey: lastCheckKey) as? Date
            if let l = last, Date().timeIntervalSince(l) < Updater.quietGap { return }
        }
        busy = true

        var req = URLRequest(url: latestURL)
        req.setValue(Prefs.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.busy = false
                Prefs.d.set(Date(), forKey: self.lastCheckKey)

                if let e = error {
                    if !silent { self.say(L("Не удалось проверить", "Could not check"),
                                          e.localizedDescription) }
                    completion(nil)
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    if !silent { self.say(L("Не удалось проверить", "Could not check"),
                                          L("GitHub ответил \(http.statusCode)",
                                            "GitHub answered \(http.statusCode)")) }
                    completion(nil)
                    return
                }
                guard let d = data, let r = self.parse(d) else {
                    if !silent { self.say(L("Не удалось проверить", "Could not check"),
                                          L("ответ GitHub не разобрать", "could not parse GitHub's answer")) }
                    completion(nil)
                    return
                }

                guard Version.isNewer(r.version, than: Prefs.appVersion) else {
                    if !silent {
                        self.say(L("Обновлений нет", "No updates"),
                                 L("Стоит \(Prefs.appVersion), это последняя.",
                                   "You have \(Prefs.appVersion), which is the latest."))
                    }
                    completion(nil)
                    return
                }

                completion(r.version)
                if !silent { self.offer(r) }
            }
        }.resume()
    }

    private func parse(_ data: Data) -> Release? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = root["tag_name"] as? String
        else { return nil }
        let notes = (root["body"] as? String) ?? ""
        var zip: URL?
        for a in (root["assets"] as? [[String: Any]]) ?? [] {
            if (a["name"] as? String) == assetName,
               let s = a["browser_download_url"] as? String, let u = URL(string: s) {
                zip = u
            }
        }
        guard let z = zip else { return nil }
        return Release(version: Version.number(tag), tag: tag, zip: z,
                       sha256: Version.sha256(inNotes: notes), notes: notes)
    }

    // --- разговор ------------------------------------------------------------
    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = L("Вышла версия \(r.version)", "Version \(r.version) is out")
        var info = L("Стоит \(Prefs.appVersion).", "You have \(Prefs.appVersion).")
        let notes = r.notes.split(separator: "\n").prefix(6).joined(separator: "\n")
        if !notes.isEmpty { info += "\n\n" + notes }
        if r.sha256 == nil {
            info += "\n\n" + L("В тексте релиза нет контрольной суммы - проверить скачанное нечем. Обновлю только вручную.",
                               "The release has no checksum - nothing to verify against. Manual update only.")
        }
        a.informativeText = info

        if r.sha256 != nil { a.addButton(withTitle: L("Обновить", "Update")) }
        a.addButton(withTitle: L("Открыть страницу", "Open the page"))
        a.addButton(withTitle: L("Позже", "Later"))

        let choice = a.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        if r.sha256 != nil && choice == first {
            install(r)
        } else if choice == (r.sha256 != nil ? .alertSecondButtonReturn : first) {
            NSWorkspace.shared.open(URL(string: Prefs.repoURL + "/releases/latest")!)
        }
    }

    private func say(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // --- установка -----------------------------------------------------------
    private func install(_ r: Release) {
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            say(L("Некуда положить", "Nowhere to write"),
                L("Нет прав на запись в \(parent.path). Скачай со страницы релиза руками.",
                  "No write access to \(parent.path). Download from the release page instead."))
            NSWorkspace.shared.open(URL(string: Prefs.repoURL + "/releases/latest")!)
            return
        }

        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.download(r, near: bundle)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                switch result {
                case .success(let newApp):
                    self.swap(newApp, over: bundle)
                case .failure(let e):
                    self.say(L("Обновиться не вышло", "Update failed"), e)
                case .none:
                    break
                }
            }
        }
    }

    // Скачивание, сверка суммы, распаковка. Всё в каталоге на ТОМ ЖЕ томе,
    // что и приложение: подмена через replaceItemAt между томами не работает.
    private func download(_ r: Release, near bundle: URL) -> Result<URL, String> {
        let fm = FileManager.default
        let work: URL
        do {
            work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: bundle, create: true)
        } catch {
            return .failure(error.localizedDescription)
        }

        // Синхронно, потому что мы уже на фоновой очереди, и потому что
        // дальше идёт цепочка шагов, каждый из которых зависит от предыдущего.
        // Data(contentsOf:) здесь не годится: он не даёт ни заголовка,
        // ни срока ожидания - висел бы молча.
        var req = URLRequest(url: r.zip)
        req.setValue(Prefs.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 300
        var data: Data?
        var netError: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, response, error in
            if let e = error { netError = e.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                netError = L("сервер ответил \(http.statusCode)", "server answered \(http.statusCode)")
            } else { data = d }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + 300) == .timedOut {
            return .failure(L("не скачалось: слишком долго", "download failed: too slow"))
        }
        guard let body = data, netError == nil else {
            return .failure(L("не скачалось: \(netError ?? "пусто")",
                              "download failed: \(netError ?? "empty")"))
        }

        // Сверка ДО распаковки: распаковывать неизвестно что и потом решать -
        // это уже поздно, ditto к тому времени разложил файлы на диск.
        let got = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        guard let want = r.sha256, got == want else {
            return .failure(L("сумма не сошлась - скачанное выброшено",
                              "checksum mismatch - the download was discarded"))
        }

        let zipPath = work.appendingPathComponent(assetName)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try body.write(to: zipPath)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }

        if let e = shell("/usr/bin/ditto", ["-x", "-k", zipPath.path, unpacked.path]) {
            return .failure(L("не распаковалось: \(e)", "unpacking failed: \(e)"))
        }

        let newApp = unpacked.appendingPathComponent("climits.app")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/climits").path) else {
            return .failure(L("в архиве нет climits.app", "no climits.app in the archive"))
        }

        // Карантин снимаем сами: иначе после подмены система спросит про
        // «скачано из интернета» у приложения, которое уже стоит.
        _ = shell("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // Подпись обязана быть на месте. Она ad-hoc, но без неё система
        // спрашивает доступ к связке ключей заново и чаще, а битый бандл
        // выглядит точно так же, как целый.
        if let e = shell("/usr/bin/codesign", ["--verify", "--quiet", newApp.path]) {
            return .failure(L("подпись не проходит проверку: \(e)",
                              "signature does not verify: \(e)"))
        }

        return .success(newApp)
    }

    private func swap(_ newApp: URL, over bundle: URL) {
        do {
            _ = try FileManager.default.replaceItemAt(bundle, withItemAt: newApp)
        } catch {
            say(L("Заменить не вышло", "Could not replace"), error.localizedDescription)
            return
        }
        // Запускаем новый экземпляр и уходим. -n, потому что старый ещё жив
        // эту секунду, и без него open просто поднял бы его окно.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", bundle.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // Возвращает текст ошибки или nil, если всё прошло.
    private func shell(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "код \(p.terminationStatus)" : msg
    }
}
