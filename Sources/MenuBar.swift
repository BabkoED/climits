import AppKit

// Иконка в строке меню и выпадающее меню.

final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage: Usage?
    private var lastError: String?
    private var settingsWindow: SettingsWindowController?
    // Один запрос в полёте. Без этого совпавшие поводы обновиться - таймер,
    // открытие меню и ⌘R одновременно - дают три параллельных запроса
    // к эндпоинту, который и от одного-то огрызается.
    private var inFlight = false
    // Деньги и локальная оценка считаются по файлам на диске, поэтому живут
    // отдельно от ответа API и обновляются в фоне.
    private var sessionWindow = WindowUsage()
    private var weeklyWindow = WindowUsage()
    private var localEstimate: WindowUsage?
    // Ключ текущего окна берётся из ответа, а не зашивается литералом.
    private var sessionKey = "five_hour"
    private var scanning = false
    private var lastScan: Date?

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude \u{2026}"
        let menu = NSMenu()
        menu.delegate = self
        // Без этого macOS сама гасит пункты без действия: строки лимитов
        // рисовались бы серыми, и цвет по нагрузке пропал бы вместе с ними.
        menu.autoenablesItems = false
        statusItem.menu = menu
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: .climitsPrefsChanged, object: nil)
        refresh(force: false)
        rearmTimer()
    }

    // --- обновление ---------------------------------------------------------
    private var ttl: TimeInterval {
        // Кэш живёт не меньше минуты, даже если пользователь выставил
        // обновление раз в минуту: совпавшие по времени поводы обновиться
        // (таймер, открытие меню, ⌘R) не должны превращаться в три запроса.
        return max(60, TimeInterval(Prefs.refreshInterval))
    }

    func rearmTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(Prefs.refreshInterval),
                                     repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        // Без .common иконка перестаёт обновляться, пока открыто меню или
        // пользователь тащит окно: обычный режим RunLoop на это время встаёт.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh(force: Bool) {
        if inFlight { return }
        inFlight = true
        UsageAPI.shared.fetch(ttl: ttl, force: force) { [weak self] result in
            guard let self = self else { return }
            self.inFlight = false
            switch result {
            case .success(let u):
                self.usage = u
                self.lastError = nil
                self.localEstimate = nil
                Notifier.check(u)
                self.rescanTranscripts(for: u)
            case .failure(let e):
                // Прежние цифры не выбрасываем: если сеть моргнула, честнее
                // оставить их на экране и приписать причину в меню.
                self.lastError = e.errorDescription
                // Ни ответа, ни кэша - остаётся посчитать по расшифровкам.
                // Это оценка расхода, а не остаток лимита, и подписана так же.
                if self.usage == nil { self.rescanLocalOnly() }
            }
            self.updateTitle()
        }
    }

    // Разбор расшифровок - это чтение файлов, иногда сотен мегабайт. В
    // главном потоке это подвесило бы строку меню на секунды.
    //
    // Реже, чем раз в две минуты, не пересчитываем: обход дерева проектов -
    // это десятки мегабайт чтения, а таймер, открытие меню и ⌘R дают поводов
    // куда чаще. Замер на живой машине: 61 МБ и 222 файла за один проход.
    private static let rescanGap: TimeInterval = 120

    private func rescanTranscripts(for u: Usage, force: Bool = false) {
        guard Prefs.showMoney else { return }
        if scanning { return }
        if !force, let last = lastScan, Date().timeIntervalSince(last) < MenuBarController.rescanGap {
            return
        }
        sessionKey = u.session?.key ?? "five_hour"
        let sessionStart = u.session.map { Money.windowStart(for: $0, isSession: true) }
            ?? Date().addingTimeInterval(-5 * 3600)
        let weeklyStart = u.bucket("seven_day").map { Money.windowStart(for: $0, isSession: false) }
            ?? Date().addingTimeInterval(-7 * 86400)

        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let w = Transcripts.usage(cutoffs: [sessionStart, weeklyStart])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                self.lastScan = Date()
                guard w.count == 2 else { return }
                self.sessionWindow = w[0]
                self.weeklyWindow = w[1]
                // Без этого макрос {money} в строке меню пуст при запуске
                // и потом всегда отстаёт на одно обновление: цифры пришли,
                // а перерисовать никто не попросил.
                self.updateTitle()
            }
        }
    }

    private func rescanLocalOnly() {
        if scanning { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let w = Transcripts.usage(since: Date().addingTimeInterval(-5 * 3600))
            DispatchQueue.main.async {
                self?.scanning = false
                self?.localEstimate = w
            }
        }
    }

    // Какое окно расшифровок относится к этому лимиту.
    private func window(for b: Bucket) -> WindowUsage {
        return b.key == sessionKey ? sessionWindow : weeklyWindow
    }

    @objc private func prefsChanged() {
        rearmTimer()
        // Включили «Деньги» - считаем сразу, не дожидаясь таймера. Иначе
        // галочка выглядит так, будто ничего не делает.
        if Prefs.showMoney, let u = usage { rescanTranscripts(for: u, force: true) }
        updateTitle()
    }

    // --- строка в трее ------------------------------------------------------
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        guard let u = usage else {
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? "Claude \u{2026}" : "Claude ?",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let money = (Prefs.showMoney ? u.session.map { Money.view(for: $0, in: sessionWindow) } : nil)
        let text = BarTitle.render(Prefs.effectiveTemplate, usage: u, money: money ?? nil)
        // Строка меню остаётся нейтральной, пока всё спокойно: цветом
        // в строке меню стоит тревожить только по делу.
        let color = u.worst.map { Palette.titleColor(for: $0) } ?? NSColor.labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: Palette.barFont,
        ])
    }

    // --- меню ---------------------------------------------------------------
    // Открытие меню - хороший повод освежить данные: человек смотрит именно
    // сейчас. Порог между запросами внутри fetch всё равно не даст частить.
    func menuWillOpen(_ menu: NSMenu) {
        refresh(force: false)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let u = usage {
            if u.isStale || lastError != nil {
                menu.addItem(dim(staleNote(u)))
                if let next = UsageAPI.shared.nextAttemptAt {
                    menu.addItem(dim(L("пробую снова в \(Fmt.hhmm(next))",
                                       "next attempt at \(Fmt.hhmm(next))")))
                }
                menu.addItem(.separator())
            }
            for b in u.buckets {
                menu.addItem(row(for: b, active: u.active?.key == b.key))
            }
            menu.addItem(.separator())
            menu.addItem(extraRow(u.extra))
            if Prefs.showMoney {
                menu.addItem(dim(L("Деньги - оценка по расшифровкам этой машины, а не счёт",
                                   "Money is an estimate from this machine's transcripts, not a bill")))
                // Флаги, которые до этого собирались и никуда не попадали.
                // Собирать и не показывать - хуже, чем не собирать: в коде
                // выглядит как учтённое, а человек об этом не узнаёт.
                let unknown = sessionWindow.unknownModels.union(weeklyWindow.unknownModels)
                if !unknown.isEmpty {
                    let list = unknown.sorted().joined(separator: ", ")
                    menu.addItem(dim(L("нет цены для \(list) - считаю по Sonnet",
                                       "no price for \(list) - counted as Sonnet")))
                }
                if sessionWindow.truncated || weeklyWindow.truncated {
                    menu.addItem(dim(L("история не прочитана целиком - итог занижен",
                                       "history not read in full - the total is understated")))
                }
            }
        } else if let err = lastError {
            let i = NSMenuItem(title: err, action: nil, keyEquivalent: "")
            i.isEnabled = true
            i.attributedTitle = NSAttributedString(string: err,
                attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(i)
            if let next = UsageAPI.shared.nextAttemptAt {
                menu.addItem(dim(L("пробую снова в \(Fmt.hhmm(next))",
                                   "next attempt at \(Fmt.hhmm(next))")))
            }
            // Ни ответа, ни сохранённых цифр. Показать хоть что-то полезнее,
            // чем показать ничего, - но это расход, а не остаток лимита,
            // и подписано именно так.
            if let est = localEstimate, !est.isEmpty {
                menu.addItem(.separator())
                menu.addItem(dim(L("Оценка по расшифровкам, за последние 5 часов",
                                   "Estimate from transcripts, last 5 hours")))
                let tt = est.totals
                menu.addItem(plain(L("запросов: \(tt.requests)", "requests: \(tt.requests)")))
                menu.addItem(plain(L("токенов: \(Fmt.compact(tt.total))",
                                     "tokens: \(Fmt.compact(tt.total))")))
                if Prefs.showMoney {
                    menu.addItem(plain(L("по прайсу API: \u{2248}\(MoneyView.money(est.cost))",
                                         "at API prices: \u{2248}\(MoneyView.money(est.cost))")))
                }
                menu.addItem(dim(L("только эта машина, лимита это не заменяет",
                                   "this machine only - not a substitute for the limit")))
            }
        } else {
            menu.addItem(dim(L("загружаю\u{2026}", "loading\u{2026}")))
        }

        menu.addItem(.separator())
        menu.addItem(action(L("Обновить", "Refresh"), #selector(doRefresh), key: "r"))
        menu.addItem(action(L("Настройки\u{2026}", "Settings\u{2026}"), #selector(openSettings), key: ","))
        menu.addItem(action(L("Открыть claude.ai/usage", "Open claude.ai/usage"), #selector(openWeb), key: ""))
        menu.addItem(.separator())
        menu.addItem(action(L("Выйти", "Quit"), #selector(quit), key: "q"))
    }

    private func staleNote(_ u: Usage) -> String {
        let at = Fmt.hhmm(u.fetchedAt)
        if UsageAPI.shared.inCooldown {
            return L("данные от \(at) \u{00B7} API попросил не частить",
                     "data from \(at) \u{00B7} API asked to slow down")
        }
        if let e = lastError {
            return L("данные от \(at) \u{00B7} \(e)", "data from \(at) \u{00B7} \(e)")
        }
        return L("данные от \(at) \u{00B7} обновиться не удалось",
                 "data from \(at) \u{00B7} refresh failed")
    }

    // Одна строка лимита рисуется двумя: подпись и процент сверху, шкала
    // и время сброса снизу.
    //
    // Табуляция с правым выравниванием, а не добивка пробелами: пробелы
    // держат колонку только в моноширинном шрифте, а подписи набраны
    // обычным - на нём «Неделя, Sonnet» и «5-часовое окно» разъезжаются.
    private func row(for b: Bucket, active: Bool) -> NSMenuItem {
        let accent = Palette.color(for: b)
        let item = NSMenuItem()
        item.isEnabled = true

        if !Prefs.twoLineRows {
            let line = (active ? "\u{25B8} " : "  ")
                + Fmt.pad(b.long, 20)
                + Fmt.padLeft("\(b.pct)", 3) + "%  "
                + Fmt.bar(b.pct) + "  "
                + Fmt.resetPhrase(b.resetsAt)
            item.attributedTitle = NSAttributedString(string: line, attributes: [
                .font: Palette.menuFont, .foregroundColor: accent,
            ])
            return item
        }

        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
        para.lineSpacing = 2

        let label = (active ? "\u{25B8} " : "   ") + b.long
        let title = NSMutableAttributedString(
            string: "\(label)\t\(b.pct)%\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize) + 1),
                .paragraphStyle: para,
            ])

        title.append(NSAttributedString(string: "   " + Fmt.bar(b.pct), attributes: [
            .font: Palette.menuFont,
            .foregroundColor: accent,
        ]))

        var tail = "  " + Fmt.resetPhrase(b.resetsAt)
        let clock = Fmt.clock(b.resetsAt)
        if !clock.isEmpty { tail += " \u{00B7} " + clock }

        // Деньги: сколько этот трафик стоил бы по прайсу API и во сколько
        // обходится весь лимит целиком. И то, и другое - оценка, о чём
        // говорит знак «≈» и отдельная строка в самом низу меню.
        if Prefs.showMoney {
            let mv = Money.view(for: b, in: window(for: b))
            if mv.spent > 0 {
                tail += "  \u{00B7} \u{2248}" + mv.spentText
                if let full = mv.fullText {
                    tail += L(" из \u{2248}", " of \u{2248}") + full
                }
            }
        }

        title.append(NSAttributedString(string: tail, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize) - 1),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        item.attributedTitle = title
        return item
    }

    private func extraRow(_ e: Extra) -> NSMenuItem {
        let text: String
        var color = NSColor.labelColor
        if !e.enabled {
            text = "  " + L("Сверх лимита: выключено", "Extra usage: off")
            color = NSColor.secondaryLabelColor
        } else if let limit = e.limitMinor, limit > 0 {
            let p = e.percent ?? 0
            text = "  " + L("Сверх лимита: ", "Extra usage: ")
                 + e.usedText + L(" из ", " of ") + e.money(limit) + "  (\(p)%)"
            color = Palette.color(forPercent: p, severity: "normal")
        } else {
            // Лимит не задан - не выдумываем «из —», а честно поясняем.
            text = "  " + L("Сверх лимита: ", "Extra usage: ") + e.usedText
                 + L(" за месяц, персональный лимит не задан",
                     " this month, no personal cap set")
        }
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = true
        i.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Palette.menuFont,
            .foregroundColor: color,
        ])
        return i
    }

    private func plain(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.isEnabled = true
        i.attributedTitle = NSAttributedString(string: "   " + s, attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize)),
        ])
        return i
    }

    private func dim(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.isEnabled = true
        i.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.isEnabled = true
        return i
    }

    @objc private func doRefresh() { refresh(force: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openWeb() {
        if let u = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(u) }
    }
    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let climitsPrefsChanged = Notification.Name("climitsPrefsChanged")
}
