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
    // Посуточный расход за неделю и границы этих суток - для столбиков.
    private var dailyWindows: [WindowUsage] = []
    private var dayCutoffs: [Date] = []
    // Расход за последний час - для темпа.
    private var lastHour = WindowUsage()
    // Ключ текущего окна берётся из ответа, а не зашивается литералом.
    private var sessionKey = "five_hour"
    private var scanning = false
    private var lastScan: Date?
    // Вторая машина: сколько машин попало в счёт и чем кончилась попытка.
    // Молча считать одну, когда настроены две, нельзя - цифра занижается
    // в разы, а выглядит так же убедительно.
    private var machines = 1
    private var remoteError: String?
    // Новая версия, если фоновая проверка её нашла.
    private var pendingUpdate: String?

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
        checkUpdatesQuietly()
        // Прайс тянем при запуске, а не по таймеру: сутки живут дольше
        // любого сеанса, и второй раз за день это всё равно не сработает.
        // Перерисовка нужна - цены поменяли деньги в уже показанной строке.
        PricingFetch.refreshIfStale { [weak self] in self?.updateTitle() }
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
                // Замер процентов кладём ВСЕГДА, даже когда история выключена:
                // включить её и увидеть пустоту - значит ждать ещё час, пока
                // накопится наклон. Файл от этого прирастает парой сотен байт
                // в час, и это дешевле, чем час без ответа.
                History.record(u.buckets.map {
                    PctSample(at: u.fetchedAt, key: $0.key, pct: $0.pct)
                })
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
        guard Prefs.showMoney || Prefs.showTokens || Prefs.showHistory else { return }
        if scanning { return }
        if !force, let last = lastScan, Date().timeIntervalSince(last) < MenuBarController.rescanGap {
            return
        }
        sessionKey = u.session?.key ?? "five_hour"
        let sessionStart = u.session.map { Money.windowStart(for: $0, isSession: true) }
            ?? Date().addingTimeInterval(-5 * 3600)
        let weeklyStart = u.bucket("seven_day").map { Money.windowStart(for: $0, isSession: false) }
            ?? Date().addingTimeInterval(-7 * 86400)

        // Суточные границы и последний час идут тем же проходом по файлам:
        // передать восемь границ вместо двух стоит столько же, сколько две,
        // а второй обход - это те же десятки мегабайт чтения заново.
        let days = Prefs.showHistory ? Trend.dayCutoffs(days: 7) : []
        let burnStart = Date().addingTimeInterval(-3600)
        var cutoffs = [sessionStart, weeklyStart]
        cutoffs += days
        if Prefs.showHistory { cutoffs.append(burnStart) }

        scanning = true
        let host = Prefs.remoteHost
        let remotePath = Prefs.remotePath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var w = Transcripts.usage(cutoffs: cutoffs)
            var err: String? = nil
            var machines = 1

            // Вторая машина считается тем же способом на своей стороне и
            // складывается сюда. Ошибку не глотаем: без неё «считаю обе»
            // и «одна не ответила» выглядят на экране одинаково.
            if !host.isEmpty {
                switch RemoteScan.usage(host: host, path: remotePath,
                                        cutoffs: cutoffs) {
                case .success(let r) where r.count == w.count:
                    for i in w.indices { w[i] = w[i] + r[i] }
                    machines = 2
                case .success:
                    err = L("ответ не по форме", "malformed answer")
                case .failure(let e):
                    err = e.text
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                self.lastScan = Date()
                self.machines = machines
                self.remoteError = err
                guard w.count == cutoffs.count, w.count >= 2 else { return }
                self.sessionWindow = w[0]
                self.weeklyWindow = w[1]
                if !days.isEmpty, w.count == 2 + days.count + 1 {
                    self.dayCutoffs = days
                    self.dailyWindows = Trend.split(Array(w[2..<(2 + days.count)]))
                    self.lastHour = w[w.count - 1]
                }
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
        if Prefs.showMoney || Prefs.showTokens, let u = usage {
            rescanTranscripts(for: u, force: true)
        }
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
        let tokens = (Prefs.showTokens ? u.session.map { Money.tokens(for: $0, in: sessionWindow) } : nil)
        let text = BarTitle.render(Prefs.effectiveTemplate, usage: u,
                                   money: money ?? nil, tokens: tokens ?? nil)
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
            if Prefs.showMoney || Prefs.showTokens {
                menu.addItem(dim(estimateNote()))
                if let e = remoteError {
                    menu.addItem(dim(L("\(Prefs.remoteHost) не ответил: \(e)",
                                       "\(Prefs.remoteHost) did not answer: \(e)")))
                }
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
            if Prefs.showHistory {
                menu.addItem(.separator())
                for line in historyRows(u) { menu.addItem(plain(line)) }
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
        if let v = pendingUpdate {
            menu.addItem(dim(L("вышла версия \(v)", "version \(v) is out")))
        }
        menu.addItem(action(L("Проверить обновления\u{2026}", "Check for updates\u{2026}"),
                            #selector(checkUpdates), key: ""))
        menu.addItem(.separator())
        menu.addItem(action(L("Выйти", "Quit"), #selector(quit), key: "q"))
    }

    // Чем именно посчитаны деньги и токены. Разница между «этой машиной» и
    // «двумя» - это разы, а не проценты, и человек должен видеть, что перед
    // ним.
    private func estimateNote() -> String {
        let what = Prefs.showMoney && Prefs.showTokens
            ? L("Деньги и токены", "Money and tokens")
            : (Prefs.showMoney ? L("Деньги", "Money") : L("Токены", "Tokens"))
        // Дата прайса стоит здесь, а не отдельной строкой: она отвечает на
        // тот же вопрос «насколько этому числу верить», что и перечень
        // машин. Две оговорки об одном числе в разных углах меню читаются
        // как две разные проблемы.
        let price = " \u{00B7} " + Pricing.originText()
        // Сколько каталогов читаем на этой машине сверх домашнего. Молчать
        // об этом нельзя в обе стороны: и когда читаем только один из двух,
        // и когда человек настроил второй и хочет убедиться, что он в счёте.
        let extra = max(0, Transcripts.localRoots().count - 1)
        let roots = extra > 0
            ? L(" и ещё \(extra) катал.", " plus \(extra) more folder(s)")
            : ""
        if machines > 1 {
            return L("\(what) - по расшифровкам двух машин: этой\(roots) и \(Prefs.remoteHost)\(price)",
                     "\(what) - from two machines: this one\(roots) and \(Prefs.remoteHost)\(price)")
        }
        return L("\(what) - по расшифровкам ТОЛЬКО этой машины\(roots)\(price)",
                 "\(what) - from THIS machine only\(roots)\(price)")
    }

    // Три строки про историю и темп. Пустые не показываем: строка «темп: -»
    // занимает место и не отвечает ни на что.
    //
    // Отвечают они на разные вопросы, и в этом смысл всей тройки:
    // столбики - «это много или как обычно», темп - «с какой скоростью
    // трачу», прогноз - «упрусь ли раньше, чем сбросится».
    private func historyRows(_ u: Usage) -> [String] {
        var out: [String] = []

        if !dailyWindows.isEmpty {
            let totals = dailyWindows.map { $0.totals.total }
            var line = "  " + L("7 дней ", "7 days ") + Fmt.spark(totals)
            if let today = dailyWindows.last, !today.isEmpty {
                line += "  \u{00B7} " + L("сегодня ", "today ") + Fmt.compact(today.totals.total)
                if Prefs.showMoney { line += " \u{2248}" + MoneyView.money(today.cost) }
            }
            out.append(line)
        }

        // Темп по расшифровкам: сколько токенов в час прошло за последний час.
        let burnTokens = lastHour.totals.total
        if let perHour = Trend.perHour(tokens: burnTokens, over: 3600) {
            var line = "  " + L("темп ", "burn ") + Fmt.compact(perHour) + L("/ч", "/h")
            // Во что обойдётся окно к сбросу при этом темпе. Это НЕ прогноз
            // лимита: сколько его всего, мы не знаем и не выдумываем.
            if Prefs.showMoney, let b = u.session,
               let end = Trend.projected(spent: Money.spent(for: b, in: sessionWindow),
                                         perHour: lastHour.cost, until: b.resetsAt) {
                line += "  \u{00B7} " + L("к сбросу \u{2248}", "by reset \u{2248}") + MoneyView.money(end)
            }
            out.append(line)
        }

        // Прогноз по процентам. Здесь нет ни одного предположения о размере
        // лимита: проценты делятся на проценты, темп берётся из своих же
        // замеров, а сотня - это сотня.
        let target = u.active ?? u.session
        if let b = target {
            let samples = History.load()
            let rate = History.rate(samples, key: b.key)
            if let hit = History.hitsFull(pct: b.pct, rate: rate) {
                let beats = History.beatsReset(hit: hit, reset: b.resetsAt) ?? false
                if beats {
                    out.append("  " + L("при таком темпе до сброса не упрёшься",
                                        "at this pace you will not hit the wall before reset"))
                } else {
                    out.append("  " + L("при таком темпе 100% в \(Fmt.hhmm(hit))",
                                        "at this pace 100% at \(Fmt.hhmm(hit))"))
                }
            } else if rate == nil {
                out.append("  " + L("темпа пока не видно - замеров мало",
                                    "no pace yet - too few samples"))
            }
        }
        return out
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

    // Строка лимита - всегда две: подпись и процент сверху, шкала и всё
    // посчитанное снизу. Однострочного вида больше нет: он экономил высоту,
    // но на нём не помещалось ни денег, ни токенов, а колонки в нём держались
    // добивкой пробелами - то есть только в моноширинном шрифте.
    //
    // Колонки держат ТАБУЛЯТОРЫ, и это главное здесь. Подпись и шкала стоят
    // на одном табуляторе, поэтому левый край текста и левый край полоски
    // совпадают в любом шрифте и при любой длине подписи. Пробелами это не
    // делается: три пробела моноширинного шрифта шире трёх пробелов
    // обычного, и полоска уезжала правее подписи.
    // 24, а не «сколько-нибудь»: если указатель окажется шире табулятора,
    // строка уедет на СЛЕДУЮЩИЙ табулятор - то есть подпись активного лимита
    // прыгнет к правому краю. «▸» шире 24 точек не бывает даже на самом
    // крупном шрифте, который разрешают настройки.
    private static let textColumn: CGFloat = 24   // где начинается и подпись, и шкала

    private func row(for b: Bucket, active: Bool) -> NSMenuItem {
        let accent = Palette.color(for: b)
        let item = NSMenuItem()
        item.isEnabled = true

        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: MenuBarController.textColumn)]
        para.lineSpacing = 2

        // Указатель стоит ДО табулятора, в своей колонке шириной в отступ:
        // иначе активная строка сдвигала бы подпись относительно остальных.
        let mark = active ? "\u{25B8}" : ""
        let title = NSMutableAttributedString(
            string: "\(mark)\t\(b.long)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize) + 1),
                .paragraphStyle: para,
            ])

        // Процент - сразу после шкалы, не наверху отдельной строкой: одно
        // место для взгляда вместо двух. Именно после, а не перед - шкала
        // у Fmt.bar всегда фиксированной длины (Prefs.barWidth, добито
        // пустыми клетками), а у процента ширина гуляет от «3%» до «100%».
        // Поставь его первым - сами шкалы разъезжались бы по горизонтали
        // на пару знаков от строки к строке.
        //
        // Цвет процента - тот же accent, что у шкалы: числом повторяется
        // тот же сигнал, что и цветом, а не идёт особняком нейтральным.
        title.append(NSAttributedString(string: "\t" + Fmt.bar(b.pct) + " \(b.pct)%", attributes: [
            .font: Palette.menuFont,
            .foregroundColor: accent,
            .paragraphStyle: para,
        ]))

        title.append(NSAttributedString(string: tail(for: b), attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize) - 1),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))

        item.attributedTitle = title
        return item
    }

    // Хвост второй строки: когда сброс, во сколько обошлось, сколько токенов.
    //
    // Деньги и токены - измеренный расход по видимым машинам, а не доля
    // лимита: сколько всего выдано, Anthropic не говорит. «≈» здесь про
    // прайс и про неполноту машин, а не про догадку о размере лимита.
    private func tail(for b: Bucket) -> String {
        var s = "  " + Fmt.untilReset(b.resetsAt)
        let clock = Fmt.clock(b.resetsAt)
        if !clock.isEmpty { s += " \u{00B7} " + clock }

        let w = window(for: b)
        if Prefs.showMoney {
            let mv = Money.view(for: b, in: w)
            if mv.spent > 0 { s += "  \u{00B7} \u{2248}" + mv.spentText }
        }
        if Prefs.showTokens {
            let tv = Money.tokens(for: b, in: w)
            if !tv.isEmpty { s += "  \u{00B7} " + tv.text }
        }
        return s
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

    @objc private func checkUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        Updater.shared.check(silent: false) { [weak self] found in
            self?.pendingUpdate = found
        }
    }

    // Тихая проверка раз в сутки: приложение должно само замечать, что вышло
    // новое, а не ждать, пока о нём вспомнят. Показывает строку в меню и
    // ничего не качает без нажатия.
    private func checkUpdatesQuietly() {
        Updater.shared.check(silent: true) { [weak self] found in
            self?.pendingUpdate = found
        }
    }
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
