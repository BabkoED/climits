import Foundation

// Терминальный режим. Тот же бинарник, что и приложение: у приложения в трее
// нет ни истории, ни диагностики, а когда что-то не работает, нужен именно
// текст в терминале, а не значок с восклицательным знаком.
//
//   climits --short    одна строка (для statusline)
//   climits --full     подробный отчёт
//   climits --json     сырой ответ API
//   climits --doctor   диагностика: связка ключей, токен, срок, запрос
enum CLI {
    static let version = "1.0.0"

    static var isTTY: Bool { return isatty(1) == 1 }

    private static func c(_ code: String) -> String { return isTTY ? "\u{1B}[\(code)m" : "" }
    static var reset: String { c("0") }
    static var dim: String { c("2") }
    static var bold: String { c("1") }
    static var green: String { c("32") }
    static var yellow: String { c("33") }
    static var red: String { c("31") }

    static func colorFor(_ pct: Int) -> String {
        if pct >= Prefs.alertAt { return red }
        if pct >= Prefs.warnAt { return yellow }
        return green
    }

    // Возвращает код выхода.
    static func run(_ args: [String]) -> Int32 {
        let arg = args.first ?? ""
        switch arg {
        case "--version", "-v":
            print("climits \(version)")
            return 0
        case "--help", "-h":
            help()
            return 0
        case "--doctor":
            return doctor()
        case "--install-cli":
            return installCLI()
        default:
            break
        }

        let ttl: TimeInterval = max(60, TimeInterval(Prefs.refreshInterval))
        switch UsageAPI.shared.fetchSync(ttl: ttl, force: false) {
        case .failure(let e):
            FileHandle.standardError.write(
                ("climits: " + (e.errorDescription ?? "?") + "\n").data(using: .utf8)!)
            return 1
        case .success(let u):
            switch arg {
            case "--json": printJSON(u)
            case "--short": printShort(u)
            default: printFull(u)
            }
            return 0
        }
    }

    private static func printJSON(_ u: Usage) {
        // Печатаем то, что пришло, но с отступами: сырой ответ нужен именно
        // для чтения глазами, когда что-то разошлось с /usage.
        if let d = u.rawBody.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: pretty, encoding: .utf8) {
            print(s)
        } else {
            print(u.rawBody)
        }
    }

    private static func printShort(_ u: Usage) {
        var parts = u.buckets.map { "\($0.short) \($0.pct)%" }
        if u.extra.enabled, u.extra.usedMinor != nil {
            parts.append(L("сверх ", "extra ") + u.extra.usedText)
        }
        var line = parts.joined(separator: " \u{00B7} ")
        if u.isStale { line += " ~" }
        print(line)
    }

    private static func printFull(_ u: Usage) {
        print("")
        for b in u.buckets {
            let col = colorFor(b.pct)
            let clock = Fmt.clock(b.resetsAt)
            let tail = clock.isEmpty ? "" : " \u{00B7} " + clock
            print("  \(bold)\(Fmt.pad(b.long, 20))\(reset)"
                + " \(col)\(Fmt.padLeft("\(b.pct)", 3))%\(reset)"
                + "  \(col)\(Fmt.bar(b.pct))\(reset)"
                + "  \(dim)\(Fmt.resetPhrase(b.resetsAt))\(tail)\(reset)")
        }
        let e = u.extra
        print("")
        let label = bold + Fmt.pad(L("Сверх лимита", "Extra usage"), 20) + reset
        if !e.enabled {
            print("  \(label) \(dim)\(L("выключено", "off"))\(reset)")
        } else if let limit = e.limitMinor, limit > 0 {
            let p = e.percent ?? 0
            print("  \(label) \(colorFor(p))\(e.usedText)\(L(" из ", " of "))\(e.money(limit))\(reset)  \(dim)(\(p)%)\(reset)")
        } else {
            print("  \(label) \(yellow)\(e.usedText)\(reset)  \(dim)"
                + L("за месяц, персональный лимит не задан", "this month, no personal cap set")
                + "\(reset)")
        }
        print("")
        if u.isStale {
            print("  \(yellow)" + L("данные от ", "data from ") + Fmt.hhmm(u.fetchedAt)
                + L(" \u{00B7} обновиться не удалось", " \u{00B7} refresh failed") + "\(reset)")
        } else {
            print("  \(dim)" + L("обновлено ", "updated ") + Fmt.hhmm(u.fetchedAt) + "\(reset)")
        }
        print("")
    }

    // Диагностика. Сам токен не печатается никогда - только его длина и то,
    // удалось ли его разобрать.
    private static func doctor() -> Int32 {
        print("climits \(version)\n")

        let raw = Keychain.rawEntry()
        if let r = raw {
            print(Fmt.pad(L("Связка ключей", "Keychain"), 18)
                + L("запись найдена, \(r.count) байт", "entry found, \(r.count) bytes"))
        } else {
            print(Fmt.pad(L("Связка ключей", "Keychain"), 18)
                + L("ЗАПИСЬ НЕ НАЙДЕНА - залогинься: claude", "NOT FOUND - log in: claude"))
            return 1
        }

        let dups = Keychain.duplicateAccounts()
        print(Fmt.pad(L("Дубликаты", "Duplicates"), 18)
            + L("\(dups.count) записей с этим именем", "\(dups.count) entries with this service"))

        do {
            let t = try Keychain.token()
            print(Fmt.pad(L("Токен", "Token"), 18)
                + L("разобран, длина \(t.value.count)", "parsed, length \(t.value.count)"))
            if let exp = t.expiresAt {
                let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
                print(Fmt.pad(L("Срок действия", "Expires"), 18) + f.string(from: exp))
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            print(Fmt.pad(L("Токен", "Token"), 18) + red + msg + reset)
            if let r = raw {
                print(Fmt.pad(L("Структура", "Structure"), 18) + Keychain.redact(r))
            }
            return 1
        }

        let api = UsageAPI.shared
        print(Fmt.pad(L("Кэш", "Cache"), 18) + api.cacheFile.path)
        if let age = api.cacheAge {
            print(Fmt.pad(L("Возраст данных", "Data age"), 18)
                + L("\(Int(age)) сек", "\(Int(age)) sec"))
        } else {
            print(Fmt.pad(L("Возраст данных", "Data age"), 18) + L("кэша нет", "no cache"))
        }
        if api.inCooldown {
            print(Fmt.pad(L("Пауза", "Cooldown"), 18)
                + L("активна - API просил не частить", "active - API asked to slow down"))
        }

        print("\n" + L("Пробую запрос к API\u{2026}", "Trying an API request\u{2026}"))
        switch api.fetchSync(ttl: 0, force: true) {
        case .success(let u):
            print(Fmt.pad("API", 18) + green + "OK" + reset
                + L(", получено \(u.rawBody.count) байт", ", \(u.rawBody.count) bytes"))
            // Какие лимиты вообще есть в ответе - это отвечает на вопрос
            // «почему такой-то модели не видно».
            let names = u.buckets.map { $0.key }.joined(separator: "  ")
            print(Fmt.pad(L("Лимиты в ответе", "Limits in response"), 18) + names)
            let shape = u.rawBody.contains("\"limits\"")
                ? L("массив limits", "limits array")
                : L("объекты верхнего уровня", "top-level objects")
            print(Fmt.pad(L("Форма ответа", "Response shape"), 18) + shape)
        case .failure(let e):
            print(Fmt.pad("API", 18) + red + (e.errorDescription ?? "?") + reset)
            return 1
        }
        return 0
    }

    // Ссылка на бинарник внутри бандла - чтобы `climits --short` работал
    // в statusline и в любых скриптах, а обновление приложения не требовало
    // переустановки команды.
    private static func installCLI() -> Int32 {
        guard let exe = Bundle.main.executablePath else {
            print(L("не нашёл собственный путь", "could not resolve own path"))
            return 1
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binDir = home.appendingPathComponent("bin", isDirectory: true)
        let link = binDir.appendingPathComponent("climits")
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: exe))
        } catch {
            print("\(error.localizedDescription)")
            return 1
        }
        print(L("команда установлена: ", "command installed: ") + link.path)
        print(L("если ~/bin нет в PATH, добавь в ~/.zshrc:", "if ~/bin is not in PATH, add to ~/.zshrc:"))
        print("  export PATH=\"$HOME/bin:$PATH\"")
        return 0
    }

    private static func help() {
        // Строки собираются заранее и по одной. Интерполяция, растянутая на
        // две строки внутри многострочного литерала, разбирается компилятором
        // не во всех версиях Swift - а собирать это будут на чужих машинах.
        let macros = BarTitle.macros.map { "  " + Fmt.pad($0.0, 14) + $0.1 }.joined(separator: "\n")
        let tagline = L("лимиты Claude в строке меню", "Claude limits in the menu bar")
        let intro = L("Без аргументов: из терминала печатает отчёт, из Finder открывает иконку в строке меню.",
                      "With no arguments: prints a report in a terminal, opens the menu bar icon from Finder.")
        let hShort = L("одна строка, для statusline", "one line, for a statusline")
        let hFull = L("подробный отчёт (по умолчанию в терминале)", "detailed report (terminal default)")
        let hJson = L("сырой ответ API", "raw API response")
        let hDoc = L("диагностика: связка ключей, токен, запрос", "diagnostics: keychain, token, request")
        let hCli = L("положить ссылку в ~/bin/climits", "symlink into ~/bin/climits")
        let hVer = L("версия", "version")
        let macroTitle = L("Макросы строки меню (Настройки -> Свой формат):",
                           "Menu bar macros (Settings -> Custom format):")
        let src = L("Данные берутся из того же эндпоинта, что и /usage внутри Claude Code:",
                    "Data comes from the same endpoint Claude Code uses for /usage:")
        let privacy = L("Токен читается из связки ключей, никуда не отправляется и не сохраняется.",
                        "The token is read from the keychain, never stored or sent anywhere else.")

        print("""
climits \(version) \u{2014} \(tagline)

\(intro)

  --short        \(hShort)
  --full         \(hFull)
  --json         \(hJson)
  --doctor       \(hDoc)
  --install-cli  \(hCli)
  --version      \(hVer)

\(macroTitle)
\(macros)

\(src)
  GET https://api.anthropic.com/api/oauth/usage
\(privacy)
""")
    }
}
