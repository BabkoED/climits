import AppKit

// Окно настроек. Свёрстано кодом, без xib и storyboard: приложение собирается
// одним вызовом swiftc, и любой ресурсный файл здесь стал бы лишним поводом
// для сборки развалиться на чужой машине.
final class SettingsWindowController: NSWindowController, NSComboBoxDelegate {

    private var checkboxes: [String: NSButton] = [:]
    private var templateField: NSTextField!
    private var customToggle: NSButton!
    private var previewLabel: NSTextField!
    private var intervalPopup: NSPopUpButton!
    private var loginToggle: NSButton!
    private var remoteField: NSComboBox!
    private var remoteResult: NSTextField!

    private let intervals: [(String, Int)] = [
        (L("каждую минуту", "every minute"), 60),
        (L("раз в 5 минут", "every 5 minutes"), 300),
        (L("раз в 15 минут", "every 15 minutes"), 900),
        (L("раз в 30 минут", "every 30 minutes"), 1800),
    ]

    convenience init() {
        // Высота окна - по экрану, а не по содержимому.
        //
        // Раньше здесь стояло жёсткое 940, и пока настроек было мало, это
        // работало. Настройки выросли, окно упёрлось в низ экрана, и нижняя
        // часть - вторая машина, каталоги, версия - просто оказалась за
        // краем: прокрутки не было, размер окна не менялся. Выглядело это
        // не как «не влезло», а как «этого в приложении нет».
        //
        // На макбуке с его 900 точками по высоте вычесть надо ощутимо:
        // строка меню сверху, док снизу, заголовок окна. visibleFrame это
        // уже учитывает, но запас всё равно нужен - окно, впритык равное
        // видимой области, ставится под самый край.
        let maxHeight: CGFloat = 940
        let available = (NSScreen.main?.visibleFrame.height ?? maxHeight) - 60
        let height = max(400, min(maxHeight, available))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = L("Настройки climits", "climits settings")
        // Ниже этого окно становится бесполезным: подвал с версией съедает
        // низ, а на прокрутку остаётся полоска в две строки.
        w.minSize = NSSize(width: 520, height: 320)
        w.center()
        self.init(window: w)
        build()
    }

    private func build() {
        guard let content = window?.contentView else { return }

        // Версия и ссылка прибиты к низу окна и НЕ прокручиваются.
        //
        // Внутри прокрутки они были бы честной строкой, до которой никто
        // не долистывает: версия нужна ровно в тот момент, когда что-то
        // пошло не так и надо сказать какую. Место под ней - самое дешёвое
        // в окне, а найти её здесь можно не читая остального.
        let footer = versionLine()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Фон рисует само окно: с прозрачной прокруткой тёмная тема
        // остаётся тёмной без отдельной настройки цвета.
        scroll.drawsBackground = false
        content.addSubview(scroll)

        // Документ прокрутки перевёрнут: у обычной NSView начало координат
        // внизу, и содержимое прижималось бы к нижнему краю, а прокрутка
        // открывалась бы на конце списка вместо начала.
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
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            // Ширина документа равна ширине видимой области: без этого
            // текст не переносится, а уезжает вправо, и вместо вертикальной
            // прокрутки появляется горизонтальная.
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            // Нижняя граница документа идёт от содержимого - именно она
            // и задаёт высоту прокрутки.
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -20),
        ])

        stack.addArrangedSubview(header(L("Что показывать", "What to show")))

        // Строка формата стоит ПЕРВОЙ, а галочки под ней.
        //
        // Раньше было наоборот, и это был неверный порядок: галочки правят
        // именно эту строку, а править то, чего ещё не видел, невозможно.
        // Сначала показываем результат, потом способы его собрать.
        customToggle = NSButton(checkboxWithTitle: L("Свой формат вместо галочек",
                                                     "Custom format instead of checkboxes"),
                                target: self, action: #selector(toggleCustom))
        customToggle.state = Prefs.useCustomTemplate ? .on : .off
        stack.addArrangedSubview(customToggle)

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
        templateField.widthAnchor.constraint(equalToConstant: 470).isActive = true
        stack.addArrangedSubview(templateField)

        let rebuild = NSButton(title: L("Собрать заново из галочек", "Rebuild from checkboxes"),
                               target: self, action: #selector(rebuildTemplate))
        rebuild.bezelStyle = .rounded
        rebuild.controlSize = .small
        stack.addArrangedSubview(rebuild)
        stack.addArrangedSubview(small(L("Галочки ниже добавляют и убирают куски этой строки. Пока «свой формат» выключен, она просто повторяет галочки; включил - и правь готовое. Пустые куски убираются вместе с разделителем.",
                                         "The checkboxes below add and remove pieces of this line. While custom format is off it simply mirrors them; switch it on and edit what is already there. Empty pieces are dropped along with their separator.")))

        stack.addArrangedSubview(spacer(6))
        stack.addArrangedSubview(checkGrid())
        stack.addArrangedSubview(small(L("Справа - не строка меню, а выпадающее: там места хватает всегда. Деньги и токены - измеренный расход, а не доля лимита: сколько всего выдано по подписке, Anthropic не публикует нигде. Считается по расшифровкам тех машин, которые видит приложение, - работаешь ещё и на сервере, впиши его ниже, иначе цифры занижены в разы.",
                                         "On the right is the dropdown, not the menu bar line: there is always room there. Money and tokens are measured usage, not a share of a limit - Anthropic publishes no plan size anywhere. Counted from transcripts of the machines the app can see: also working on a server, add it below or the numbers are off by multiples.")))
        stack.addArrangedSubview(small(L("Столбики истории отвечают на «это много или как обычно», прогноз - на «упрусь ли раньше, чем сбросится»: он считается по своим же замерам процента, размер лимита для него не нужен.",
                                         "History bars answer \"is this a lot or a normal day\"; the forecast answers \"will I hit the wall before the reset\" - computed from our own percentage samples, no plan size needed.")))
        stack.addArrangedSubview(small(L("Галочками собирается всё, что вообще бывает в строке. Руками в своём формате дописываются только отдельные модели - {opus} {sonnet} {fable} {haiku} - и деньги с токенами, если очень нужны наверху: {money} {tokens}.",
                                         "The checkboxes cover everything the line can hold. Only single models - {opus} {sonnet} {fable} {haiku} - and money or tokens up top, if you really want them, are typed by hand: {money} {tokens}.")))

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

        let notify = NSButton(checkboxWithTitle: L("Уведомлять при достижении порога",
                                                   "Notify when a threshold is reached"),
                              target: self, action: #selector(toggleCheck(_:)))
        notify.state = Prefs.notifyEnabled ? .on : .off
        notify.identifier = NSUserInterfaceItemIdentifier("notifyEnabled")
        checkboxes["notifyEnabled"] = notify
        stack.addArrangedSubview(notify)

        stack.addArrangedSubview(fieldRow([
            field(L("порог уведомления, %", "notify at, %"), "notifyAt", "\(Prefs.notifyAt)", width: 40),
        ]))

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(header(L("Вид", "Appearance")))

        // Три подраздела, и порядок в них не случайный: цвет, потом знаки,
        // потом шрифт, потом пороги. Сначала то, что видно издалека,
        // в конце то, из-за чего цвет меняется.
        stack.addArrangedSubview(subheader(L("Цвета трёх уровней", "Colours of the three levels")))
        stack.addArrangedSubview(fieldRow([
            field(L("спокойно", "calm"), "colorCalm", Prefs.colorCalm, width: 80),
            field(L("внимание", "warning"), "colorWarn", Prefs.colorWarn, width: 80),
            field(L("тревога", "alarm"), "colorAlarm", Prefs.colorAlarm, width: 80),
        ]))
        stack.addArrangedSubview(small(L("Пусто - системный цвет. Можно словом (red, orange) или кодом (#ff3b30).",
                                         "Empty means system colour. A word (red, orange) or a hex code (#ff3b30).")))

        stack.addArrangedSubview(subheader(L("Шкала и кружок", "Bar and dot")))
        // Галочка стоит ПЕРЕД знаками, а не после: она решает, значат ли
        // они что-нибудь в меню вообще. Снятая - возвращает прежний вид
        // из знаков, и тогда «шкала» и «фон» снова правят то, что видно.
        addCheck(stack, "menuCapsule",
                 L("Полоской, а не знаками", "Draw the bar, not glyphs"),
                 Prefs.menuCapsule)
        stack.addArrangedSubview(fieldRow([
            combo(L("шкала", "bar"), "barFilled", Prefs.barFilled, Presets.barFilled, width: 150),
            combo(L("фон", "empty"), "barEmpty", Prefs.barEmpty, Presets.barEmpty, width: 150),
        ]))
        // Та же логика, что у полоски в меню: галочка стоит ПЕРЕД знаками,
        // потому что решает, значат ли они что-нибудь в строке трея.
        // Снятая - возвращает прежние три знака.
        addCheck(stack, "barRing",
                 L("Кружок кольцом, а не знаком", "Draw the dot as a ring"),
                 Prefs.barRing)
        stack.addArrangedSubview(fieldRow([
            combo(L("кружки", "dots"), "iconSet", Prefs.iconSet, Presets.iconSet, width: 190),
            field(L("длина шкалы", "bar width"), "barWidth", "\(Prefs.barWidth)", width: 40),
        ]))
        stack.addArrangedSubview(small(L("Кольцо показывает тот же самый лимит, что и знак - самый нагруженный, - но процентом, а не одной из трёх ступеней. Места в строке занимает столько же. Пока кольцо включено, знаки из списка ниже работают только в терминальном отчёте.",
                                         "The ring shows the same limit the glyph did - the busiest one - but as a percentage instead of one of three steps. It takes the same room in the bar. While the ring is on, the glyphs below only apply to the terminal report.")))
        stack.addArrangedSubview(small(L("Кружки - три знака через запятую: спокойно, внимание, тревога. Длина шкалы - от 4 до 40. Из списка можно выбрать, а можно вписать своё, включая эмодзи. Пока шкала рисуется полоской, «шкала» и «фон» работают только в терминальном отчёте; длина считается в тех же клетках.",
                                         "Dots are three glyphs separated by commas: calm, warning, alarm. Bar width is 4 to 40. Pick from the list or type your own, emoji included. While the bar is drawn, \"bar\" and \"empty\" only apply to the terminal report; the width is counted in the same cells.")))

        // Шрифты и пороги стояли в одном ряду - четыре поля по сорок точек
        // подряд. Читалось как один набор чисел, хотя это разные вещи:
        // шрифт про размер букв, порог про то, когда кружок краснеет.
        // Разведены по рядам и подписаны.
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(subheader(L("Шрифт", "Font")))
        stack.addArrangedSubview(fieldRow([
            field(L("в строке", "in the bar"), "fontSize", "\(Prefs.fontSize)", width: 40),
            field(L("в меню", "in the menu"), "menuFontSize", "\(Prefs.menuFontSize)", width: 40),
            combo(L("имя", "name"), "fontName", Prefs.fontName, Presets.fontName, width: 220),
        ]))
        stack.addArrangedSubview(small(L("Пусто - системный моноширинный. Размер от 9 до 20; за пределами значение зажимается, а не ломается.",
                                         "Empty means the system monospaced font. Size 9 to 20; outside that the value is clamped, not broken.")))

        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(subheader(L("Когда тревожиться", "When to worry")))
        stack.addArrangedSubview(fieldRow([
            field(L("внимание с, %", "warn at, %"), "warnAt", "\(Prefs.warnAt)", width: 40),
            field(L("тревога с, %", "alarm at, %"), "alertAt", "\(Prefs.alertAt)", width: 40),
        ]))
        stack.addArrangedSubview(small(L("Меняют цвет строки и кружка. Это наша выдумка на случай, когда сервер молчит: если в ответе есть severity, слушаем его - тот, кто считает лимит, знает о нём больше нас.",
                                         "These change the colour of the line and the dot. They are our own guess for when the server says nothing: if the response carries severity, we follow it - whoever counts the limit knows more about it than we do.")))

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(header(L("Вторая машина", "Second machine")))
        stack.addArrangedSubview(small(L("Лимит у аккаунта один, а расшифровки лежат на каждой машине свои. Если работа идёт ещё и по ssh, без этого адреса деньги и токены занижены в разы.",
                                         "The account has one limit, but transcripts live on each machine separately. If you also work over ssh, money and tokens are understated several-fold without this.")))

        let remoteRow = NSStackView()
        remoteRow.orientation = .horizontal
        remoteRow.spacing = 8
        // Выпадающий список, а не пустое поле: адрес не набирается по памяти,
        // а выбирается из того, что человек уже настроил в ~/.ssh/config.
        // Опечатка в адресе - самая обидная из возможных ошибок здесь:
        // выглядит как «не работает», а на деле просто буква не та.
        remoteField = NSComboBox()
        remoteField.isEditable = true
        remoteField.completes = true
        remoteField.addItems(withObjectValues: SSHConfig.hosts())
        remoteField.stringValue = Prefs.remoteHost
        remoteField.delegate = self
        remoteField.identifier = NSUserInterfaceItemIdentifier("remoteHost")
        remoteField.placeholderString = L("имя из ~/.ssh/config или user@адрес",
                                          "a Host from ~/.ssh/config, or user@address")
        remoteField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        remoteField.translatesAutoresizingMaskIntoConstraints = false
        remoteField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        remoteRow.addArrangedSubview(remoteField)
        let checkBtn = NSButton(title: L("Проверить", "Test"), target: self,
                                action: #selector(testRemote))
        checkBtn.bezelStyle = .rounded
        checkBtn.controlSize = .small
        remoteRow.addArrangedSubview(checkBtn)
        stack.addArrangedSubview(remoteRow)

        remoteResult = NSTextField(labelWithString: "")
        remoteResult.font = NSFont.systemFont(ofSize: 10)
        remoteResult.textColor = .secondaryLabelColor
        stack.addArrangedSubview(remoteResult)
        let known = SSHConfig.hosts()
        stack.addArrangedSubview(small(known.isEmpty
            ? L("В ~/.ssh/config записей нет - впиши адрес целиком, вида user@адрес.",
                "No entries in ~/.ssh/config - type the full address, user@host.")
            : L("Из ~/.ssh/config: \(known.prefix(8).joined(separator: ", ")).",
                "From ~/.ssh/config: \(known.prefix(8).joined(separator: ", ")).")))
        stack.addArrangedSubview(small(L("Пароль спросить негде: нужен ключ без пароля и один заход из терминала, чтобы хост попал в known_hosts.",
                                         "There is nowhere to ask for a password: you need a key and one terminal login so the host lands in known_hosts.")))

        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(header(L("Ещё каталоги на этой машине", "More folders on this machine")))
        stack.addArrangedSubview(small(L("Второй аккаунт со своим CLAUDE_CONFIG_DIR пишет расшифровки мимо ~/.claude/projects. Лимит при этом общий, а расход мы видели только домашний. По одному пути в строке.",
                                         "A second account with its own CLAUDE_CONFIG_DIR writes transcripts outside ~/.claude/projects. The limit is shared, but we only saw the home folder. One path per line.")))
        stack.addArrangedSubview(field(L("пути", "paths"), "extraRoots",
                                       Prefs.extraRoots.replacingOccurrences(of: "\n", with: " "),
                                       width: 300))
        stack.addArrangedSubview(small(L("Несколько - через пробел. Вида ~/work/.claude/projects.",
                                         "Several - separated by spaces. Like ~/work/.claude/projects.")))

        // Версия живёт в подвале окна, вне прокрутки - см. build().
        stack.addArrangedSubview(spacer(4))

        updatePreview()
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
    // текстом: цвет можно задать и словом («red»), и кодом («#ff3b30»),
    // знак шкалы - любым символом, включая эмодзи.
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
    // сюда вписывают, а поле остаётся редактируемым - своё значение никто
    // не запрещает.
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

    // Ряд полей. В конце ряда - распорка, и это здесь главное.
    //
    // Без неё горизонтальный стек раздаёт лишнюю ширину между своими
    // элементами: пока окно узкое, поля стоят рядом, а на широком окне
    // первое поле прижимается влево, остальные улетают вправо, и ряд
    // «шрифт строки 13 ... шрифт меню 12 внимание с 50 тревога с 80»
    // читается как четыре разных места, а не один набор.
    //
    // Ровно эта же болезнь была у таблицы макросов и лечится тем же:
    // пустышка цепляется за ширину слабее всех, весь избыток достаётся ей.
    private func fieldRow(_ items: [NSView]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        items.forEach { row.addArrangedSubview($0) }
        let filler = NSView()
        filler.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        filler.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                       for: .horizontal)
        row.addArrangedSubview(filler)
        return row
    }

    // --- элементы -----------------------------------------------------------
    private func header(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 13)
        return t
    }
    // Галочки в два столбца, слева строка меню, справа выпадающее.
    //
    // Столбцы разделены по смыслу, а не пополам по счёту: слева то, что
    // борется за три-четыре знака в строке наверху, справа то, для чего
    // места хватает всегда. Раньше все девять шли одним списком, и разница
    // между «попадёт в строку» и «не попадёт никогда» держалась на подписи
    // мелким шрифтом под ними.
    //
    // Здесь же раньше стояла таблица имён макросов - «{icon}», «{5h}» -
    // кнопками. Убрана: коды нужны тому, кто пишет формат руками, а таких
    // случаев один на сотню, и ради него восемнадцать строк занимали пол-окна.
    // Кому надо - имена перечислены строкой под галочками.
    private func checkGrid() -> NSView {
        // Порядок сверху вниз - как в самой строке меню: кружок, окно,
        // время, неделя, потом то, что добавляют реже. Так галочка стоит
        // там, где человек ждёт увидеть её кусок в результате.
        let left: [(String, String, Bool)] = [
            ("showIcon", L("Кружок загрузки", "Load dot"), Prefs.showIcon),
            ("showSession", L("Процент текущего окна", "Current window percent"), Prefs.showSession),
            ("showLeft", L("Сколько до сброса", "Time until reset"), Prefs.showLeft),
            ("showResetClock", L("Часы сброса: пн 03:00", "Reset clock: Mon 03:00"), Prefs.showResetClock),
            ("showWeekly", L("Недельный кап", "Weekly cap"), Prefs.showWeekly),
            ("showWorst", L("Самый нагруженный лимит", "The busiest limit"), Prefs.showWorst),
            ("showActive", L("Что упрётся первым", "What hits first"), Prefs.showActive),
            ("showModels", L("Лимиты по моделям", "Per-model limits"), Prefs.showModels),
            ("showExtra", L("Потрачено сверх лимита", "Extra usage spent"), Prefs.showExtra),
            ("showExtraPct", L("Сверх лимита, процент", "Extra usage, percent"), Prefs.showExtraPct),
        ]
        let right: [(String, String, Bool)] = [
            ("showMoney", L("Деньги по прайсу API", "Money at API prices"), Prefs.showMoney),
            ("showTokens", L("Токены за окно", "Tokens this window"), Prefs.showTokens),
            ("showHistory", L("История и темп", "History and pace"), Prefs.showHistory),
            ("showSessions", L("Кто работает и кто ждёт", "Who is working and who waits"),
             Prefs.showSessions),
        ]

        var rows: [[NSView]] = [[subheader(L("В строке меню", "In the menu bar")),
                                 subheader(L("В выпадающем меню", "In the dropdown"))]]
        for i in 0..<max(left.count, right.count) {
            let a: NSView = i < left.count ? makeCheck(left[i].0, left[i].1, left[i].2) : NSView()
            let b: NSView = i < right.count ? makeCheck(right[i].0, right[i].1, right[i].2) : NSView()
            rows.append([a, b])
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 3
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).leadingPadding = 28
        // Та же распорка, что и везде: без неё таблица растягивается на всю
        // ширину окна и второй столбец улетает к правому краю.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        let holder = NSStackView()
        holder.orientation = .horizontal
        holder.spacing = 0
        holder.addArrangedSubview(grid)
        let filler = NSView()
        filler.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        filler.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                       for: .horizontal)
        holder.addArrangedSubview(filler)
        return holder
    }

    private func subheader(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.boldSystemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }

    private func small(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: 10)
        t.textColor = .secondaryLabelColor
        // Многострочная подпись без этого показывает первую строку и
        // многоточие: у метки по умолчанию одна строка.
        t.usesSingleLineMode = false
        t.lineBreakMode = .byWordWrapping
        t.maximumNumberOfLines = 0
        // Ширина, ПОСЛЕ которой текст переносится.
        //
        // Без неё «переносится» не значит ничего: собственная ширина метки -
        // это вся строка в одну линию, и раз она больше окна, окно под неё
        // и растягивается. Проверено снимком из CI: окно шириной 560 стало
        // шириной 1240, а самая длинная подпись всё равно не влезла и
        // обрезалась по краю.
        //
        // 500 - это 560 окна минус отступы по 20 с каждой стороны и запас
        // на полосу прокрутки.
        t.preferredMaxLayoutWidth = 500
        t.widthAnchor.constraint(lessThanOrEqualToConstant: 500).isActive = true
        return t
    }
    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }
    private func makeCheck(_ key: String, _ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleCheck(_:)))
        b.state = on ? .on : .off
        b.identifier = NSUserInterfaceItemIdentifier(key)
        checkboxes[key] = b
        return b
    }

    private func addCheck(_ stack: NSStackView, _ key: String, _ title: String, _ on: Bool) {
        stack.addArrangedSubview(makeCheck(key, title, on))
    }

    // --- реакции ------------------------------------------------------------
    @objc private func toggleCheck(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.identifier?.rawValue ?? "" {
        case "showIcon": Prefs.showIcon = on
        case "barRing": Prefs.barRing = on
        case "showSessions": Prefs.showSessions = on
        case "showSession": Prefs.showSession = on
        case "showLeft": Prefs.showLeft = on
        case "showWeekly": Prefs.showWeekly = on
        case "showModels": Prefs.showModels = on
        case "showExtra": Prefs.showExtra = on
        case "showWorst": Prefs.showWorst = on
        case "showActive": Prefs.showActive = on
        case "showResetClock": Prefs.showResetClock = on
        case "showExtraPct": Prefs.showExtraPct = on
        case "showMoney": Prefs.showMoney = on
        case "showTokens": Prefs.showTokens = on
        case "showHistory": Prefs.showHistory = on
        case "notifyEnabled": Prefs.notifyEnabled = on; applied(); return
        // Вид шкалы в меню - не кусок строки трея, макроса за ним нет.
        // Уходим сразу, не заглядывая в шаблон: иначе галочка «вида»
        // прошла бы через сборку строки меню и потрогала её ни за чем.
        case "menuCapsule": Prefs.menuCapsule = on; applied(); return
        default: break
        }
        // При включённом «своём формате» галочка ДОПОЛНЯЕТ строку, а не
        // заменяет её.
        //
        // Раньше здесь стояло обратное: любая галочка выключала свой формат
        // и затирала написанное. Логика была «раз жмёт галочки - значит
        // хочет быстрый выбор». На деле человек собирает строку как
        // конструктор: галочками добавляет куски, руками правит порядок,
        // и один случайный клик стирал всю работу.
        if Prefs.useCustomTemplate {
            let key = sender.identifier?.rawValue ?? ""
            var t = templateField.stringValue
            if key == "showLeft" {
                // «Сколько до сброса» - не свой макрос, а добавка к чужим:
                // отдельно от процента время в строке ни о чём не говорит.
                // Поэтому добавляем и убираем его у тех окон, что уже есть.
                for base in ["{5h}", "{7d}"] where t.contains(base) {
                    let left = String(base.dropLast()) + ".left}"
                    t = on ? TemplateEdit.add([base, left], to: t)
                           : TemplateEdit.remove([left], from: t)
                }
            } else {
                let macros = TemplateEdit.macros(for: key, withLeft: Prefs.showLeft)
                t = on ? TemplateEdit.add(macros, to: t)
                       : TemplateEdit.remove(macros, from: t)
            }
            templateField.stringValue = t
            Prefs.customTemplate = t
            applied()
            return
        }
        // Поле шаблона повторяет галочки, пока свой формат выключен. Иначе
        // человек включает его и видит либо пустоту, либо то, что собиралось
        // галочками неделю назад, - и правит не то, что у него в трее.
        mirrorTemplate()
        applied()
    }

    // Выбор мышью из списка не проходит через controlTextDidEndEditing:
    // без этого выбранный адрес виден в поле, но никуда не записан.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // Через главную очередь: в момент уведомления stringValue у поля
        // ещё старый, и записалось бы предыдущее значение.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let box = notification.object as? NSComboBox,
                  let raw = box.objectValueOfSelectedItem as? String else { return }
            // В списке лежит «значение - пояснение». В поле и в настройки
            // идёт только значение: пояснение туда попасть не должно ни
            // при каких обстоятельствах - оно станет частью шкалы или
            // шаблона и вылезет в строку меню.
            let picked = Presets.value(of: raw)
            box.stringValue = picked
            let key = box.identifier?.rawValue ?? ""
            if key == "remoteHost" { self.remoteResult.stringValue = "" }
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

    // Проверка второй машины: показать, что оттуда реально приехало. Без
    // этого настройка проверяется только тем, что цифры в меню «как будто
    // побольше стали».
    @objc private func testRemote() {
        let host = remoteField.stringValue.trimmingCharacters(in: .whitespaces)
        Prefs.remoteHost = host
        guard !host.isEmpty else {
            remoteResult.stringValue = L("адрес пуст - считаю только эту машину",
                                         "empty - counting this machine only")
            return
        }
        remoteResult.stringValue = L("спрашиваю \(host)\u{2026}", "asking \(host)\u{2026}")
        let path = Prefs.remotePath
        let since = Date().addingTimeInterval(-5 * 3600)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = RemoteScan.usage(host: host, path: path, cutoffs: [since])
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .success(let windows) where !windows.isEmpty:
                    let w = windows[0]
                    let t = w.totals
                    self.remoteResult.stringValue = L(
                        "за 5 часов оттуда: \(Fmt.compact(t.total)) токенов, \(t.requests) запросов, \u{2248}\(MoneyView.money(w.cost))",
                        "last 5 hours there: \(Fmt.compact(t.total)) tokens, \(t.requests) requests, \u{2248}\(MoneyView.money(w.cost))")
                case .success:
                    self.remoteResult.stringValue = L("ответ пуст", "empty answer")
                case .failure(let e):
                    self.remoteResult.stringValue = L("не вышло: \(e.text)", "failed: \(e.text)")
                }
            }
        }
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

    // Эти поля применяются по окончании ввода, а не на каждое нажатие.
    //
    // Иначе, набирая порог 50, человек на мгновение ставит 5 - и получает
    // настоящее уведомление о «пороге», которого не задавал. Адрес второй
    // машины здесь по той же причине: на каждой букве приложение лезло бы
    // по ssh на несуществующий хост. С цветами и шаблоном наоборот: там
    // живой отклик и есть весь смысл.
    private static let deferredKeys: Set<String> = [
        "barWidth", "fontSize", "menuFontSize", "warnAt", "alertAt", "notifyAt",
        // Адрес машины и пути к каталогам - только по окончании ввода:
        // на каждой букве приложение обходило бы полпути к несуществующему
        // каталогу и лезло по ssh на несуществующий хост.
        "remoteHost", "extraRoots",
    ]

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let key = f.identifier?.rawValue ?? ""
        if SettingsWindowController.deferredKeys.contains(key) { return }
        apply(key: key, value: f.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField else { return }
        let key = f.identifier?.rawValue ?? ""
        guard SettingsWindowController.deferredKeys.contains(key) else { return }
        apply(key: key, value: f.stringValue)
    }

    private static let presetKeys: Set<String> = [
        "barFilled", "barEmpty", "iconSet", "fontName", "customTemplate",
    ]

    private func apply(key: String, value raw: String) {
        // Выбор мышью в NSComboBox сначала кладёт в поле показанную строку
        // целиком - «● - кружок», - и только потом приходит уведомление
        // о выборе. Если снять пояснение только там, то в промежутке
        // в настройках успевает полежать «● - кружок», и предпросмотр
        // моргает мусором. Снимаем здесь, на обоих путях сразу.
        let v = SettingsWindowController.presetKeys.contains(key)
            ? Presets.value(of: raw)
            : raw
        switch key {
        case "remoteHost":   Prefs.remoteHost = v; applied(); return
        // Поле одно, а путей может быть несколько: разделяем пробелом при
        // вводе и храним по строке на путь. Пробел в самом пути тогда
        // невозможен - но каталог расшифровок с пробелом в имени против
        // читаемого поля не стоит ничего.
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
        case "notifyAt":     if let n = Int(v) { Prefs.notifyAt = n }
        default:             Prefs.customTemplate = v
        }
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
        // С деньгами: иначе галочка «Деньги» на предпросмотр не влияет вовсе,
        // и человек решает, что она сломана.
        previewLabel.stringValue = BarTitle.render(Prefs.effectiveTemplate,
                                                   usage: SettingsWindowController.sample,
                                                   money: SettingsWindowController.sampleMoney,
                                                   tokens: SettingsWindowController.sampleTokens)
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
