import AppKit

// Окно настроек. Свёрстано кодом, без xib и storyboard: приложение собирается
// одним вызовом swiftc, и любой ресурсный файл здесь стал бы лишним поводом
// для сборки развалиться на чужой машине.
//
// ВКЛАДКИ (1.22.0). До этого окно было одной лентой: 28 галочек, 17 полей
// и 15 серых абзацев пояснений подряд, и нужное приходилось искать
// прокруткой. Слово Антона 10.10.2026, со снимками Usage for Claude:
// «Очень удобно разделено меню, не приходится искать ничего как у нас...
// сейчас все очень шумит». Теперь пять вкладок, на каждой несколько
// карточек; вид строки меню выбирается картинкой с живым предпросмотром,
// а пояснения ушли в подсказки при наведении - под контролом остаётся
// строка, и только там, где без неё ошибутся.
//
// Настройки под вкладками ПРЕЖНИЕ, ключи те же: обновление не трогает
// того, что человек настроил, а `defaults write` работает как работал.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {

    private var checkboxes: [String: NSButton] = [:]
    private var tabs: NSSegmentedControl!
    private var tabView: NSTabView!

    // Строка меню
    private var previewView: NSImageView!
    private var iconTiles: [NSButton] = []
    private var glyphRow: NSView!
    private var linesSeg: NSSegmentedControl!
    private var resetSeg: NSSegmentedControl!
    private var templateField: NSTextField!
    private var customToggle: NSButton!
    private var customNote: NSTextField!

    // Меню
    private var cardsSeg: NSSegmentedControl!

    // Уведомления
    private var bannerHolder: NSStackView!
    private var rulesStack: NSStackView!
    private var addRuleButton: NSButton!
    private var rules: [NotifyRule] = []

    // Машины
    private var remoteField: NSComboBox!
    // Список машин в момент, когда открыли выпадающий список. Выбор
    // дописывается к НЕМУ, а не к тексту после прошлого шага: иначе проход
    // стрелками mono -> vps8 -> vps9 оставлял в списке все три (ревью правки
    // 09.10.2026). Сбрасывается правкой текста руками.
    private var hostsBase: String?
    private var remoteResult: NSTextField!
    private var loadStack: NSStackView!

    // Основные
    private var intervalPopup: NSPopUpButton!
    private var loginToggle: NSButton!

    private var disclosed: [(content: NSView, holder: NSStackView, button: NSButton)] = []

    // Ноль - «частоту выбирает приложение»: 2 минуты, пока смотришь
    // в меню, 5 - пока идёт работа, 15 - в простое.
    private let intervals: [(String, Int)] = [
        (L("сама: 2-15 минут по ситуации", "auto: 2-15 minutes as needed"), 0),
        (L("каждую минуту", "every minute"), 60),
        (L("раз в 5 минут", "every 5 minutes"), 300),
        (L("раз в 15 минут", "every 15 minutes"), 900),
        (L("раз в 30 минут", "every 30 minutes"), 1800),
    ]

    private static let tabTitles = [
        L("Строка меню", "Menu bar"),
        L("Меню", "Menu"),
        L("Уведомления", "Notifications"),
        L("Машины", "Machines"),
        L("Основные", "General"),
    ]

    convenience init() {
        // Высота окна - по экрану, а не по содержимому: на макбуке с его
        // 900 точками по высоте окно, впритык равное видимой области,
        // ставится под самый край. Содержимое вкладки прокручивается.
        let maxHeight: CGFloat = 720
        let available = (NSScreen.main?.visibleFrame.height ?? maxHeight) - 60
        let height = max(420, min(maxHeight, available))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("Настройки climits", "climits settings")
        w.minSize = NSSize(width: 560, height: 380)
        w.center()
        self.init(window: w)
        build()
    }

    // Раскрыть все свёрнутые разделы - для снимка в CI: свёрнутое не
    // попадает в кадр, и его вёрстку иначе не видит никто.
    func expandAllForShot() {
        for d in disclosed {
            d.button.state = .on
            toggleDisclosure(d.button)
        }
    }

    // Открыть вкладку по номеру - для снимка в CI.
    func selectTab(_ i: Int) {
        guard i >= 0 && i < Self.tabTitles.count else { return }
        tabs.selectedSegment = i
        tabView.selectTabViewItem(at: i)
        if i == 2 { refreshBanner() }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Разрешение на уведомления могли поменять в системных настройках,
        // пока окно было закрыто: плашка обязана говорить про сейчас.
        refreshBanner()
    }

    private func build() {
        guard let content = window?.contentView else { return }

        // Версия и ссылка прибиты к низу окна и НЕ прокручиваются: версия
        // нужна ровно в тот момент, когда что-то пошло не так и надо
        // сказать какую.
        let footer = versionLine()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        tabs = NSSegmentedControl(labels: Self.tabTitles, trackingMode: .selectOne,
                                  target: self, action: #selector(switchTab(_:)))
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)

        tabView = NSTabView()
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        let pages = [barPage(), menuPage(), notifyPage(), machinesPage(), generalPage()]
        for (i, p) in pages.enumerated() {
            let item = NSTabViewItem(identifier: "tab\(i)")
            item.label = Self.tabTitles[i]
            item.view = p
            tabView.addTabViewItem(item)
        }

        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            tabView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        markIconTiles()
        buildRules()
        buildLoadToggles()
        updatePreview()
        // Свой формат включён - его раздел открыт сразу, а не спрятан.
        if Prefs.useCustomTemplate, let first = disclosed.first {
            first.button.state = .on
            toggleDisclosure(first.button)
        }
    }

    @objc private func switchTab(_ sender: NSSegmentedControl) {
        selectTab(sender.selectedSegment)
    }

    // MARK: - Вкладка «Строка меню»

    private func barPage() -> NSView {
        // Предпросмотр - сверху и первым: всё, что ниже, правит именно его,
        // а править то, чего не видишь, невозможно.
        previewView = NSImageView()
        previewView.imageScaling = .scaleNone
        previewView.translatesAutoresizingMaskIntoConstraints = false
        let pill = PillView(previewView)
        // По центру карточки: стопка во всю ширину, предпросмотр в средней
        // области тяжести.
        let holder = NSStackView()
        holder.orientation = .horizontal
        holder.setViews([pill], in: .center)
        let previewCard = CardView([holder])
        previewCard.toolTip = L("Так будет выглядеть строка в трее - на выдуманных цифрах.",
                                "This is how the menu bar line will look, on sample numbers.")

        // Значок - картинками, как он и выглядит в трее.
        let ringTip = L("Кольцо показывает самый нагруженный лимит процентом: дуга растёт непрерывно, а знак - тремя ступенями. Места занимает столько же.",
                        "The ring shows the busiest limit as a percentage: the arc grows smoothly, the glyph in three steps. Same width.")
        iconTiles = [
            iconTile(.none, L("Нет", "None"),
                     BarImage.image(lines: ["37%"], color: .labelColor, icon: .none, height: 22)),
            iconTile(.glyph, L("Знак", "Glyph"),
                     BarImage.image(lines: [], color: .labelColor, icon: .glyph(Fmt.icon(for: 62)), height: 22)),
            iconTile(.ring, L("Кольцо", "Ring"),
                     BarImage.image(lines: [], color: .labelColor, icon: .ring(62), height: 22)),
        ]
        iconTiles[2].toolTip = ringTip
        let tilesRow = NSStackView(views: iconTiles)
        tilesRow.orientation = .horizontal
        tilesRow.spacing = 10
        let glyphCombo = combo(L("знаки", "glyphs"), "iconSet", Prefs.iconSet, Presets.iconSet, width: 190)
        glyphCombo.toolTip = L("Три знака через запятую: спокойно, внимание, тревога. Можно вписать своё, включая эмодзи.",
                               "Three glyphs separated by commas: calm, warning, alarm. Your own work too, emoji included.")
        glyphRow = glyphCombo
        let iconCard = CardView([tilesRow, glyphRow])

        // Строки и сброс - по одному выбору на ряд.
        linesSeg = NSSegmentedControl(labels: [L("5ч", "5h"), L("Неделя", "Week")],
                                      trackingMode: .selectAny,
                                      target: self, action: #selector(linesPicked(_:)))
        linesSeg.setSelected(Prefs.showSession, forSegment: 0)
        linesSeg.setSelected(Prefs.showWeekly, forSegment: 1)
        linesSeg.toolTip = L("Одно окно со временем - процент крупно, время мельче под ним. Оба окна - две строки друг над другом. В строку - через свой формат.",
                             "One window with time - big percent, smaller time below. Both windows - two stacked lines. One line - via a custom format.")
        resetSeg = NSSegmentedControl(labels: [L("Нет", "Off"), L("Отсчёт", "Countdown"), L("Часы", "Clock")],
                                      trackingMode: .selectOne,
                                      target: self, action: #selector(resetPicked(_:)))
        resetSeg.selectedSegment = Prefs.ResetStyle.allCases.firstIndex(of: Prefs.resetStyle) ?? 1
        resetSeg.toolTip = L("Отсчёт отвечает на «сколько осталось», часы - на «попадёт ли сброс на рабочий день».",
                             "The countdown answers \"how long is left\", the clock - \"will the reset land on a working day\".")
        let showCard = CardView([
            line(L("Строки", "Lines"), linesSeg,
                 note: L("Одно - процент над временем, оба - друг над другом",
                         "One - percent over time; both - stacked")),
            separator(),
            line(L("Сброс", "Reset"), resetSeg),
        ])

        let extraCard = CardView([
            check("showWorst", L("Самый нагруженный лимит", "The busiest limit"), Prefs.showWorst),
            check("showActive", L("Что упрётся первым", "What hits first"), Prefs.showActive),
            check("showModels", L("Лимиты по моделям: O, S, F", "Per-model limits: O, S, F"), Prefs.showModels),
            check("showExtra", L("Потрачено сверх лимита", "Extra usage spent"), Prefs.showExtra),
            check("showExtraPct", L("Сверх лимита, процентом", "Extra usage, percent"), Prefs.showExtraPct),
        ])

        // Свой формат живёт в свёрнутой «Тонкой настройке», а строку задаёт
        // он: без этой строки человек жмёт выбор и не понимает, почему трей
        // не меняется так, как в предпросмотре ждал (Антон, 10.10.2026).
        customNote = note(L("Строку сейчас задаёт свой формат - он в «Тонкой настройке» ниже. Выбор правит его строку.",
                            "The line is set by a custom format - see Fine-tuning below. The choices edit that line."))
        customNote.isHidden = !Prefs.useCustomTemplate

        return page([
            previewCard,
            customNote,
            sectionTitle(L("Значок", "Icon")), iconCard,
            sectionTitle(L("Что показывать", "What to show")), showCard,
            sectionTitle(L("Ещё в строке", "Also in the line")), extraCard,
            disclosure(L("Тонкая настройка", "Fine-tuning"), barTuning()),
        ])
    }

    // Цвета, пороги, шрифт и свой формат. Нужны редко, а места занимали
    // половину прежнего окна - поэтому свёрнуты.
    private func barTuning() -> NSView {
        let colorTip = L("Пусто - системный цвет. Можно словом (red, orange) или кодом (#ff3b30).",
                         "Empty means system colour. A word (red, orange) or a hex code (#ff3b30).")
        let colors = fieldRow([
            field(L("спокойно", "calm"), "colorCalm", Prefs.colorCalm, width: 80),
            field(L("внимание", "warning"), "colorWarn", Prefs.colorWarn, width: 80),
            field(L("тревога", "alarm"), "colorAlarm", Prefs.colorAlarm, width: 80),
        ])
        colors.toolTip = colorTip
        let worry = fieldRow([
            field(L("внимание с, %", "warn at, %"), "warnAt", "\(Prefs.warnAt)", width: 40),
            field(L("тревога с, %", "alarm at, %"), "alertAt", "\(Prefs.alertAt)", width: 40),
        ])
        worry.toolTip = L("Меняют цвет строки и значка. Это наша выдумка на случай, когда сервер молчит: если в ответе есть severity, слушаем его.",
                          "These change the colour of the line and the icon. Our own guess for when the server says nothing: if the response carries severity, we follow it.")
        let font = fieldRow([
            field(L("размер", "size"), "fontSize", "\(Prefs.fontSize)", width: 40),
            combo(L("шрифт", "font"), "fontName", Prefs.fontName, Presets.fontName, width: 200),
        ])
        font.toolTip = L("Пусто - системный моноширинный. Размер от 9 до 20. В две строки размер берётся от высоты строки меню.",
                         "Empty means the system monospaced font. Size 9 to 20. Two lines take their size from the menu bar height.")

        customToggle = NSButton(checkboxWithTitle: L("Свой формат вместо выбора выше",
                                                     "Custom format instead of the choices above"),
                                target: self, action: #selector(toggleCustom))
        customToggle.state = Prefs.useCustomTemplate ? .on : .off
        customToggle.toolTip = L("Выбор выше добавляет и убирает куски этой строки. Пока свой формат выключен, она просто повторяет выбор; включил - и правь готовое.",
                                 "The choices above add and remove pieces of this line. While custom format is off it mirrors them; switch it on and edit what is there.")
        // Список готовых форматов, но поле редактируемое: чаще всего человек
        // открывает список не чтобы сменить вид, а чтобы подсмотреть, как
        // вообще выглядит правильная строка.
        let templateBox = NSComboBox()
        templateBox.isEditable = true
        templateBox.completes = false
        templateBox.addItems(withObjectValues: Presets.templates)
        templateBox.numberOfVisibleItems = 6
        templateField = templateBox
        templateField.stringValue = Prefs.customTemplate
        templateField.delegate = self
        templateField.identifier = NSUserInterfaceItemIdentifier("customTemplate")
        templateField.isEnabled = Prefs.useCustomTemplate
        templateField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        templateField.translatesAutoresizingMaskIntoConstraints = false
        templateField.widthAnchor.constraint(equalToConstant: 440).isActive = true
        templateField.toolTip = L("Макросы: {icon} {5h} {5h.left} {5h.reset} {7d} {7d.left} {7d.reset} {worst} {active} {models} {opus} {sonnet} {fable} {haiku} {extra} {extra.pct} {money} {tokens} {sessions}. {br} - перенос на вторую строку.",
                                  "Macros: {icon} {5h} {5h.left} {5h.reset} {7d} {7d.left} {7d.reset} {worst} {active} {models} {opus} {sonnet} {fable} {haiku} {extra} {extra.pct} {money} {tokens} {sessions}. {br} - break to a second line.")
        let rebuild = NSButton(title: L("Собрать заново из выбора", "Rebuild from the choices"),
                               target: self, action: #selector(rebuildTemplate))
        rebuild.bezelStyle = .rounded
        rebuild.controlSize = .small

        return CardView([
            subheader(L("Цвета трёх уровней", "Colours of the three levels")), colors,
            subheader(L("Когда тревожиться", "When to worry")), worry,
            subheader(L("Шрифт строки", "Line font")), font,
            separator(),
            customToggle, templateField, rebuild,
            note(L("{br} в своём формате переносит остальное на вторую строку.",
                   "{br} in a custom format moves the rest to a second line.")),
        ])
    }

    private func iconTile(_ style: Prefs.IconStyle, _ title: String, _ image: NSImage) -> NSButton {
        let b = NSButton(title: title, image: image, target: self, action: #selector(iconPicked(_:)))
        b.imagePosition = .imageAbove
        // Нажатие без залипания: выбранную плитку отмечает рамка. Залипшая
        // кнопка заливается цветом акцента, и значок цвета текста на ней
        // пропадает - снимок 1.22.0 показал это на кольце.
        b.setButtonType(.momentaryPushIn)
        b.bezelStyle = .regularSquare
        b.identifier = NSUserInterfaceItemIdentifier("icon:" + style.rawValue)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 112).isActive = true
        b.heightAnchor.constraint(equalToConstant: 58).isActive = true
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        return b
    }

    private func markIconTiles() {
        let current = "icon:" + Prefs.iconStyle.rawValue
        for b in iconTiles {
            let on = b.identifier?.rawValue == current
            b.layer?.borderWidth = on ? 2 : 0
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        glyphRow.isHidden = Prefs.iconStyle != .glyph
    }

    @objc private func iconPicked(_ sender: NSButton) {
        let raw = String((sender.identifier?.rawValue ?? "icon:none").dropFirst(5))
        let style = Prefs.IconStyle(rawValue: raw) ?? .none
        // Кольцо или знак - не кусок строки, а то, чем рисовать {icon}:
        // ставится до того, как значок добавят в строку.
        if style != .none { Prefs.barRing = style == .ring }
        setFlag("showIcon", style != .none)
        markIconTiles()
    }

    @objc private func linesPicked(_ sender: NSSegmentedControl) {
        let five = sender.isSelected(forSegment: 0)
        let week = sender.isSelected(forSegment: 1)
        if five != Prefs.showSession { setFlag("showSession", five) }
        if week != Prefs.showWeekly { setFlag("showWeekly", week) }
    }

    @objc private func resetPicked(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard i >= 0 && i < Prefs.ResetStyle.allCases.count else { return }
        let style = Prefs.ResetStyle.allCases[i]
        Prefs.resetStyle = style
        if Prefs.useCustomTemplate {
            // В своём формате время меняется у тех окон, что уже стоят:
            // строку собирал человек, и новых кусков выбор не добавляет.
            let t = TemplateEdit.setResetStyle(style, in: templateField.stringValue)
            templateField.stringValue = t
            Prefs.customTemplate = t
        } else {
            mirrorTemplate()
        }
        applied()
    }

    // MARK: - Вкладка «Меню»

    private func menuPage() -> NSView {
        cardsSeg = NSSegmentedControl(labels: [L("Карточки", "Cards"), L("Строки", "Rows")],
                                      trackingMode: .selectOne,
                                      target: self, action: #selector(cardsPicked(_:)))
        cardsSeg.selectedSegment = Prefs.menuCards ? 0 : 1
        cardsSeg.toolTip = L("Карточки: заголовок, полоса, сброс, темп. Строки ниже ростом.",
                             "Cards: title, bar, reset, pace. Rows are shorter.")
        let capsule = check("menuCapsule", L("Шкала полоской, а не знаками", "Draw the bar, not glyphs"),
                            Prefs.menuCapsule)
        capsule.toolTip = L("Знаки остаются там, где картинки не бывает, - в терминальном отчёте.",
                            "Glyphs stay where there are no pictures - in the terminal report.")
        let menuFont = fieldRow([
            field(L("размер шрифта", "font size"), "menuFontSize", "\(Prefs.menuFontSize)", width: 40),
        ])
        let viewCard = CardView([line(L("Вид", "Style"), cardsSeg), separator(), capsule, menuFont])

        let moneyTip = L("Деньги и токены - измеренный расход, а не доля лимита: сколько выдано по подписке, Anthropic не публикует. Считается по расшифровкам видимых машин - работаешь ещё и на сервере, добавь его на вкладке «Машины», иначе цифры занижены в разы.",
                         "Money and tokens are measured usage, not a share of a limit - Anthropic publishes no plan size. Counted from transcripts of the machines the app can see: add your server on the Machines tab or the numbers are off by multiples.")
        let money = check("showMoney", L("Деньги по прайсу API", "Money at API prices"), Prefs.showMoney)
        money.toolTip = moneyTip
        let tokens = check("showTokens", L("Токены за окно", "Tokens this window"), Prefs.showTokens)
        tokens.toolTip = moneyTip
        let history = check("showHistory", L("История и темп", "History and pace"), Prefs.showHistory)
        history.toolTip = L("Столбики отвечают на «это много или как обычно», прогноз - на «упрусь ли раньше, чем сбросится»: он считается по своим же замерам процента.",
                            "Bars answer \"is this a lot or a normal day\"; the forecast - \"will I hit the wall before the reset\", from our own percentage samples.")
        let activity = check("showActivity", L("Над чем сессия работает", "What a session works on"),
                             Prefs.showActivity)
        activity.toolTip = L("Последний запрос человека в строке сессии. Это содержание работы - видно через плечо и на демонстрации экрана.",
                             "The last prompt in the session line. That is the content of the work - visible over the shoulder and in screen sharing.")
        let chats = check("showSpendByChat", L("Куда ушло за неделю: темы чатов", "Where the week went: chat topics"),
                          Prefs.showSpendByChat)
        chats.toolTip = activity.toolTip
        let sectionsCard = CardView([
            money, tokens, history,
            check("showSessions", L("Кто работает и кто ждёт", "Who is working and who waits"), Prefs.showSessions),
            check("watchLoops", L("Ловить кручение на месте", "Catch sessions looping"), Prefs.watchLoops),
            activity, chats,
            check("codexEnabled", L("Codex: лимиты, если он стоит", "Codex: limits, if installed"), Prefs.codexEnabled),
        ])

        let barGlyphs = fieldRow([
            combo(L("шкала", "bar"), "barFilled", Prefs.barFilled, Presets.barFilled, width: 150),
            combo(L("фон", "empty"), "barEmpty", Prefs.barEmpty, Presets.barEmpty, width: 150),
            field(L("длина", "width"), "barWidth", "\(Prefs.barWidth)", width: 40),
        ])
        barGlyphs.toolTip = L("Знаки шкалы и её длина от 4 до 40. Пока шкала рисуется полоской, знаки работают только в терминальном отчёте.",
                              "Bar glyphs and width 4 to 40. While the bar is drawn, glyphs only apply to the terminal report.")

        return page([
            sectionTitle(L("Вид меню", "Menu style")), viewCard,
            sectionTitle(L("Разделы", "Sections")), sectionsCard,
            note(L("Деньги, токены и разделы ниже живут только в меню: в строку трея они не попадают.",
                   "Money, tokens and the sections live in the menu only: they never go to the menu bar line.")),
            disclosure(L("Шкала знаками", "Glyph bar"), CardView([barGlyphs])),
        ])
    }

    @objc private func cardsPicked(_ sender: NSSegmentedControl) {
        Prefs.menuCards = sender.selectedSegment == 0
        applied()
    }

    // MARK: - Вкладка «Уведомления»

    private func notifyPage() -> NSView {
        // Плашка не прячется, а пустеет: скрытый вид стопка снимает с себя
        // вместе с ограничениями, и после показа он терял бы ширину.
        bannerHolder = NSStackView()
        bannerHolder.orientation = .vertical
        bannerHolder.alignment = .leading

        rulesStack = NSStackView()
        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 6
        addRuleButton = NSButton(title: L("+ Добавить правило", "+ Add rule"),
                                 target: self, action: #selector(addRule))
        addRuleButton.bezelStyle = .rounded
        addRuleButton.controlSize = .small
        let rulesCard = CardView([rulesStack, addRuleButton])

        let reset = check("notifyReset",
                          L("Сказать, когда лимит, в который упёрся, сбросится",
                            "Tell me when a limit I hit has reset"),
                          Prefs.notifyReset)
        reset.toolTip = L("Приходит на время сброса и только по лимиту, который сработал по правилу. Если держит другой лимит - не приходит.",
                          "Comes at the reset time and only for a limit that triggered a rule. Not sent while another limit still holds.")
        let loops = check("notifyLoops",
                          L("Сессия крутится на месте", "A session is looping"),
                          Prefs.notifyLoops)
        loops.toolTip = L("Три одинаковых вызова за 5 минут при одинаковом выводе. На своей истории - одна тревога на сотню сессий.",
                          "Three identical calls in 5 minutes with the same output. On our history - one alarm per hundred sessions.")

        return page([
            bannerHolder,
            sectionTitle(L("Правила", "Rules")), rulesCard,
            note(L("Каждое правило - один раз на окно лимита; после сброса взводится заново.",
                   "Each rule fires once per limit window and re-arms after the reset.")),
            sectionTitle(L("Ещё", "Also")), CardView([reset, loops]),
        ])
    }

    private func buildRules() {
        rules = Prefs.notifyRules
        for v in rulesStack.arrangedSubviews { v.removeFromSuperview() }
        for (i, r) in rules.enumerated() {
            let row = ruleRow(i, r)
            rulesStack.addArrangedSubview(row)
            // Во всю ширину: кнопка «убрать» у всех правил стоит в одном столбце.
            row.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true
        }
        if rules.isEmpty {
            rulesStack.addArrangedSubview(note(L("Правил нет - о лимитах climits молчит.",
                                                 "No rules - climits stays silent about limits.")))
        }
        addRuleButton.isEnabled = rules.count < NotifyRules.maxRules
    }

    private func ruleRow(_ i: Int, _ r: NotifyRule) -> NSView {
        let on = NSButton(checkboxWithTitle: L("Когда", "When"), target: self,
                          action: #selector(ruleToggled(_:)))
        on.state = r.on ? .on : .off
        on.tag = i
        let scope = NSPopUpButton()
        scope.addItems(withTitles: NotifyRule.Scope.allCases.map { NotifyRules.title($0) })
        scope.selectItem(at: NotifyRule.Scope.allCases.firstIndex(of: r.scope) ?? 0)
        scope.tag = i
        scope.target = self
        scope.action = #selector(ruleScopeChanged(_:))
        let over = NSTextField(labelWithString: L("превышает", "goes over"))
        let at = NSTextField(string: "\(r.at)")
        at.tag = i
        at.identifier = NSUserInterfaceItemIdentifier("ruleAt")
        at.delegate = self
        at.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        at.translatesAutoresizingMaskIntoConstraints = false
        at.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let pct = NSTextField(labelWithString: "%")
        let del = NSButton(title: "\u{2212}", target: self, action: #selector(ruleRemoved(_:)))
        del.bezelStyle = .rounded
        del.controlSize = .small
        del.tag = i
        del.toolTip = L("Убрать правило", "Remove the rule")
        let row = NSStackView(views: [on, scope, over, at, pct, filler(), del])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func saveRules(rebuild: Bool) {
        Prefs.notifyRules = rules
        // Не осталось ни одного включённого - поставленные на будущее
        // «лимит снова есть» тоже не должны прийти (ревью 24.09.2026).
        if !rules.contains(where: { $0.on }) { Notifier.cancelResets() }
        if rebuild { buildRules() }
        applied()
    }

    // Включили правило - самый честный момент спросить разрешение: человек
    // только что сказал, что уведомления ему нужны. На старте приложения
    // разрешение обычно не дают.
    private func askIfUnknown() {
        Notifier.permission { [weak self] p in
            guard p == .unknown else { return }
            Notifier.askPermission { _ in self?.refreshBanner() }
        }
    }

    @objc private func ruleToggled(_ sender: NSButton) {
        guard sender.tag < rules.count else { return }
        rules[sender.tag].on = sender.state == .on
        saveRules(rebuild: false)
        if sender.state == .on { askIfUnknown() }
    }

    @objc private func ruleScopeChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard sender.tag < rules.count, i >= 0, i < NotifyRule.Scope.allCases.count else { return }
        rules[sender.tag].scope = NotifyRule.Scope.allCases[i]
        saveRules(rebuild: false)
    }

    @objc private func ruleRemoved(_ sender: NSButton) {
        guard sender.tag < rules.count else { return }
        rules.remove(at: sender.tag)
        saveRules(rebuild: true)
    }

    @objc private func addRule() {
        guard rules.count < NotifyRules.maxRules else { return }
        // Новое правило - на неделю: самый частый второй порог. Поменять
        // лимит - один выбор в списке.
        rules.append(NotifyRule(scope: .week, at: 90, on: true))
        saveRules(rebuild: true)
        askIfUnknown()
    }

    // Плашка сверху вкладки, пока macOS не даёт показывать уведомления.
    // Без неё правило «включено», а уведомление не приходит никогда, и
    // отличить это от «порог не пройден» нечем.
    private func refreshBanner() {
        guard bannerHolder != nil else { return }
        Notifier.permission { [weak self] p in
            guard let self = self else { return }
            for v in self.bannerHolder.arrangedSubviews { v.removeFromSuperview() }
            switch p {
            case .allowed:
                return
            case .denied:
                self.showBanner(self.banner(
                    L("Уведомления выключены в macOS", "Notifications are off in macOS"),
                    L("Правила ниже не сработают, пока уведомления climits не включить в Системных настройках.",
                      "The rules below won't fire until climits notifications are allowed in System Settings."),
                    L("Открыть настройки", "Open Settings"), #selector(self.openNotifySettings)))
            case .unknown:
                self.showBanner(self.banner(
                    L("Уведомления ещё не разрешены", "Notifications are not allowed yet"),
                    L("macOS спросит один раз. Без разрешения правила ниже молчат.",
                      "macOS asks once. Without permission the rules below stay silent."),
                    L("Разрешить", "Allow"), #selector(self.askPermission)))
            }
        }
    }

    private func showBanner(_ b: NSView) {
        bannerHolder.addArrangedSubview(b)
        b.widthAnchor.constraint(equalTo: bannerHolder.widthAnchor).isActive = true
    }

    private func banner(_ title: String, _ text: String, _ button: String, _ action: Selector) -> NSView {
        let t = NSTextField(labelWithString: "\u{26A0}\u{FE0E} " + title)
        t.font = NSFont.boldSystemFont(ofSize: 13)
        let b = NSButton(title: button, target: self, action: action)
        b.bezelStyle = .rounded
        let head = NSStackView(views: [t, filler(), b])
        head.orientation = .horizontal
        head.spacing = 8
        return CardView([head, note(text)], tint: .systemOrange)
    }

    @objc private func openNotifySettings() {
        Notifier.openSystemSettings()
    }

    @objc private func askPermission() {
        Notifier.askPermission { [weak self] _ in self?.refreshBanner() }
    }

    // MARK: - Вкладка «Машины»

    private func machinesPage() -> NSView {
        // Выпадающий список, а не пустое поле: адрес не набирается по памяти,
        // а выбирается из того, что человек уже настроил в ~/.ssh/config.
        remoteField = NSComboBox()
        remoteField.isEditable = true
        remoteField.completes = true
        remoteField.addItems(withObjectValues: SSHConfig.hosts())
        remoteField.stringValue = Prefs.remoteHosts
        remoteField.delegate = self
        remoteField.identifier = NSUserInterfaceItemIdentifier("remoteHosts")
        remoteField.placeholderString = L("vps7, vps8 - имена из ~/.ssh/config или user@адрес",
                                          "a Host from ~/.ssh/config, or user@address")
        remoteField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        remoteField.translatesAutoresizingMaskIntoConstraints = false
        remoteField.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let known = SSHConfig.hosts()
        let hostsTip = L("Машин можно несколько - через запятую. Каталог расшифровок - вторым словом после адреса, если он не ~/.claude/projects: vps8 ~/work/.claude/projects. Нужен ssh-ключ без пароля и один заход из терминала, чтобы хост попал в known_hosts.",
                                "Several machines are fine - comma-separated. A transcripts folder goes as a second word when it is not ~/.claude/projects. You need a passwordless key and one terminal login so the host lands in known_hosts.")
        let knownTip = known.isEmpty ? ""
            : "\n" + L("Из ~/.ssh/config: ", "From ~/.ssh/config: ") + known.prefix(8).joined(separator: ", ")
        remoteField.toolTip = hostsTip + knownTip
        let checkBtn = NSButton(title: L("Проверить", "Test"), target: self, action: #selector(testRemote))
        checkBtn.bezelStyle = .rounded
        checkBtn.controlSize = .small
        let hostRow = NSStackView(views: [remoteField, checkBtn])
        hostRow.orientation = .horizontal
        hostRow.spacing = 8

        remoteResult = NSTextField(labelWithString: "")
        remoteResult.font = NSFont.systemFont(ofSize: 10)
        remoteResult.textColor = .secondaryLabelColor
        remoteResult.usesSingleLineMode = false
        remoteResult.maximumNumberOfLines = 0
        remoteResult.preferredMaxLayoutWidth = 470
        // Пустая строка ответа занимала бы место до первой проверки.
        remoteResult.isHidden = true

        let hostsCard = CardView([
            hostRow, remoteResult,
            note(L("Лимит у аккаунта один, а расшифровки у каждой машины свои: без этих адресов деньги и токены занижены.",
                   "The account has one limit, but each machine keeps its own transcripts: without these, money and tokens are understated.")),
        ])

        loadStack = NSStackView()
        loadStack.orientation = .vertical
        loadStack.alignment = .leading
        loadStack.spacing = 4
        let loadCard = CardView([
            loadStack,
            note(L("Снятая машина уходит из раздела сессий целиком. Деньги и токены по ней считаются, как раньше.",
                   "An unticked machine leaves the sessions section entirely. Its money and tokens still count.")),
        ])

        let roots = field(L("пути", "paths"), "extraRoots",
                          Prefs.extraRoots.replacingOccurrences(of: "\n", with: " "), width: 330)
        roots.toolTip = L("Второй аккаунт со своим CLAUDE_CONFIG_DIR пишет расшифровки мимо ~/.claude/projects. Несколько - через пробел, вида ~/work/.claude/projects.",
                          "A second account with its own CLAUDE_CONFIG_DIR writes transcripts outside ~/.claude/projects. Several - space-separated, like ~/work/.claude/projects.")

        return page([
            sectionTitle(L("Другие машины по ssh", "Other machines over ssh")), hostsCard,
            sectionTitle(L("Машины в разделе сессий", "Machines in the sessions section")), loadCard,
            sectionTitle(L("Ещё каталоги на этой машине", "More folders on this machine")), CardView([roots]),
        ])
    }

    // Галочки машин - по тем же именам, что у групп в разделе сессий: своя
    // машина под своим именем, удалённые - ярлыком или хостом.
    private func buildLoadToggles() {
        for v in loadStack.arrangedSubviews { v.removeFromSuperview() }
        let hidden = Prefs.hiddenMachines()
        let own = Sessions.localName()
        var items: [(key: String, title: String)] = [
            ("", own.isEmpty ? L("эта машина", "this machine") : own + L(" - эта машина", " - this machine")),
        ]
        for t in Prefs.remoteTargets() {
            let shown = t.label.isEmpty ? SSHConfig.label(for: t.host) : t.label
            if !items.contains(where: { $0.key == shown }) { items.append((shown, shown)) }
        }
        for it in items {
            let b = NSButton(checkboxWithTitle: it.title, target: self, action: #selector(loadToggled(_:)))
            b.state = hidden.contains(it.key) ? .off : .on
            b.identifier = NSUserInterfaceItemIdentifier("load:" + it.key)
            loadStack.addArrangedSubview(b)
        }
    }

    @objc private func loadToggled(_ sender: NSButton) {
        let key = String((sender.identifier?.rawValue ?? "load:").dropFirst(5))
        Prefs.setMachineHidden(key, sender.state != .on)
        applied()
    }

    // MARK: - Вкладка «Основные»

    private func generalPage() -> NSView {
        intervalPopup = NSPopUpButton()
        intervalPopup.addItems(withTitles: intervals.map { $0.0 })
        if Prefs.adaptiveRefresh {
            intervalPopup.selectItem(at: 0)
        } else if let idx = intervals.firstIndex(where: { $0.1 == Prefs.refreshInterval }) {
            intervalPopup.selectItem(at: idx)
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(changeInterval)
        intervalPopup.toolTip = L("Чаще раза в минуту эндпоинт отвечает 429 - это его защита, не наша.",
                                  "More often than once a minute the endpoint answers 429 - its protection, not ours.")

        loginToggle = NSButton(checkboxWithTitle: L("Запускать при входе в систему", "Launch at login"),
                               target: self, action: #selector(toggleLogin))
        loginToggle.state = LaunchAtLogin.isEnabled ? .on : .off

        let status = check("showServiceStatus",
                           L("Статус Anthropic: точка на значке во время сбоя",
                             "Anthropic status: a dot on the icon during an incident"),
                           Prefs.showServiceStatus)
        status.toolTip = L("Фиолетовая точка - «это у них, а не у тебя». Только по claude.ai, Claude Code и API.",
                           "A purple dot - \"it's them, not you\". Only for claude.ai, Claude Code and the API.")
        let privacy = check("privacyMode",
                            L("Скрыть личное: чаты номерами, без запросов", "Hide personal info: chats as numbers, no prompts"),
                            Prefs.privacyMode)
        privacy.toolTip = L("Для показа экрана. Переключается и из самого меню.",
                            "For screen sharing. Also toggled from the menu itself.")
        let sparkle = check("sparkleEnabled", L("Обновляться через Sparkle", "Update via Sparkle"),
                            Prefs.sparkleEnabled)
        sparkle.toolTip = L("Выключить - запасной выход, если Sparkle однажды начнёт мешать: обновление пойдёт через GitHub.",
                            "Turning it off is the way out if Sparkle ever gets in the way: updates go via GitHub.")

        return page([
            sectionTitle(L("Поведение", "Behaviour")),
            CardView([line(L("Обновлять", "Refresh"), intervalPopup), separator(),
                      loginToggle, status, privacy]),
            sectionTitle(L("Обновления", "Updates")), CardView([sparkle]),
        ])
    }

    // MARK: - Детали вёрстки

    // Страница вкладки: прокрутка с перевёрнутым документом и стопкой
    // карточек. Карточки растягиваются на всю ширину, остальное - по себе.
    private func page(_ items: [NSView]) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Фон рисует само окно: с прозрачной прокруткой тёмная тема
        // остаётся тёмной без отдельной настройки цвета.
        scroll.drawsBackground = false

        // Документ прокрутки перевёрнут: у обычной NSView начало координат
        // внизу, и содержимое прижималось бы к нижнему краю.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            // Ширина документа равна ширине видимой области: без этого текст
            // не переносится, а уезжает вправо.
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
            // Ширина содержимого - не больше 640 и по центру: на растянутом
            // окне контрол уезжал к правому краю, за полэкрана от подписи
            // (снимок 1.22.0 на ширине 1400).
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            stack.widthAnchor.constraint(lessThanOrEqualTo: doc.widthAnchor, constant: -40),
        ])
        // Ниже 500 - приоритета, с которым окно держит свой размер: при 750
        // это ограничение вместе с пределом 640 само сжимало окно до 680
        // (снимок 1.22.0, растянутое окно).
        let fill = stack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -40)
        fill.priority = NSLayoutConstraint.Priority(490)
        fill.isActive = true
        for v in items {
            stack.addArrangedSubview(v)
            if v is CardView || v is NSStackView {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return scroll
    }

    private func sectionTitle(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 13)
        return t
    }

    private func subheader(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    // Строка пояснения - одна, мелко. Длинное живёт в подсказке контрола.
    private func note(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        // Без этого многострочная подпись показывает первую строку и
        // многоточие, а без предела ширины - растягивает окно под себя.
        t.usesSingleLineMode = false
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 0
        t.preferredMaxLayoutWidth = 470
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 470).isActive = true
        return t
    }

    // Ряд «подпись слева, контрол справа», необязательная строка под подписью.
    private func line(_ title: String, _ control: NSView, note text: String? = nil) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = NSFont.systemFont(ofSize: 13)
        var left: NSView = t
        if let text = text {
            let n = NSTextField(labelWithString: text)
            n.font = NSFont.systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            let v = NSStackView(views: [t, n])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 1
            left = v
        }
        let row = NSStackView(views: [left, filler(), control])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // Пустышка, которая забирает лишнюю ширину ряда: без неё горизонтальный
    // стек раздаёт её между элементами, и ряд разъезжается по краям.
    private func filler() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }

    // Свёрнутый раздел: треугольник и подпись, под ними содержимое.
    private func disclosure(_ title: String, _ content: NSView) -> NSView {
        let btn = NSButton(title: "", target: self, action: #selector(toggleDisclosure(_:)))
        btn.bezelStyle = .disclosure
        btn.setButtonType(.onOff)
        btn.state = .off
        btn.tag = disclosed.count
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        let head = NSStackView(views: [btn, label])
        head.orientation = .horizontal
        head.spacing = 4
        let v = NSStackView(views: [head])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        disclosed.append((content, v, btn))
        return v
    }

    // Раскрытие ДОБАВЛЯЕТ содержимое в стопку, сворачивание - убирает, а не
    // прячет. Скрытый вид стопка отцепляет от себя в свой проход вёрстки
    // и снимает его ограничения, а возвращает тоже не сразу: ширина,
    // поставленная после «показать», могла бы встать на вид без родителя
    // (ревью правки 10.10.2026). Добавленный вид родителя имеет сразу, а
    // убранный уносит свои ограничения с собой - копиться им негде.
    @objc private func toggleDisclosure(_ sender: NSButton) {
        guard sender.tag < disclosed.count else { return }
        let d = disclosed[sender.tag]
        if sender.state == .on {
            guard d.content.superview == nil else { return }
            d.holder.addArrangedSubview(d.content)
            d.content.widthAnchor.constraint(equalTo: d.holder.widthAnchor).isActive = true
        } else {
            d.holder.removeArrangedSubview(d.content)
            d.content.removeFromSuperview()
        }
    }

    // Версия и адрес репозитория вместо поля User-Agent.
    //
    // Поле убрано намеренно: менять то, чем приложение представляется, полезно
    // ровно в одном редком случае - когда эндпоинт упёрся в 429, - а стоит
    // оно строки в окне и вопроса «а что сюда писать». Запасной выход остался:
    //     defaults write com.babko.climits userAgent "..."
    private func versionLine() -> NSView {
        let t = NSTextField(labelWithString: "")
        let s = NSMutableAttributedString(
            string: "climits \(Prefs.appVersion) \u{00B7} ",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: "github.com/BabkoED/climits", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .link: Prefs.repoURL,
        ]))
        t.attributedStringValue = s
        t.isSelectable = true
        t.allowsEditingTextAttributes = true   // без этого ссылка не нажимается
        return t
    }

    // Компактное поле с подписью слева. Всё оформление настраивается
    // текстом: цвет можно задать и словом («red»), и кодом («#ff3b30»).
    private func field(_ label: String, _ key: String, _ value: String, width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        row.addArrangedSubview(l)
        let f = NSTextField()
        f.stringValue = value
        f.delegate = self
        f.identifier = NSUserInterfaceItemIdentifier(key)
        f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.addArrangedSubview(f)
        return row
    }

    // То же поле, но со списком предложенного. Список подсказывает, ЧТО
    // сюда вписывают, а поле остаётся редактируемым.
    private func combo(_ label: String, _ key: String, _ value: String,
                       _ presets: [String], width: CGFloat) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        row.addArrangedSubview(l)
        let b = NSComboBox()
        b.isEditable = true
        // completes = false намеренно: список показывается с пояснением
        // («● - кружок»), и автодополнение дописывало бы это пояснение
        // прямо в поле, то есть в значение.
        b.completes = false
        b.addItems(withObjectValues: presets)
        b.numberOfVisibleItems = 8
        b.stringValue = value
        b.delegate = self
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.addArrangedSubview(b)
        return row
    }

    // Ряд полей с распоркой в конце: без неё на широком окне поля
    // разъезжаются по краям, и один набор читается как четыре разных места.
    private func fieldRow(_ items: [NSView]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        items.forEach { row.addArrangedSubview($0) }
        row.addArrangedSubview(filler())
        return row
    }

    private func check(_ key: String, _ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleCheck(_:)))
        b.state = on ? .on : .off
        b.identifier = NSUserInterfaceItemIdentifier(key)
        checkboxes[key] = b
        return b
    }

    // MARK: - Реакции

    @objc private func toggleCheck(_ sender: NSButton) {
        setFlag(sender.identifier?.rawValue ?? "", sender.state == .on)
    }

    // Одна точка для галочек и для выбора картинкой: значок и строки
    // правят те же ключи, что прежние галочки, и тем же путём.
    private func setFlag(_ key: String, _ on: Bool) {
        switch key {
        case "showIcon": Prefs.showIcon = on
        case "showSessions": Prefs.showSessions = on
        case "watchLoops": Prefs.watchLoops = on
        case "showActivity": Prefs.showActivity = on
        case "showSpendByChat": Prefs.showSpendByChat = on
        case "sparkleEnabled":
            Prefs.sparkleEnabled = on
            // Поднять сразу, а не после перезапуска: галочка, которая
            // «сработает потом», выглядит как неработающая.
            if on { SparkleBridge.shared.startIfEnabled() }
        case "showSession": Prefs.showSession = on
        case "showWeekly": Prefs.showWeekly = on
        case "showModels": Prefs.showModels = on
        case "showExtra": Prefs.showExtra = on
        case "showWorst": Prefs.showWorst = on
        case "showActive": Prefs.showActive = on
        case "showExtraPct": Prefs.showExtraPct = on
        case "showMoney": Prefs.showMoney = on
        case "showTokens": Prefs.showTokens = on
        case "showHistory": Prefs.showHistory = on
        case "notifyReset":
            Prefs.notifyReset = on
            if !on { Notifier.cancelResets() }
            applied(); return
        case "notifyLoops": Prefs.notifyLoops = on; applied(); return
        case "showServiceStatus": Prefs.showServiceStatus = on; applied(); return
        case "privacyMode": Prefs.privacyMode = on; applied(); return
        // Вид шкалы в меню - не кусок строки трея, макроса за ним нет.
        case "menuCapsule": Prefs.menuCapsule = on; applied(); return
        case "codexEnabled":
            Prefs.codexEnabled = on
            if !on { Notifier.cancelResets(prefix: "codex_") }
            applied(); return
        default: break
        }
        // При включённом «своём формате» выбор ДОПОЛНЯЕТ строку, а не
        // заменяет её: человек собирает её как конструктор, и один
        // случайный клик не должен стирать работу.
        if Prefs.useCustomTemplate {
            var t = templateField.stringValue
            let macros = timedMacros(for: key, on: on)
            t = on ? TemplateEdit.add(macros, to: t) : TemplateEdit.remove(macros, from: t)
            // Окна и в своём формате встают друг над другом, как без него.
            if key == "showSession" || key == "showWeekly" {
                t = on ? TemplateEdit.stackWindows(t) : TemplateEdit.dropEmptyBreak(t)
            }
            templateField.stringValue = t
            Prefs.customTemplate = t
            applied()
            return
        }
        // Поле шаблона повторяет выбор, пока свой формат выключен. Иначе
        // человек включает его и видит не то, что у него в трее.
        mirrorTemplate()
        applied()
    }

    // Окно со временем добавляется в свой формат с тем временем, что выбрано
    // в «сбросе», а убирается вместе с любым своим временем.
    private func timedMacros(for key: String, on: Bool) -> [String] {
        let bases = ["showSession": "5h", "showWeekly": "7d", "showWorst": "worst", "showActive": "active"]
        guard let b = bases[key] else { return TemplateEdit.macros(for: key, withLeft: Prefs.showLeft) }
        if !on { return ["{\(b)}", "{\(b).left}", "{\(b).reset}"] }
        switch Prefs.resetStyle {
        case .none: return ["{\(b)}"]
        case .countdown: return ["{\(b)}", "{\(b).left}"]
        case .clock: return ["{\(b)}", "{\(b).reset}"]
        }
    }

    // Выбор мышью из списка не проходит через controlTextDidEndEditing:
    // без этого выбранный адрес виден в поле, но никуда не записан.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // Текст поля ДО выбора - он ещё старый как раз в этот момент. Для
        // списка машин выбранный хост ДОПИСЫВАЕТСЯ к нему (ревью 09.10.2026).
        let before = (notification.object as? NSComboBox)?.stringValue ?? ""
        let base = hostsBase
        // Через главную очередь: в момент уведомления stringValue у поля
        // ещё старый, и записалось бы предыдущее значение.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let box = notification.object as? NSComboBox,
                  let raw = box.objectValueOfSelectedItem as? String else { return }
            // В списке лежит «значение - пояснение». В поле и в настройки
            // идёт только значение: пояснение станет частью шкалы или
            // шаблона и вылезет в строку меню.
            let picked = Presets.value(of: raw)
            let key = box.identifier?.rawValue ?? ""
            if key == "remoteHosts" {
                let start = base ?? (before.trimmingCharacters(in: .whitespaces) == picked
                    ? Prefs.remoteHosts : before)
                let merged = Prefs.addingHost(picked, to: start)
                box.stringValue = merged
                self.remoteResult.stringValue = ""
                self.apply(key: key, value: merged)
                return
            }
            box.stringValue = picked
            self.apply(key: key, value: picked)
        }
    }

    private func mirrorTemplate() {
        guard !Prefs.useCustomTemplate else { return }
        let t = Prefs.defaultTemplateFromCheckboxes()
        templateField.stringValue = t
        Prefs.customTemplate = t
    }

    @objc private func rebuildTemplate() {
        let t = Prefs.defaultTemplateFromCheckboxes()
        templateField.stringValue = t
        Prefs.customTemplate = t
        applied()
    }

    // Проверка удалённых машин: показать, что оттуда реально приехало, по
    // строке на каждую. Молчание про одну из трёх - это молчание про её
    // расход, а он в счёт не войдёт.
    @objc private func testRemote() {
        Prefs.remoteHosts = remoteField.stringValue
        buildLoadToggles()
        remoteResult.isHidden = false
        let targets = Prefs.remoteTargets()
        guard !targets.isEmpty else {
            remoteResult.stringValue = L("список пуст - считаю только эту машину",
                                         "empty - counting this machine only")
            return
        }
        remoteResult.stringValue = L("спрашиваю \(targets.count)\u{2026}",
                                     "asking \(targets.count)\u{2026}")
        let since = Date().addingTimeInterval(-5 * 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            let lock = NSLock()
            let group = DispatchGroup()
            for target in targets {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = RemoteScan.usage(host: target.host, path: target.path,
                                             cutoffs: [since])
                    let line: String
                    switch r {
                    case .success(let a) where !a.windows.isEmpty:
                        let w = a.windows[0]
                        let tt = w.totals
                        let money = MoneyView.make(spent: w.cost, partial: true).spentMarked
                        // Сессии тем же ответом и приехали - значит и
                        // проверка должна про них сказать: «оттуда ничего не
                        // видно» и «оттуда никто не работает» - разные вещи.
                        let ss = Sessions.summary(a.sessions)
                        let tail = ss.total > 0
                            ? L(", сессий \(ss.total)", ", \(ss.total) sessions")
                            : L(", сессий не видно", ", no sessions visible")
                        line = L("\(target.host): \(Fmt.compact(tt.total)) токенов, \(tt.requests) запросов, \(money)\(tail)",
                                 "\(target.host): \(Fmt.compact(tt.total)) tokens, \(tt.requests) requests, \(money)\(tail)")
                    case .success:
                        line = L("\(target.host): ответ пуст", "\(target.host): empty answer")
                    case .failure(let e):
                        line = L("\(target.host): не вышло - \(e.text)",
                                 "\(target.host): failed - \(e.text)")
                    }
                    lock.lock(); lines.append(line); lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                self?.remoteResult.stringValue = lines.sorted().joined(separator: "\n")
            }
        }
    }

    @objc private func toggleCustom() {
        let on = customToggle.state == .on
        Prefs.useCustomTemplate = on
        templateField.isEnabled = on
        customNote.isHidden = !on
        // При первом включении подставляем то, что собрано выбором: человек
        // видит рабочий образец и правит его, а не пустое поле.
        if on && templateField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            templateField.stringValue = Prefs.defaultTemplateFromCheckboxes()
            Prefs.customTemplate = templateField.stringValue
        }
        applied()
    }

    // Эти поля применяются по окончании ввода, а не на каждое нажатие.
    //
    // Иначе, набирая порог 50, человек на мгновение ставит 5 - и получает
    // настоящее уведомление о «пороге», которого не задавал. Адрес машины
    // здесь по той же причине: на каждой букве приложение лезло бы по ssh
    // на несуществующий хост. С цветами и шаблоном наоборот: там живой
    // отклик и есть весь смысл.
    private static let deferredKeys: Set<String> = [
        "barWidth", "fontSize", "menuFontSize", "warnAt", "alertAt", "ruleAt",
        "remoteHosts", "extraRoots",
    ]

    // Открыли выпадающий список машин - запоминаем, к чему дописывать.
    func comboBoxWillPopUp(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox,
              box.identifier?.rawValue == "remoteHosts" else { return }
        hostsBase = box.stringValue
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let key = f.identifier?.rawValue ?? ""
        // Текст правят руками - прежняя точка отсчёта для выбора устарела.
        if key == "remoteHosts" { hostsBase = nil }
        if SettingsWindowController.deferredKeys.contains(key) { return }
        apply(key: key, value: f.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let key = f.identifier?.rawValue ?? ""
        guard SettingsWindowController.deferredKeys.contains(key) else { return }
        if key == "ruleAt" {
            // Порог правила: номер правила - в tag поля.
            guard f.tag < rules.count, let n = Int(f.stringValue.trimmingCharacters(in: .whitespaces)) else {
                if f.tag < rules.count { f.stringValue = "\(rules[f.tag].at)" }
                return
            }
            rules[f.tag].at = NotifyRules.clamp(n)
            f.stringValue = "\(rules[f.tag].at)"
            saveRules(rebuild: false)
            return
        }
        apply(key: key, value: f.stringValue)
    }

    private static let presetKeys: Set<String> = [
        "barFilled", "barEmpty", "iconSet", "fontName", "customTemplate",
    ]

    private func apply(key: String, value raw: String) {
        // Выбор мышью в NSComboBox сначала кладёт в поле показанную строку
        // целиком - «● - кружок», - и только потом приходит уведомление
        // о выборе. Снимаем пояснение здесь, на обоих путях сразу.
        let v = SettingsWindowController.presetKeys.contains(key)
            ? Presets.value(of: raw)
            : raw
        switch key {
        case "remoteHosts":
            Prefs.remoteHosts = v
            buildLoadToggles()
            applied(); return
        // Поле одно, а путей может быть несколько: разделяем пробелом при
        // вводе и храним по строке на путь.
        case "extraRoots":
            Prefs.extraRoots = v.split(separator: " ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            applied(); return
        case "colorCalm":    Prefs.colorCalm = v
        case "colorWarn":    Prefs.colorWarn = v
        case "colorAlarm":   Prefs.colorAlarm = v
        case "barFilled":    Prefs.barFilled = v
        case "barEmpty":     Prefs.barEmpty = v
        case "iconSet":      Prefs.iconSet = v
        case "fontName":     Prefs.fontName = v
        case "barWidth":     if let n = Int(v) { Prefs.barWidth = n }
        case "fontSize":     if let n = Int(v) { Prefs.fontSize = n }
        case "menuFontSize": if let n = Int(v) { Prefs.menuFontSize = n }
        case "warnAt":       if let n = Int(v) { Prefs.warnAt = n }
        case "alertAt":      if let n = Int(v) { Prefs.alertAt = n }
        default:             Prefs.customTemplate = v
        }
        applied()
    }

    @objc private func changeInterval() {
        let idx = intervalPopup.indexOfSelectedItem
        if idx >= 0 && idx < intervals.count {
            let v = intervals[idx].1
            Prefs.adaptiveRefresh = v == 0
            if v > 0 { Prefs.refreshInterval = v }
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
    // Рисуется тем же кодом, что и трей в две строки.
    private func updatePreview() {
        guard previewView != nil else { return }
        let t = Prefs.effectiveTemplate
        let s = SettingsWindowController.sample
        let lines = BarTitle.lines(t, usage: s,
                                   money: SettingsWindowController.sampleMoney,
                                   tokens: SettingsWindowController.sampleTokens,
                                   iconGlyph: "")
        let pct = s.worst?.pct ?? 0
        let icon: BarImage.Icon = !t.contains("{icon}") ? .none
            : (Prefs.barRing ? .ring(pct) : .glyph(Fmt.icon(for: pct)))
        previewView.image = BarImage.image(lines: lines, color: .labelColor, icon: icon,
                                           height: NSStatusBar.system.thickness,
                                           trailing: t.trimmingCharacters(in: .whitespaces).hasSuffix("{icon}"),
                                           titled: BarTitle.isTitled(t))
    }

    static let sampleMoney = MoneyView.make(spent: 12.40, partial: true)
    static let sampleTokens = TokensView(spent: 1_240_000)

    static let sample: Usage = {
        let now = Date()
        let buckets = [
            Bucket(key: "five_hour", short: L("5ч", "5h"), long: L("5-часовое окно", "5-hour window"),
                   percent: 37, resetsAt: now.addingTimeInterval(2 * 3600 + 840), isActive: true, rank: 0, severity: "normal"),
            Bucket(key: "seven_day", short: L("7д", "7d"), long: L("Неделя, всего", "Week, total"),
                   percent: 62, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 1, severity: "normal"),
            Bucket(key: "seven_day_opus", short: "Opus", long: L("Неделя, Opus", "Week, Opus"),
                   percent: 81, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 2, severity: "normal"),
            Bucket(key: "seven_day_sonnet", short: "Sonnet", long: L("Неделя, Sonnet", "Week, Sonnet"),
                   percent: 12, resetsAt: now.addingTimeInterval(3 * 86400), isActive: false, rank: 2, severity: "normal"),
            Bucket(key: UsageParser.fableKey, short: "Fable", long: L("Неделя, Fable", "Week, Fable"),
                   percent: 0, resetsAt: nil, isActive: false, rank: 2, severity: "normal"),
        ]
        let extra = Extra(enabled: true, usedMinor: 13963, limitMinor: 20000,
                          exponent: 2, currency: "USD", percentGiven: nil)
        return Usage(buckets: buckets, extra: extra, fetchedAt: now, isStale: false, rawBody: "{}")
    }()
}

// Перевёрнутая система координат: начало сверху, как в вебе и как ждёт
// прокрутка. У NSView по умолчанию начало внизу.
final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

// Карточка: скруглённая подложка с тонкой рамкой и стопкой рядов внутри.
//
// Своим рисованием, а не NSBox: размер NSBox под Auto Layout от содержимого
// не берётся предсказуемо, а проверить это отсюда нечем. Подложка - цвет
// текста с малой прозрачностью: в светлой теме чуть темнее окна, в тёмной
// чуть светлее, без двух наборов цветов. tint - для плашки-предупреждения.
final class CardView: NSView {
    private let stack = NSStackView()
    private let tint: NSColor?

    init(_ rows: [NSView], tint: NSColor? = nil) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        for r in rows {
            stack.addArrangedSubview(r)
            // Ряды «подпись - контрол» и разделители - во всю ширину
            // карточки: иначе контрол стоит не у правого края, а где
            // кончилась подпись.
            if r is NSBox || r is NSStackView {
                r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (tint?.withAlphaComponent(0.14) ?? NSColor.labelColor.withAlphaComponent(0.035)).setFill()
        path.fill()
        (tint?.withAlphaComponent(0.45) ?? NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // Цвета динамические, но рисуются в draw: смена темы обязана
    // перерисовать карточку, а не оставить подложку прежней темы.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Подложка предпросмотра строки меню - кусочек «строки меню» вокруг картинки.
final class PillView: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
