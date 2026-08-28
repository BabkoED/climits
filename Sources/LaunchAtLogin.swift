import Foundation
import ServiceManagement

// Автозапуск.
//
// Штатный путь - SMAppService (macOS 13+). У него есть одна оговорка, важная
// именно для нас: приложение собирается на месте и подписано ad-hoc, а не
// сертификатом разработчика. На части систем регистрация такого бандла
// завершается ошибкой. Поэтому есть запасной путь - обычный LaunchAgent:
// он работает с любым бандлом и снимается так же чисто.
enum LaunchAtLogin {
    private static var agentURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("com.babko.climits.plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { return true }
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        if on {
            if #available(macOS 13.0, *) {
                do {
                    try SMAppService.mainApp.register()
                    return nil
                } catch {
                    // Молча не сдаёмся: пробуем LaunchAgent и сообщаем только
                    // если не вышло и это.
                }
            }
            return writeAgent()
        } else {
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.unregister()
            }
            try? FileManager.default.removeItem(at: agentURL)
            return nil
        }
    }

    private static func writeAgent() -> String? {
        let exe = Bundle.main.executablePath ?? ""
        guard !exe.isEmpty else {
            return L("не нашёл путь к собственному бинарнику",
                     "could not resolve own executable path")
        }
        let plist: [String: Any] = [
            "Label": "com.babko.climits",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        do {
            let dir = agentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: agentURL)
            return nil
        } catch {
            return "\(error.localizedDescription)"
        }
    }
}
