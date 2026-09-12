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
    // Ошибки по хостам, а не одна: машин может быть несколько, и молчать
    // про упавшую нельзя - её расход просто не войдёт в счёт.
    private var remoteErrors: [String: String] = [:]
    // Новая версия, если фоновая проверка её нашла.
    private var pendingUpdate: String?

    // Сессии: кто работает, кто ждёт ответа. Два источника лежат отдельно
    // намеренно. Свои читаются дёшево и прямо перед показом меню - это
    // несколько маленьких файлов, а не обход расшифровок. Серверные
    // приезжают раз в обход, вместе с деньгами, и между обходами
    // устаревают - поэтому их возраст в меню подписан, а свои считаются
    // текущими.
    private var localSessions: [AgentSession] = []
    private var remoteSessions: [AgentSession] = []
    // Память ТОЛЬКО удалённой машины: приезжает раз в обход вместе с
    // деньгами. Своя не мерится вовсе - на маке памяти обычно много,
    // сложности бывают на сервере.
    private var remoteMemory: [String: MachineMemory] = [:]

    // Куда ушли деньги за недельное окно - по разговорам. Считается тем
    // же проходом, что и сами деньги, - отдельного чтения не стоит.
    private var chats: [Transcripts.ChatUsage] = []
    private var sessions: [AgentSession] {
        return Sessions.sorted(localSessions + remoteSessions)
    }

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
        // Тихая проверка остаётся на первом пути - он проверен временем.
        // Sparkle поднимается только по галочке и только для установки.
        SparkleBridge.shared.startIfEnabled()
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
        // Прайс проверяем и здесь, а не только при запуске. Приложение в
        // трее живёт неделями между перезапусками: с проверкой только на
        // старте «раз в сутки» означало бы «один раз за всё время работы»,
        // и цены после подорожания так и остались бы прошлыми. Сам вызов
        // дешёвый - смотрит отметку времени и обычно сразу возвращается.
        PricingFetch.refreshIfStale { [weak self] in self?.updateTitle() }
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
            self.refreshLocalSessions()
            self.updateTitle()
        }
    }

    // Свои сессии - десяток файлов по полкилобайта в ~/.claude/sessions.
    // Это не обход расшифровок, порога между чтениями здесь не нужно:
    // на живой машине весь каталог читается быстрее, чем перерисовывается
    // строка меню. Отдельная функция, а не строка внутри updateTitle,
    // чтобы чтение файлов не оказалось внутри отрисовки.
    private func refreshLocalSessions() {
        guard Prefs.showSessions || Prefs.effectiveTemplate.contains("{sessions}") else {
            localSessions = []
            return
        }
        // Дочитывание по расшифровкам стоит дороже самих файлов сессий -
        // полмегабайта хвоста на живую сессию против полукилобайта, -
        // но идёт по тому же поводу и в том же потоке: на десятке сессий
        // это единицы миллисекунд, порога между чтениями оно не требует.
        localSessions = Sessions.enrich(Sessions.read(),
                                        watchLoops: Prefs.watchLoops,
                                        showActivity: Prefs.showActivity)
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
        let targets = Prefs.remoteTargets()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Разбивка по проектам - за НЕДЕЛЬНОЕ окно (в списке границ
            // оно второе). Пятичасовое на этот вопрос не отвечает: в нём
            // обычно один проект, и разбивка показывала бы сама себя.
            var byChat: [String: WindowUsage] = [:]
            var w = Transcripts.usage(cutoffs: cutoffs, projects: &byChat, projectsWindow: 1)

            // Удалённые машины считаются тем же способом каждая на своей
            // стороне и складываются сюда. Ошибки не глотаем: без них
            // «считаю все» и «одна не ответила» выглядят одинаково.
            //
            // Хосты опрашиваются ПАРАЛЛЕЛЬНО. Последовательно три хоста при
            // сторожевом таймере в минуту дают три минуты худшего случая -
            // дольше, чем порог между обходами, то есть обход не успевал бы
            // закончиться до следующего. Работа здесь целиком в ожидании
            // сети, так что параллель ничего не стоит.
            var answers: [String: Result<RemoteScan.Answer, RemoteScan.Failure>] = [:]
            if !targets.isEmpty {
                let lock = NSLock()
                let group = DispatchGroup()
                for t in targets {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let r = RemoteScan.usage(host: t.host, path: t.path, cutoffs: cutoffs,
                                                 wantActivity: Prefs.showActivity,
                                                 projectsWindow: Prefs.showProjects ? 1 : -1)
                        lock.lock(); answers[t.host] = r; lock.unlock()
                        group.leave()
                    }
                }
                group.wait()
            }

            // Складываем в порядке списка, а не в порядке ответов: иначе
            // одни и те же числа приходили бы разными между обходами.
            var machines = 1
            var errs: [String: String] = [:]
            var remoteSessions: [AgentSession] = []
            var remoteMemory: [String: MachineMemory] = [:]
            for t in targets {
                switch answers[t.host] {
                case .success(let r) where r.windows.count == w.count:
                    for i in w.indices { w[i] = w[i] + r.windows[i] }
                    machines += 1
                    remoteSessions += r.sessions
                    if !r.memory.isEmpty { remoteMemory[t.host] = r.memory }
                    // Проекты с той машины кладутся в ту же корзину, что и
                    // свои: один проект, над которым работают с двух машин,
                    // должен дать одну строку с общей суммой, а не две.
                    for (key, w) in r.projects {
                        byChat[key] = (byChat[key] ?? WindowUsage()) + w
                    }
                case .success:
                    errs[t.host] = L("ответ не по форме", "malformed answer")
                case .failure(let e):
                    errs[t.host] = e.text
                case nil:
                    break
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.scanning = false
                self.lastScan = Date()
                self.machines = machines
                self.remoteErrors = errs
                self.remoteSessions = remoteSessions
                self.remoteMemory = remoteMemory
                self.chats = Transcripts.named(byChat, top: Prefs.maxChats)
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
        let template = Prefs.effectiveTemplate

        // Кольцо занимает место кружка, а не добавляется к нему: макрос
        // {icon} отдаётся пустым, и он схлопывается вместе со своим
        // разделителем. Иначе в строке стояли бы оба - и картинка, и знак.
        let ring = Prefs.barRing && template.contains("{icon}")
        let text = BarTitle.render(template, usage: u,
                                   money: money ?? nil, tokens: tokens ?? nil,
                                   sessions: Sessions.summary(sessions),
                                   iconGlyph: ring ? "" : nil)
        // Строка меню остаётся нейтральной, пока всё спокойно: цветом
        // в строке меню стоит тревожить только по делу.
        let color = u.worst.map { Palette.titleColor(for: $0) } ?? NSColor.labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: Palette.barFont,
        ])

        if ring {
            // С какой стороны строки стоял знак, с той стороны встаёт и
            // кольцо. Шаблон по умолчанию начинается с {icon}, но свой
            // формат может кончаться им - и переносить кольцо молча
            // в начало значит переставить человеку его же строку.
            let trailing = template.trimmingCharacters(in: .whitespaces).hasSuffix("{icon}")
            button.image = RingBar.image(percent: u.worst?.pct ?? 0, color: color,
                                         font: Palette.barFont, trailing: trailing)
            button.imagePosition = trailing ? .imageTrailing : .imageLeading
        } else {
            // Снимать обязательно: галочку можно выключить на живом
            // приложении, и картинка от прошлой отрисовки осталась бы
            // висеть рядом со знаком.
            button.image = nil
            button.imagePosition = .noImage
        }
    }

    // --- меню ---------------------------------------------------------------
    // Открытие меню - хороший повод освежить данные: человек смотрит именно
    // сейчас. Порог между запросами внутри fetch всё равно не даст частить.
    func menuWillOpen(_ menu: NSMenu) {
        // Сессии читаются здесь, а не только по ответу сети: ответ может
        // прийти из кэша и вообще не дойти до чтения файлов, а «ждёт меня»
        // устаревшее на пять минут - это ровно та цифра, ради которой
        // меню и открывают.
        refreshLocalSessions()
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
            // «Сверх лимита» участвует в подсчёте колонки наравне со
            // строками лимитов: он стоит в тех же колонках, и если считать
            // ширину без него, его собственное имя налезет на процент.
            // Верхняя граница обязательна: без неё ширина меню зависит от
            // того, как Anthropic назовёт следующую модель. См. Fmt.clip.
            let nameCells = min(MenuBarController.nameLimit,
                                (u.buckets.map { $0.short.count } + [extraName.count]).max() ?? 4)
            let cols = columns(nameCells: nameCells, font: Palette.menuFont)
            for b in u.buckets {
                menu.addItem(row(for: b, active: u.active?.key == b.key, cols: cols))
            }
            menu.addItem(.separator())
            menu.addItem(extraRow(u.extra, cols: cols))
            if Prefs.showMoney || Prefs.showTokens {
                menu.addItem(dim(estimateNote()))
                for (host, e) in remoteErrors.sorted(by: { $0.key < $1.key }) {
                    menu.addItem(dim(L("\(host) не ответил: \(e)",
                                       "\(host) did not answer: \(e)")))
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
            for item in chatRows() { menu.addItem(item) }
            for item in sessionRows() { menu.addItem(item) }
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
        // ОДИН пункт. Каким путём проверять - забота приложения, не человека.
        //
        // Сначала их было два, и причина была настоящей: я не мог отличить
        // отказ Sparkle от нормального «версия последняя», а переключаться
        // вслепую значило дёргать второй обновлятор на каждом спокойном
        // ответе. Различие нашлось - Sparkle сообщает эти два случая разными
        // вызовами делегата, - и второй пункт стал лишним выбором, которого
        // человек делать не должен.
        //
        // Выключить Sparkle совсем по-прежнему можно, но галочкой в
        // настройках, а не вторым пунктом в меню: это настройка, а не
        // ежедневное решение.
        menu.addItem(action(L("Проверить обновления\u{2026}", "Check for updates\u{2026}"),
                            #selector(checkUpdates), key: ""))
        // Об отказе Sparkle молчать нельзя даже теперь, когда он не мешает
        // обновиться: иначе «работает» и «молча падает каждый раз, а
        // обновляет запасной» выглядят одинаково, и поломка живёт годами.
        if case .failed(let e) = SparkleBridge.shared.state {
            menu.addItem(dim(L("Sparkle не смог, шёл через GitHub: \(Fmt.clip(e, 32))",
                               "Sparkle failed, used GitHub: \(Fmt.clip(e, 32))")))
        }
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
        // Машины перечисляются по именам, а не числом.
        //
        // Стояло «по расшифровкам двух машин: этой и <host>» - и это врало
        // сразу при трёх, а хуже того, молчало о том, КАКАЯ не вошла: если
        // из двух серверов ответил один, подпись всё равно говорила «двух».
        // Считаем только те, что реально сложились: machines растёт на
        // успешный ответ, а не на строку в настройке.
        let answered = Prefs.remoteTargets().map { $0.host }
            .filter { remoteErrors[$0] == nil }
        if !answered.isEmpty {
            let names = answered.joined(separator: ", ")
            return L("\(what) - по расшифровкам \(machines) машин: этой\(roots) и \(names)\(price)",
                     "\(what) - from \(machines) machines: this one\(roots) and \(names)\(price)")
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

    // Строка лимита - ОДНА, и второго ряда нет вовсе: полоска, короткое
    // имя, процент, сколько осталось, деньги и токены. Всё, что было
    // внизу, поместилось в тот же ряд, как только оттуда ушли часы сброса.
    //
    // Было наоборот - два ряда всегда, и верхний уходил целиком под
    // подпись «5-часовое окно». Ряд ради подписи, которую заменяет «5ч»,
    // удваивал высоту меню на ровном месте.
    //
    // Колонки держат ТАБУЛЯТОРЫ, а не пробелы: пробел пропорционального
    // шрифта уже пробела моноширинного, и добивка разъезжается ровно там,
    // где человек сменил шрифт. Табулятор процента - ПРАВЫЙ: у «3%» и
    // «100%» разная ширина, по левому краю числа стояли бы лесенкой.

    // Ширина знака моноширинного шрифта - единица измерения всех колонок.
    // Ноль на всякий случай отбиваем: шрифт из настроек может не найтись,
    // и делить колонки на ноль - значит сложить их все в одну точку.
    // Десять знаков покрывают все нынешние имена («Sonnet», «Fable», «Сверх»,
    // «5ч») с запасом и не дают меню разрастись от чужого длинного имени.
    static let nameLimit = 10

    private func cellWidth(_ font: NSFont) -> CGFloat {
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return w > 0 ? w : max(4, font.pointSize * 0.6)
    }

    // Колонки строки лимита. Считаются один раз на всё меню и раздаются
    // строкам: посчитай их каждая строка сама - у «5ч» и у «Sonnet»
    // проценты встали бы в разных местах, и столбиком числа читаться
    // перестали бы.
    private struct Columns {
        let cell: CGFloat     // ширина знака моноширинного шрифта
        let capW: CGFloat     // длина нарисованной полоски
        let capH: CGFloat     // её толщина
        let para: NSParagraphStyle
    }

    private func columns(nameCells: Int, font mono: NSFont) -> Columns {
        let ch = cellWidth(mono)
        let capW = CapsuleBar.width(cells: Prefs.barWidth, unit: ch)

        // Полоска знаками занимает всю ширину клетки, рисованная - половину.
        // Считать колонку по одной из них нельзя: при выключенной капсуле
        // шкала перескочила бы через свой табулятор, и имя лимита улетело
        // бы на СЛЕДУЮЩИЙ - то есть в правую колонку процента.
        let barW = Prefs.menuCapsule ? capW : ch * CGFloat(Prefs.barWidth)

        // Колонка указателя - от ширины знака, а не числом точек: «▸» на
        // шрифте 20 вдвое шире, чем на 9, и жёсткие 24 точки означали бы
        // то запас в три пробела, то перескок на следующий табулятор.
        let xBar = max(12, (ch * 1.6).rounded())
        let xName = xBar + barW + ch
        // Правый край числа. Колонку имени считаем по САМОМУ длинному имени
        // из тех, что пришли, а не по «Sonnet»: имя модели придумывает
        // Anthropic, и на девятибуквенном зашитая ширина означала бы, что
        // имя налезает на правый табулятор процента - а текст, переросший
        // правый табулятор, уезжает на следующий, то есть в конец строки.
        // Плюс пробел на отбивку и четыре знака под «100%».
        let xPct = xName + ch * CGFloat(max(4, nameCells) + 1 + 4)

        let para = NSMutableParagraphStyle()
        para.tabStops = [
            NSTextTab(textAlignment: .left,  location: xBar),
            NSTextTab(textAlignment: .left,  location: xName),
            NSTextTab(textAlignment: .right, location: xPct),
            NSTextTab(textAlignment: .left,  location: xPct + ch),
            // Деньги и токены - каждое своей колонкой, а не сразу за
            // остатком: у «22м» и «3д 3ч» разная ширина, у «≈$5.20» и
            // «≈$532» тоже, и без колонок оба числа гуляли бы от строки
            // к строке. Восемь клеток под деньги - это «≈$99.99» и запас.
            NSTextTab(textAlignment: .left,  location: xPct + ch * 8),
            NSTextTab(textAlignment: .left,  location: xPct + ch * 16),
        ]
        para.lineSpacing = 2
        return Columns(cell: ch, capW: capW,
                       capH: CapsuleBar.height(fontSize: CGFloat(Prefs.menuFontSize)),
                       para: para)
    }

    private func row(for b: Bucket, active: Bool, cols: Columns) -> NSMenuItem {
        let accent = Palette.color(for: b)
        let item = NSMenuItem()
        item.isEnabled = true

        let mono = Palette.menuFont
        let title = NSMutableAttributedString()
        func put(_ s: String, _ f: NSFont, _ c: NSColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]))
        }

        // Указатель стоит ДО первого табулятора, в своей колонке: иначе
        // активная строка сдвигала бы полоску относительно остальных.
        put(active ? "\u{25B8}" : "", mono, accent)
        put("\t", mono, .labelColor)

        if Prefs.menuCapsule {
            title.append(CapsuleBar.attachment(percent: b.pct, color: accent,
                                               width: cols.capW, height: cols.capH, font: mono))
        } else {
            put(Fmt.bar(b.pct), mono, accent)
        }

        put("\t" + Fmt.clip(b.short, MenuBarController.nameLimit), mono, .labelColor)
        // Цвет процента - тот же accent, что у полоски: числом повторяется
        // тот же сигнал, что и цветом, а не идёт особняком нейтральным.
        put("\t\(b.pct)%", mono, accent)
        put("\t" + Fmt.untilReset(b.resetsAt), mono, .secondaryLabelColor)

        // Деньги и токены - в том же ряду, на месте часов сброса.
        //
        // Часов здесь больше нет намеренно (слово Антона 05.09.2026): на
        // вопрос «когда обнулится» уже отвечает отсчёт рядом, а «вс 02:59»
        // повторял тот же ответ другими словами и занимал место, которое
        // стоит дороже - под то, что больше нигде не сказано. Макрос
        // {5h.reset} для строки трея остался, там отсчёта может не быть.
        // Пустая колонка проходится табулятором насквозь: если денег нет,
        // а токены есть, второй табулятор ставит их на своё место, а не
        // подтягивает влево.
        let sp = spentParts(for: b)
        if !sp.money.isEmpty || !sp.tokens.isEmpty {
            put("\t" + sp.money, mono, .secondaryLabelColor)
            if !sp.tokens.isEmpty { put("\t" + sp.tokens, mono, .tertiaryLabelColor) }
        }

        // Стиль абзаца - на всю строку разом, а не по кускам: у картинки
        // куска со стилем нет вовсе, и табуляторы после неё считались бы
        // по умолчанию, то есть каждые 28 точек.
        title.addAttribute(.paragraphStyle, value: cols.para,
                           range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
        return item
    }

    // Хвост строки: во сколько обошлось окно и сколько токенов. Пусто,
    // пока обе галочки сняты, - и тогда строка кончается остатком.
    //
    // Деньги и токены - измеренный расход по видимым машинам, а не доля
    // лимита: сколько всего выдано, Anthropic не говорит. «≈» здесь про
    // прайс и про неполноту машин, а не про догадку о размере лимита.
    private func spentParts(for b: Bucket) -> (money: String, tokens: String) {
        let w = window(for: b)
        var money = ""
        var tokens = ""
        if Prefs.showMoney {
            let mv = Money.view(for: b, in: w)
            if mv.spent > 0 { money = mv.spentMarked }
        }
        if Prefs.showTokens {
            let tv = Money.tokens(for: b, in: w)
            if !tv.isEmpty { tokens = tv.text }
        }
        return (money, tokens)
    }

    // «Сверх лимита» - такая же строка, как у лимитов: полоска, имя,
    // процент, деньги хвостом. Вопрос у неё тот же самый - сколько от
    // потолка съедено, - и отвечать на него другим языком незачем.
    // Раньше это был абзац текста в моноширинном шрифте: рядом с
    // однострочными лимитами он читался как чужая вставка.
    //
    // Три случая, и они разные по смыслу. Выключено - процента нет и быть
    // не может, полоски тоже. Потолок не задан - деньги есть, доли нет,
    // и это сказано словами, а не нарисовано пустой шкалой. Всё есть -
    // полная строка.
    private var extraName: String { return L("Сверх", "Extra") }

    private func extraRow(_ e: Extra, cols: Columns) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true

        let mono = Palette.menuFont
        let small = NSFont.systemFont(ofSize: CGFloat(Prefs.menuFontSize) - 1)
        let title = NSMutableAttributedString()
        func put(_ s: String, _ f: NSFont, _ c: NSColor) {
            title.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]))
        }

        if !e.enabled {
            put("\t\t" + L("Сверх лимита: выключено", "Extra usage: off"),
                small, .secondaryLabelColor)
        } else if let limit = e.limitMinor, limit > 0, let p = e.percent {
            let accent = Palette.color(forPercent: p, severity: "normal")
            put("\t", mono, .labelColor)
            if Prefs.menuCapsule {
                title.append(CapsuleBar.attachment(percent: p, color: accent,
                                                   width: cols.capW, height: cols.capH,
                                                   font: mono))
            } else {
                put(Fmt.bar(p), mono, accent)
            }
            put("\t" + extraName, mono, .labelColor)
            put("\t\(p)%", mono, accent)
            put("\t" + e.usedText + L(" из ", " of ") + e.money(limit),
                mono, .secondaryLabelColor)
        } else {
            // Потолок не задан - не выдумываем «из —» и не рисуем шкалу,
            // которой не от чего считаться.
            put("\t\t" + L("Сверх лимита: ", "Extra usage: ") + e.usedText
                + L(" за месяц, персональный лимит не задан",
                    " this month, no personal cap set"),
                small, .secondaryLabelColor)
        }

        title.addAttribute(.paragraphStyle, value: cols.para,
                           range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
        return item
    }

    // Раздел «сессии»: кто работает, а кто ждёт ответа.
    //
    // Отвечает на другой вопрос, чем лимиты, и поэтому стоит отдельным
    // разделом, а не колонкой в их строках: лимит - это «работать дальше
    // или подождать», а это - «не стоит ли агент». Сессия, упёршаяся в
    // разрешение, лимита не тратит вовсе.
    //
    // Пустой раздел не показываем совсем: заголовок «Сессии» без строк
    // занимает место и не отвечает ни на что.
    // Куда ушли деньги за неделю - по разговорам.
    //
    // Отвечает на «на что», когда сумма уже ответила на «сколько». Без
    // этого недельная цифра ни к какому решению не ведёт: она большая
    // или маленькая, и всё.
    //
    // Доля в процентах стоит рядом с деньгами намеренно. Деньги здесь -
    // счёт по прайсу API, а работа идёт по подписке: сама сумма ничему
    // не равна, и человеку про неё известно только то, что это оценка.
    // А вот ДОЛЯ верна независимо от того, сколько стоит токен: если
    // десятая часть недели ушла в один разговор, это правда и по
    // подписке тоже.
    private func chatRows() -> [NSMenuItem] {
        guard Prefs.showSpendByChat, !chats.isEmpty else { return [] }
        let total = chats.reduce(0.0) { $0 + $1.cost }
        guard total > 0 else { return [] }

        var out: [NSMenuItem] = [.separator(),
                                 dim(L("Куда ушло за неделю", "Where the week went"))]
        let shown = chats.prefix(Prefs.maxChats)
        for c in shown {
            let share = Int((c.cost / total * 100).rounded())
            // Имя длиннее остальной строки, поэтому режется ОНО, а не
            // числа: «≈$392 · 10%» без имени бесполезно, имя без хвоста
            // всё ещё узнаётся.
            let tail = " \u{00B7} \u{2248}\(MoneyView.money(c.cost)) \u{00B7} \(share)%"
            out.append(plain(Fmt.clip(c.title, max(8, Sessions.maxLine - tail.count)) + tail))
        }
        // Хвост не выбрасываем молча: «показано 5 из 135» без остатка
        // читается как «всего пять», и доли в строках выше начинают
        // выглядеть так, будто они не сходятся к сотне.
        if chats.count > shown.count {
            let rest = chats.dropFirst(shown.count).reduce(0.0) { $0 + $1.cost }
            let share = Int((rest / total * 100).rounded())
            out.append(dim(L("и ещё \(chats.count - shown.count) \u{00B7} \(share)%",
                             "\(chats.count - shown.count) more \u{00B7} \(share)%")))
        }
        return out
    }

    private func sessionRows() -> [NSMenuItem] {
        guard Prefs.showSessions else { return [] }
        // nameLimit здесь СВОЙ, а не колонки лимитов: имя сессии человек
        // задаёт сам через `/rename`, и десяти знаков ему мало.
        let lines = Sessions.lines(sessions, remoteScanAt: lastScan,
                                   machines: remoteMemory)
        guard !lines.rows.isEmpty else { return [] }

        var out: [NSMenuItem] = [.separator(), dim(lines.header)]
        for r in lines.rows { out.append(plain(r)) }
        for n in lines.notes { out.append(dim(n)) }
        return out
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

    // Одна кнопка на оба пути.
    //
    // Порядок: сначала Sparkle - он для этого и сделан. Нечем спросить
    // (не собран, выключен галочкой) - сразу свой путь. Спросили и он
    // отказал - свой путь по ответу делегата, без участия человека.
    //
    // «Версия последняя» запасной путь НЕ поднимает: это полученный ответ,
    // просто отрицательный. Иначе каждый спокойный ответ Sparkle стоил бы
    // второго обхода GitHub и второго диалога.
    @objc private func checkUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        let ok = SparkleBridge.shared.checkForUpdates(onFailure: { [weak self] in
            self?.checkViaGitHub()
        })
        if !ok { checkViaGitHub() }
    }

    // Свой путь: GitHub-релизы со сверкой sha256 из текста релиза.
    private func checkViaGitHub() {
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
    // Открыть настройки не по клику, а по требованию снаружи.
    //
    // Нужно ровно для одного: снимок окна на настоящем macOS в CI. Вёрстка
    // окна не покрывается ни одним тестом - ни «-parse», ни разбором логики,
    // - и до сих пор единственным способом узнать, что получилось, был
    // человек со скриншотом. Это дорого и медленно: три версии подряд
    // правились вслепую.
    func showSettingsForShot(width: CGFloat?) {
        openSettings()
        // Растянутое окно - отдельный случай, и именно в нём ломалась
        // вёрстка трижды подряд: ряды полей и таблицы раздают лишнюю
        // ширину между своими элементами, и на узком окне этого не видно
        // вовсе. Снимок только узкого окна такую поломку не ловит.
        if let w = width, let win = settingsWindow?.window {
            var f = win.frame
            f.size.width = w
            win.setFrame(f, display: true)
        }
    }

    // Снимок выпадающего меню - тем же способом, что и окно настроек.
    //
    // Вёрстку строки лимита не видит ни -parse, ни тесты: колонки, отступы,
    // высота ряда и то, рисуется ли картинка внутри пункта меню вообще, -
    // всё это существует только на настоящем macOS. До этого снимка
    // единственным способом узнать было поставить сборку Антону.
    //
    // Цифры выдуманы намеренно: в CI нет ни ключа, ни сети, и настоящее
    // меню показало бы «загружаю…». Проценты подобраны так, чтобы в кадр
    // попали все три уровня тревоги разом - спокойный, внимание, тревога:
    // снимок с одним цветом подтверждает только одну треть.
    func showMenuForShot() {
        let iso = ISO8601DateFormatter()
        let soon = iso.string(from: Date().addingTimeInterval(2 * 3600 + 14 * 60))
        let later = iso.string(from: Date().addingTimeInterval(3 * 86400 + 4 * 3600))
        let body = """
        {
          "five_hour":        {"utilization": 57.0, "resets_at": "\(soon)"},
          "seven_day":        {"utilization": 13.0, "resets_at": "\(later)"},
          "seven_day_opus":   {"utilization": 92.0, "resets_at": "\(later)"},
          "seven_day_sonnet": {"utilization": 4.0,  "resets_at": "\(later)"},
          "nimbus_quill":     {"utilization": 20.0, "resets_at": "\(later)"},
          "extra_usage": {"is_enabled": true, "monthly_limit": 20000,
                          "used_credits": 13963.0, "decimal_places": 2}
        }
        """
        usage = UsageParser.parse(body: body, fetchedAt: Date(), isStale: false)
        lastError = nil
        updateTitle()

        // Деньги и токены в CI взять неоткуда: расшифровок на машине нет.
        // А теперь именно они стоят в конце ряда - снимок без них проверял
        // бы ровно ту часть строки, которая и так не менялась. Поэтому окна
        // заполняются руками, а галочки включаются на время снимка.
        Prefs.showMoney = true
        Prefs.showTokens = true
        var sw = WindowUsage()
        sw.byFamily["opus"] = TokenTally(input: 120_000, output: 45_000,
                                         cacheWrite: 900_000, cacheRead: 74_000_000,
                                         requests: 310, cacheWrite1h: 0)
        sessionWindow = sw
        var ww = WindowUsage()
        ww.byFamily["opus"] = TokenTally(input: 1_500_000, output: 420_000,
                                         cacheWrite: 9_000_000, cacheRead: 890_000_000,
                                         requests: 3_800, cacheWrite1h: 0)
        ww.byFamily["fable"] = TokenTally(input: 90_000, output: 30_000,
                                          cacheWrite: 400_000, cacheRead: 21_000_000,
                                          requests: 240, cacheWrite1h: 0)
        weeklyWindow = ww

        // Сессии в CI взять тоже неоткуда: ~/.claude/sessions там нет,
        // и раздел не попал бы в кадр вовсе. Состав подобран так, чтобы
        // в снимок разом попали все четыре состояния и обе машины: по
        // одному цвету и одному состоянию проверяется одна четверть.
        Prefs.showSessions = true
        // Занятие в снимке ВКЛЮЧАЕМ, хотя по умолчанию оно выключено:
        // выключенное не попало бы в кадр, а рост ширины меню от него
        // как раз и есть то, что снимок обязан поймать. Ровно так в
        // 1.7.0 нашлась строка шире строк лимитов - тесты её не видели,
        // потому что предел ширины они проверяют, а ФАКТИЧЕСКУЮ ширину
        // отрисованного текста задаёт шрифт, и она бывает больше.
        Prefs.showActivity = true
        localSessions = [
            AgentSession(pid: 901, name: "budget-app", folder: "budget-app",
                         surface: "Terminal", state: .waiting,
                         waitingFor: L("разрешение на запись", "write permission"),
                         since: Date().addingTimeInterval(-260), machine: ""),
            // Крутящаяся - первой по порядку и с указателем. В кадре
            // проверяется и то, и другое: что она вытеснила ждущую
            // наверх и что подпись «крутится: Bash ×4» не разъехалась.
            AgentSession(pid: 902, name: "climits", folder: "climits",
                         surface: "VS Code", state: .busy, waitingFor: nil,
                         since: Date().addingTimeInterval(-70),
                         loop: LoopAlert(tool: "Bash", count: 4, what: "swift build"),
                         machine: ""),
            // А у этой хвост занят занятием - тем самым, которого раньше
            // в строке не было вовсе.
            AgentSession(pid: 903, name: "sintra", folder: "sintra",
                         surface: "Terminal", state: .idle, waitingFor: nil,
                         since: Date().addingTimeInterval(-4200),
                         activity: L("посчитай отказы за сентябрь",
                                     "count declines for September"),
                         machine: ""),
            // Памяти у своих сессий в фикстуре нет намеренно: её больше
            // не мерят и на живой машине. Снимок должен показывать то,
            // что человек увидит, иначе он проверяет не тот экран.
        ]
        remoteSessions = [
            AgentSession(pid: 904, name: "work-71", folder: "harness",
                         surface: "SDK", state: .unknown, waitingFor: nil,
                         since: nil, machine: "vps7",
                         rssMB: 270, swapMB: 184),
        ]
        // Разбивка по разговорам - тоже в кадр, по той же причине: это
        // новый раздел, и его строки длиннее строк сессий. Имена взяты
        // нарочно разной длины и в обоих видах, какие бывают: своё имя
        // (`/rename`) и первый запрос - второй длиннее и режется.
        Prefs.showSpendByChat = true
        func cu(_ title: String, _ out: Int) -> Transcripts.ChatUsage {
            var w = WindowUsage()
            w.byFamily["opus"] = TokenTally(input: out / 3, output: out,
                                            cacheWrite: out * 2, cacheRead: out * 40,
                                            requests: out / 100, cacheWrite1h: 0)
            return Transcripts.ChatUsage(key: title, title: title, usage: w)
        }
        chats = [
            cu(L("Организационный чат", "Org chat"), 380_000),
            cu(L("проверь мою настройку MCP, насколько она рабочая",
                 "check my MCP setup, is it actually working"), 120_000),
            cu(L("Тариф Альфы", "Alpha pricing"), 42_000),
            cu(L("посчитай отказы за сентябрь", "count declines for September"), 18_000),
            cu(L("починить сборку climits", "fix the climits build"), 9_000),
            cu(L("мелочь", "small one"), 900),
        ]
        lastScan = Date().addingTimeInterval(-95)
        remoteMemory = ["vps7": MachineMemory(totalMB: 3915, availableMB: 1224,
                                              swapTotalMB: 7030, swapUsedMB: 1743)]
        // Адрес хоста в снимке тоже подставляем: без него строка про
        // память СЕРВЕРА в кадр не попадает, и её вёрстка остаётся
        // непроверенной. Так и вышло на снимке 1.10.0.
        Prefs.remoteHosts = "vps7\nvps8"

        // Sparkle в снимке ВКЛЮЧАЕМ, хотя по умолчанию он выключен.
        //
        // Это единственная возможная проверка того, что чужой фреймворк
        // вообще поднимается: собрался - видно по сборке, а загрузился ли
        // dylib по нашему rpath и не ругается ли апдейтер на настройку,
        // видно только на живом macOS. В меню состояние подписано словами,
        // значит на снимке будет либо два пункта обновления, либо строка
        // «Sparkle не смог» с причиной.
        Prefs.sparkleEnabled = true
        SparkleBridge.shared.startIfEnabled()

        // Тёмная тема задаётся САМОМУ МЕНЮ, а не системе и не приложению.
        // Проверено двумя прогонами: `defaults write -g AppleInterfaceStyle`
        // в CI не сработал вовсе, `NSApp.appearance` - тоже: меню
        // статус-элемента своё оформление у приложения не наследует.
        // Оба раза снимок «тёмной» выходил светлым, то есть подложка
        // полоски на тёмном фоне так и оставалась непроверенной.
        if ProcessInfo.processInfo.environment["CLIMITS_UI_SHOT_DARK"] == "1" {
            statusItem.menu?.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Кликом по своей же кнопке: программного «покажи меню статус-
        // элемента» у AppKit нет, а popUpMenu рисует его не там - в углу
        // экрана вместо строки меню, то есть снимает не то, что видит
        // человек. Вызов не возвращается, пока меню открыто: это и нужно -
        // снимок делает соседний процесс.
        statusItem.button?.performClick(nil)
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
