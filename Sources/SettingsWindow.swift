import AppKit

// Окно настроек. Свёрстано кодом, без xib и storyboard: приложение собирается
// одним вызовом swiftc, и любой ресурсный файл здесь стал бы лишним поводом
// для сборки развалиться на чужой машине.
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {

    private var checkboxes: [String: NSButton] = [:]
    private var templateField: NSTextField!
    private var customToggle: NSButton!
    private var previewLabel: NSTextField!
    private var intervalPopup: NSPopUpButton!
    private var loginToggle: NSButton!
    private var uaField: NSTextField!

    private let intervals: [(String, Int)] = [
        (L("каждую минуту", "every minute"), 60),
        (L("раз в 5 минут", "every 5 minutes"), 300),
        (L("раз в 15 минут", "every 15 minutes"), 900),
        (L("раз в 30 минут", "every 30 minutes"), 1800),
    ]

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("Настройки climits", "climits settings")
        w.center()
        self.init(window: w)
        build()
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])

        stack.addArrangedSubview(header(L("Что показывать в строке меню",
                                          "What to show in the menu bar")))

        addCheck(stack, "showIcon", L("Кружок загрузки", "Load dot"), Prefs.showIcon)
        addCheck(stack, "showSession", L("Процент текущего окна", "Current window percent"), Prefs.showSession)
        addCheck(stack, "showLeft", L("Сколько до сброса", "Time until reset"), Prefs.showLeft)
        addCheck(stack, "showWeekly", L("Недельный кап", "Weekly cap"), Prefs.showWeekly)
        addCheck(stack, "showModels", L("Лимиты по моделям (Opus, Sonnet, Fable)",
                                        "Per-model limits (Opus, Sonnet, Fable)"), Prefs.showModels)
        addCheck(stack, "showExtra", L("Потрачено сверх лимита", "Extra usage spent"), Prefs.showExtra)

        stack.addArrangedSubview(spacer(6))
        customToggle = NSButton(checkboxWithTitle: L("Свой формат вместо галочек",
                                                     "Custom format instead of checkboxes"),
                                target: self, action: #selector(toggleCustom))
        customToggle.state = Prefs.useCustomTemplate ? .on : .off
        stack.addArrangedSubview(customToggle)

        templateField = NSTextField()
        templateField.stringValue = Prefs.customTemplate
        templateField.delegate = self
        templateField.isEnabled = Prefs.useCustomTemplate
        templateField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        templateField.translatesAutoresizingMaskIntoConstraints = false
        templateField.widthAnchor.constraint(equalToConstant: 470).isActive = true
        stack.addArrangedSubview(templateField)

        let hint = BarTitle.macros.map { $0.0 }.joined(separator: "  ")
        stack.addArrangedSubview(small(hint))
        stack.addArrangedSubview(small(L("Пустые макросы убираются вместе с разделителем.",
                                         "Empty macros are dropped along with their separator.")))

        stack.addArrangedSubview(spacer(6))
        previewLabel = NSTextField(labelWithString: "")
        previewLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(header(L("Как это будет выглядеть", "Preview")))
        stack.addArrangedSubview(previewLabel)

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(header(L("Поведение", "Behaviour")))

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(NSTextField(labelWithString: L("Обновлять:", "Refresh:")))
        intervalPopup = NSPopUpButton()
        intervalPopup.addItems(withTitles: intervals.map { $0.0 })
        if let idx = intervals.firstIndex(where: { $0.1 == Prefs.refreshInterval }) {
            intervalPopup.selectItem(at: idx)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(changeInterval)
        row.addArrangedSubview(intervalPopup)
        stack.addArrangedSubview(row)

        stack.addArrangedSubview(small(L("Чаще раза в минуту эндпоинт отвечает 429 - это его защита, не наша.",
                                         "More often than once a minute the endpoint answers 429 - its protection, not ours.")))

        loginToggle = NSButton(checkboxWithTitle: L("Запускать при входе в систему",
                                                    "Launch at login"),
                               target: self, action: #selector(toggleLogin))
        loginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
        stack.addArrangedSubview(loginToggle)

        stack.addArrangedSubview(spacer(6))
        stack.addArrangedSubview(NSTextField(labelWithString: "User-Agent"))
        uaField = NSTextField()
        uaField.stringValue = Prefs.userAgent
        uaField.delegate = self
        uaField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        uaField.translatesAutoresizingMaskIntoConstraints = false
        uaField.widthAnchor.constraint(equalToConstant: 470).isActive = true
        stack.addArrangedSubview(uaField)
        stack.addArrangedSubview(small(L("Трогать стоит, только если эндпоинт постоянно отвечает 429. Пусто - значение по умолчанию.",
                                         "Only worth touching if the endpoint keeps answering 429. Empty means the default.")))

        updatePreview()
    }

    // --- элементы -----------------------------------------------------------
    private func header(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 13)
        return t
    }
    private func small(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: 10)
        t.textColor = .secondaryLabelColor
        return t
    }
    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    private func addCheck(_ stack: NSStackView, _ key: String, _ title: String, _ on: Bool) {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleCheck(_:)))
        b.state = on ? .on : .off
        b.identifier = NSUserInterfaceItemIdentifier(key)
        checkboxes[key] = b
        stack.addArrangedSubview(b)
    }

    // --- реакции ------------------------------------------------------------
    @objc private func toggleCheck(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.identifier?.rawValue ?? "" {
        case "showIcon": Prefs.showIcon = on
        case "showSession": Prefs.showSession = on
        case "showLeft": Prefs.showLeft = on
        case "showWeekly": Prefs.showWeekly = on
        case "showModels": Prefs.showModels = on
        case "showExtra": Prefs.showExtra = on
        default: break
        }
        // Правка галочек означает, что человек хочет быстрый выбор, а не
        // шаблон: молча оставить включённым «свой формат» - значит показать
        // ему, что галочки ни на что не влияют.
        if Prefs.useCustomTemplate {
            Prefs.useCustomTemplate = false
            customToggle.state = .off
            templateField.isEnabled = false
        }
        applied()
    }

    @objc private func toggleCustom() {
        let on = customToggle.state == .on
        Prefs.useCustomTemplate = on
        templateField.isEnabled = on
        // При первом включении подставляем то, что собрано галочками: человек
        // видит рабочий образец и правит его, а не пустое поле.
        if on && templateField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            templateField.stringValue = Prefs.defaultTemplateFromCheckboxes()
            Prefs.customTemplate = templateField.stringValue
        }
        applied()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Одно окно, два поля: разбираемся, кто именно изменился.
        if let f = obj.object as? NSTextField, f === uaField {
            Prefs.userAgent = f.stringValue
            return
        }
        Prefs.customTemplate = templateField.stringValue
        applied()
    }

    @objc private func changeInterval() {
        let idx = intervalPopup.indexOfSelectedItem
        if idx >= 0 && idx < intervals.count {
            Prefs.refreshInterval = intervals[idx].1
        }
        applied()
    }

    @objc private func toggleLogin() {
        let on = loginToggle.state == .on
        if let err = LaunchAtLogin.set(on) {
            loginToggle.state = LaunchAtLogin.isEnabled ? .on : .off
            let a = NSAlert()
            a.messageText = L("Не удалось настроить автозапуск", "Could not set up launch at login")
            a.informativeText = err + "\n\n" + L(
                "Обходной путь: Системные настройки → Основные → Объекты входа → добавить climits.",
                "Workaround: System Settings → General → Login Items → add climits.")
            a.runModal()
        }
    }

    private func applied() {
        updatePreview()
        NotificationCenter.default.post(name: .climitsPrefsChanged, object: nil)
    }

    // Предпросмотр на выдуманных, но правдоподобных цифрах: настраивать вид
    // строки, глядя на живые 3%, неудобно - половина макросов выглядит пусто.
    private func updatePreview() {
        previewLabel.stringValue = BarTitle.render(Prefs.effectiveTemplate, usage: SettingsWindowController.sample)
    }

    static let sample: Usage = {
        let now = Date()
        let buckets = [
            Bucket(key: "five_hour", short: L("5ч", "5h"), long: L("5-часовое окно", "5-hour window"),
                   percent: 37, resetsAt: now.addingTimeInterval(2 * 3600 + 840), isActive: true, rank: 0),
            Bucket(key: "seven_day", short: L("7д", "7d"), long: L("Неделя, всего", "Week, total"),
                   percent: 62, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 1),
            Bucket(key: "seven_day_opus", short: "Opus", long: L("Неделя, Opus", "Week, Opus"),
                   percent: 81, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 2),
            Bucket(key: "seven_day_sonnet", short: "Sonnet", long: L("Неделя, Sonnet", "Week, Sonnet"),
                   percent: 12, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 2),
            Bucket(key: UsageParser.fableKey, short: "Fable", long: L("Неделя, Fable", "Week, Fable"),
                   percent: 0, resetsAt: nil, isActive: false, rank: 2),
        ]
        let extra = Extra(enabled: true, usedMinor: 13963, limitMinor: 20000,
                          exponent: 2, currency: "USD", percentGiven: nil)
        return Usage(buckets: buckets, extra: extra, fetchedAt: now, isStale: false, rawBody: "{}")
    }()
}
