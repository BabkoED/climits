import Foundation

// Настройки. Всё лежит в стандартном UserDefaults приложения, то есть в
// ~/Library/Preferences/com.babko.climits.plist - править можно и руками
// через `defaults write com.babko.climits ...`, если так удобнее.
//
// Строка меню настраивается двумя способами сразу, и это сделано намеренно:
//   * галочки - для тех, кому нужно «показывай процент и деньги»;
//   * шаблон  - для тех, кто хочет точный порядок и свои подписи.
// Галочки просто собирают тот же самый шаблон. Один механизм внутри, два
// входа снаружи: расхождения между ними невозможны по построению.
struct Prefs {
    static let bundleID = "com.babko.climits"

    // СВОЙ бандл, даже когда бинарник позвали через ссылку из ~/bin.
    //
    // Поймано на живой машине 07.09.2026. `--install-cli` кладёт в ~/bin
    // ссылку на бинарник внутри бандла, и при запуске через неё
    // `Bundle.main` наш бандл НЕ опознаёт. Следствий три, и все тихие:
    //   * версия падала в «dev» - отчёт врал про самого себя;
    //   * `UserDefaults.standard` брал ДРУГОЙ домен, то есть все настройки
    //     читались значениями по умолчанию. `--doctor` показывал «Sparkle
    //     выключен» при включённой галочке, а `--short` для statusline
    //     собирал строку по чужому шаблону, а не по настроенному;
    //   * `Version.isNewer` на «dev» всегда false - обновления из
    //     терминала не находились бы вовсе.
    // Видно это стало только теперь: до сих пор имя в ~/bin занимал
    // старый скрипт, и ссылку никто не запускал.
    //
    // Путь бинарника разрешается от ссылок и от него поднимаемся к .app:
    // .../climits.app/Contents/MacOS/climits -> .../climits.app
    static let ownBundle: Bundle = {
        if Bundle.main.bundleIdentifier == bundleID { return Bundle.main }
        let raw = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
        guard !raw.isEmpty else { return Bundle.main }
        let app = URL(fileURLWithPath: raw)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // climits.app
        guard app.pathExtension == "app",
              let b = Bundle(url: app),
              b.bundleIdentifier == bundleID
        else { return Bundle.main }
        return b
    }()

    // Настройки читаются из домена приложения по ИМЕНИ, а не через
    // Bundle.main. Подмена включается только когда Bundle.main - не мы:
    // у графического запуска всё остаётся как было, то есть настройки
    // человека этой правкой не могут пострадать по построению.
    static let d: UserDefaults = {
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }()

    static func bool(_ key: String, _ def: Bool) -> Bool {
        return d.object(forKey: key) as? Bool ?? def
    }
    static func int(_ key: String, _ def: Int) -> Int {
        return d.object(forKey: key) as? Int ?? def
    }

    // --- что показывать в строке меню (быстрый выбор) ---
    static var showIcon: Bool {
        get { bool("showIcon", true) } set { d.set(newValue, forKey: "showIcon") } }
    static var showSession: Bool {
        get { bool("showSession", true) } set { d.set(newValue, forKey: "showSession") } }
    static var showLeft: Bool {
        get { bool("showLeft", true) } set { d.set(newValue, forKey: "showLeft") } }
    static var showWeekly: Bool {
        get { bool("showWeekly", false) } set { d.set(newValue, forKey: "showWeekly") } }
    static var showModels: Bool {
        get { bool("showModels", false) } set { d.set(newValue, forKey: "showModels") } }
    static var showExtra: Bool {
        get { bool("showExtra", true) } set { d.set(newValue, forKey: "showExtra") } }

    // --- то, что раньше было доступно только через свой формат ------------
    //
    // Эти четыре куска существовали макросами и вписывались руками. Галочек
    // у них не было по одной причине: их придумывали позже остальных, когда
    // список галочек уже казался длинным. На деле «доступно, если знаешь имя
    // и впишешь его сам» - это не доступно: имя надо где-то увидеть, а
    // увидеть его было негде, кроме README.
    static var showWorst: Bool {
        get { bool("showWorst", false) } set { d.set(newValue, forKey: "showWorst") } }
    static var showActive: Bool {
        get { bool("showActive", false) } set { d.set(newValue, forKey: "showActive") } }
    // Часы сброса - «пн 03:00». Отвечает не на «сколько осталось», а на
    // «попадёт сброс на рабочий день или на выходной», и это разные вопросы:
    // «через 4д 2ч» второго не говорит.
    static var showResetClock: Bool {
        get { bool("showResetClock", false) } set { d.set(newValue, forKey: "showResetClock") } }
    static var showExtraPct: Bool {
        get { bool("showExtraPct", false) } set { d.set(newValue, forKey: "showExtraPct") } }
    static var showTokens: Bool {
        get { bool("showTokens", false) } set { d.set(newValue, forKey: "showTokens") } }

    // Спарклайн за неделю, «сегодня» и темп - в выпадающем меню.
    // Выключено по умолчанию по той же причине, что деньги: считается это
    // обходом расшифровок, а обход стоит десятки мегабайт чтения.
    static var showHistory: Bool {
        get { bool("showHistory", false) } set { d.set(newValue, forKey: "showHistory") } }

    // --- свой формат ---
    static var useCustomTemplate: Bool {
        get { bool("useCustomTemplate", false) } set { d.set(newValue, forKey: "useCustomTemplate") } }
    static var customTemplate: String {
        get { d.string(forKey: "customTemplate") ?? defaultTemplateFromCheckboxes() }
        set { d.set(newValue, forKey: "customTemplate") } }

    // --- поведение ---
    // 300 секунд: чаще нет смысла - цифры всё равно кэшируются, а частый
    // опрос этого эндпоинта приводит к HTTP 429. Проверено на живом трее:
    // раз в минуту хватало, чтобы поймать 429 за час.
    // Зажат, как и остальные. Без границ было два исхода, и оба тихие:
    // 0 -> таймер с нулевым интервалом, порядка десяти тысяч срабатываний
    // в секунду на главном потоке, строка меню встаёт. Огромное значение ->
    // кэш всегда считается свежим, приложение показывает годовалые цифры
    // БЕЗ пометки «~», потому что на этой ветке isStale ставится false
    // и суточный потолок не применяется.
    static var refreshInterval: Int {
        get { max(60, min(3600, int("refreshInterval", 300))) }
        set { d.set(newValue, forKey: "refreshInterval") } }
    // Как представляемся эндпоинту.
    //
    // Есть распространённое мнение, что запросы без User-Agent вида
    // «claude-code/<версия>» попадают в жёстко лимитируемый бакет и ловят
    // постоянный 429. По первоисточникам оно не подтверждается: в issues
    // claude-code про 429 на этом эндпоинте User-Agent не упоминается вовсе.
    // Поэтому по умолчанию представляемся своим именем - честно и проверяемо,
    // а если 429 будет мешать, значение меняется в настройках без пересборки.
    // Версия берётся из бандла, а не пишется здесь строкой: иначе она
    // расходится с настоящей ровно в тот момент, когда её забыли обновить.
    static let repoURL = "https://github.com/BabkoED/climits"
    // Версия берётся из бандла, а не пишется строкой: иначе она расходится
    // с настоящей ровно в тот момент, когда её забыли обновить. Из СВОЕГО
    // бандла, а не из Bundle.main: через ссылку из ~/bin второй не
    // опознаётся, и отчёт печатал «dev» про выпущенную сборку.
    static var appVersion: String {
        return ownBundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static var defaultUserAgent: String {
        return "climits/\(appVersion) (macOS; +\(repoURL))"
    }
    static var userAgent: String {
        get {
            let s = (d.string(forKey: "userAgent") ?? "").trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? defaultUserAgent : s
        }
        set { d.set(newValue, forKey: "userAgent") }
    }

    // --- вторая машина ---
    //
    // Проценты лимита сервер считает по всему аккаунту, а расшифровки лежат
    // на каждой машине свои. Если работа идёт ещё и по ssh на сервере, то
    // локальный счёт видит меньшую часть расхода - и деньги, и токены
    // занижаются молча, в разы. Здесь адрес второй машины: приложение
    // считает её расшифровки тем же способом и складывает с местными.
    //
    // Пусто - считаем только себя, как раньше.
    //
    // МАШИН МОЖЕТ БЫТЬ НЕСКОЛЬКО (слово Антона 07.09.2026). Раньше здесь
    // была одна строка, и «вторая машина» сидела допущением в четырёх
    // местах: в настройке, в счётчике машин, в подписи «по расшифровкам
    // двух машин» и в единственной переменной под ошибку.
    //
    // Формат: адреса через запятую ИЛИ по одному в строке, необязательный
    // каталог вторым словом после адреса.
    //
    //     vps7, vps8
    //     vps8 ~/work/.claude/projects
    //
    // Два разделителя, потому что вводов тоже два. В окне настроек стоит
    // NSComboBox - он однострочный, но зато подсказывает хосты из
    // ~/.ssh/config, и терять подсказку ради второго разделителя глупо:
    // там пишут через запятую. А `defaults write` и правка plist руками
    // естественнее многострочными, как у extraRoots рядом.
    //
    // Пробел разделяет адрес и каталог, а не двоеточие: двоеточие
    // встречается и в адресах, и в путях, а пробел в имени хоста ssh
    // невозможен.
    //
    static var remoteHosts: String {
        get {
            let list = str("remoteHosts", "")
            // Переход со старой настройки. Пока человек не тронул новую,
            // работает прежняя: молча потерять настроенный сервер нельзя.
            if list.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let one = str("remoteHost", "").trimmingCharacters(in: .whitespaces)
                if !one.isEmpty {
                    let p = str("remotePath", "").trimmingCharacters(in: .whitespaces)
                    return p.isEmpty ? one : one + " " + p
                }
            }
            return list
        }
        set { d.set(newValue, forKey: "remoteHosts") } }

    // Разобранный список: адрес и каталог. Пустые строки и повторы
    // отбрасываются - один и тот же сервер, вписанный дважды, удвоил бы
    // его расход в деньгах, и заметить это было бы нечем.
    static func remoteTargets() -> [(host: String, path: String, label: String)] {
        var out: [(host: String, path: String, label: String)] = []
        var seen = Set<String>()
        for raw in remoteHosts.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
            let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard var h = parts.first.map(String.init), !h.isEmpty else { continue }

            // ЯРЛЫК ЧЕРЕЗ РАВНО: «vps7=51.38.110.54».
            //
            // Нужен на случай, когда в ~/.ssh/config записи нет, а голый
            // IP в каждой строке занимает тринадцать знаков. Автоматика
            // из ssh config закрывает обычный случай, это - остальные,
            // и человеку не приходится править конфиг ssh ради трея.
            //
            // Знак равенства выбран потому, что в адресах его не бывает
            // вовсе: ни в имени хоста, ни в IP, ни в «user@host».
            var label = ""
            if let eq = h.firstIndex(of: "=") {
                label = String(h[h.startIndex..<eq])
                h = String(h[h.index(after: eq)...])
            }
            guard !h.isEmpty, seen.insert(h).inserted else { continue }
            let path = parts.count > 1 ? String(parts[1]) : ""
            out.append((h, path, label))
        }
        return out
    }

    // Прежние ключи остались читаемыми: ими пользуется переход выше и
    // окно настроек, когда список ещё не заполнен.
    static var remoteHost: String {
        get { remoteTargets().first?.host ?? "" }
        set { d.set(newValue, forKey: "remoteHost") } }
    static var remotePath: String {
        get { str("remotePath", "").trimmingCharacters(in: .whitespaces) }
        set { d.set(newValue, forKey: "remotePath") } }

    // Ещё каталоги расшифровок на ЭТОЙ машине, по одному в строке.
    //
    // Второй аккаунт с собственным CLAUDE_CONFIG_DIR - рабочий и личный -
    // пишет расшифровки мимо «~/.claude/projects». Лимит при этом общий,
    // если аккаунт один, а расход мы видели только домашний.
    static var extraRoots: String {
        get { str("extraRoots", "") } set { d.set(newValue, forKey: "extraRoots") } }

    // --- деньги, уведомления, вид строк ---
    //
    // Деньги выключены по умолчанию намеренно: это счёт по прайсу API и
    // только по видимым машинам, и включать его без объяснения значит
    // показать человеку цифру, которую он примет за счёт.
    //
    // 29.08.2026 их пробовали включить и поставить в строку меню первыми.
    // Откачено по слову Антона в тот же день: в трее помещается мало, а
    // процент и время до сброса отвечают на главный вопрос - «работать
    // дальше или подождать». Деньги, токены и история отвечают на другой,
    // и им место в выпадающем меню, а не в строке.
    static var showMoney: Bool {
        get { bool("showMoney", false) } set { d.set(newValue, forKey: "showMoney") } }
    static var notifyEnabled: Bool {
        get { bool("notifyEnabled", false) } set { d.set(newValue, forKey: "notifyEnabled") } }
    static var notifyAt: Int {
        get { max(1, min(100, int("notifyAt", 80))) } set { d.set(newValue, forKey: "notifyAt") } }

    // --- вид ---
    //
    // Всё, что описывает внешность, вынесено в настройки. Значение по
    // умолчанию - пустая строка или ноль, и тогда берётся системное:
    // так опечатка не ломает вид, а просто ничего не меняет.
    static func str(_ key: String, _ def: String) -> String {
        return d.string(forKey: key) ?? def
    }

    static var colorCalm: String {
        get { str("colorCalm", "") } set { d.set(newValue, forKey: "colorCalm") } }
    static var colorWarn: String {
        get { str("colorWarn", "") } set { d.set(newValue, forKey: "colorWarn") } }
    static var colorAlarm: String {
        get { str("colorAlarm", "") } set { d.set(newValue, forKey: "colorAlarm") } }

    static var fontSize: Int {
        get { max(9, min(20, int("fontSize", 13))) } set { d.set(newValue, forKey: "fontSize") } }
    static var menuFontSize: Int {
        get { max(9, min(20, int("menuFontSize", 12))) } set { d.set(newValue, forKey: "menuFontSize") } }
    static var fontName: String {
        get { str("fontName", "") } set { d.set(newValue, forKey: "fontName") } }

    // Шкала: чем рисовать и какой длины.
    static var barFilled: String {
        get { let s = str("barFilled", "\u{2588}"); return s.isEmpty ? "\u{2588}" : s }
        set { d.set(newValue, forKey: "barFilled") } }
    static var barEmpty: String {
        get { let s = str("barEmpty", "\u{2591}"); return s.isEmpty ? "\u{2591}" : s }
        set { d.set(newValue, forKey: "barEmpty") } }
    // Умолчание 10, а не 14 (06.09.2026). Считано tools/menu-width.py:
    // каждая клетка шкалы стоит меню 3.6 pt по ширине, и четыре лишние
    // клетки давали 340 pt при разумных для меню статуса 250-320.
    // Меньше 10 идти не стал: на восьми клетках шаг заливки становится
    // заметно грубым, а выигрыш всего 7 pt. У кого настроено своё
    // значение - оно сохраняется, умолчание на него не влияет.
    static var barWidth: Int {
        get { max(4, min(40, int("barWidth", 10))) } set { d.set(newValue, forKey: "barWidth") } }

    // Чем рисовать шкалу в выпадающем меню: капсулой или знаками.
    //
    // Знаки никуда не делись и остаются единственным вариантом там, где
    // картинки не бывает, - в терминальном отчёте. Настройки «шкала» и
    // «фон» правят именно их, поэтому при включённой капсуле они работают
    // только в терминале, о чём в окне настроек сказано словами.
    static var menuCapsule: Bool {
        get { bool("menuCapsule", true) } set { d.set(newValue, forKey: "menuCapsule") } }

    // Sparkle. ВКЛЮЧЁН по умолчанию с 1.8.6 - проверен целиком на живой
    // машине 07.09.2026: предложил, скачал, проверил подпись и поставил,
    // причём на сборке без сертификата Apple. Выключенным он был ровно
    // до этой проверки, а не «на всякий случай».
    //
    // Галочка остаётся, но теперь она не про выбор пути: путь приложение
    // выбирает само, одной кнопкой. Она про «отключить Sparkle совсем»,
    // если он однажды начнёт мешать на новой macOS, - чтобы выход был
    // и без ожидания новой версии от меня.
    static var sparkleEnabled: Bool {
        get { bool("sparkleEnabled", true) } set { d.set(newValue, forKey: "sparkleEnabled") } }

    // Кружок в строке меню - кольцом, а не знаком. Включено по умолчанию:
    // знак давал три ступени на сто процентов, дуга - непрерывно, и места
    // занимает столько же. Галочка есть, потому что кольцо рисуется
    // картинкой, а знак - знаком: у кого шрифт трея свой и нестандартный,
    // тот вправе вернуть знак.
    static var barRing: Bool {
        get { bool("barRing", true) } set { d.set(newValue, forKey: "barRing") } }

    // Раздел «сессии» в выпадающем меню: кто работает, кто ждёт ответа.
    // Стоит дёшево - несколько маленьких файлов, не обход расшифровок, -
    // поэтому включено. В строку трея это НЕ попадает даже при включённой
    // галочке: там места на «работать или подождать», а не на «не стоит ли
    // агент». Нужно в трее - макрос {sessions} в своём формате.
    static var showSessions: Bool {
        get { bool("showSessions", true) } set { d.set(newValue, forKey: "showSessions") } }

    // Сторож кручения: не повторяет ли сессия одно и то же впустую.
    //
    // ВКЛЮЧЕНО по умолчанию, и вот на каком основании. Реплей по своей
    // истории (286 сессий, 14 329 вызовов, 12.09.2026) дал ТРИ тревоги -
    // одна на сотню сессий, и все три по делу. Фича, которая молчит
    // 99 раз из 100 и не ошибается в сотый, выключенной быть не должна:
    // человек про галочку вспомнит ровно тогда, когда уже потерял час.
    //
    // Стоит это полмегабайта чтения на живую сессию раз в обновление -
    // на порядок меньше обхода расшифровок ради денег, который уже идёт.
    static var watchLoops: Bool {
        get { bool("watchLoops", true) } set { d.set(newValue, forKey: "watchLoops") } }

    // Над чем сессия работает - последний запрос человека в строке.
    //
    // ВЫКЛЮЧЕНО по умолчанию, в отличие от сторожа выше, и причина не в
    // цене. Это единственное место во всём приложении, где на экран
    // попадает СОДЕРЖАНИЕ работы, а не числа о ней: имя мерчанта, сумма,
    // суть задачи. Трей виден через плечо и попадает в демонстрацию
    // экрана целиком. Такое включает человек сам, увидев, что именно
    // там покажется, - а не приложение за него.
    static var showActivity: Bool {
        get { bool("showActivity", false) } set { d.set(newValue, forKey: "showActivity") } }

    // Куда ушли деньги за неделю - по разговорам.
    //
    // ВЫКЛЮЧЕНО по умолчанию по той же причине, что и showActivity:
    // имя разговора - это его тема, то есть содержание работы. Сначала
    // разбивка была по каталогам проектов и содержания не показывала
    // вовсе, но и смысла не имела: 97% недели в одном каталоге, потому
    // что все рабочие сессии идут из одной папки. Выбор был между
    // безобидной пустотой и полезной ценой; взято второе, но под
    // галочкой и с честной подписью.
    static var showSpendByChat: Bool {
        get { bool("showSpendByChat", false) } set { d.set(newValue, forKey: "showSpendByChat") } }

    // Сколько разговоров показываем. Ниже хвост всё равно не читают,
    // а меню растёт вниз без предела. Это же число ограничивает чтение
    // имён: у остальных имя не берётся вовсе.
    static let maxChats = 5

    // Кружок слева: три знака через запятую, от спокойного к тревожному.
    static var iconSet: String {
        get { let s = str("iconSet", "\u{25D4},\u{25D1},\u{25D5}"); return s.isEmpty ? "\u{25D4},\u{25D1},\u{25D5}" : s }
        set { d.set(newValue, forKey: "iconSet") } }

    static var warnAt: Int {
        get { max(1, min(100, int("warnAt", 50))) } set { d.set(newValue, forKey: "warnAt") } }
    static var alertAt: Int {
        get { max(1, min(100, int("alertAt", 80))) } set { d.set(newValue, forKey: "alertAt") } }

    // Итоговый шаблон: либо свой, либо собранный из галочек.
    static var effectiveTemplate: String {
        if useCustomTemplate {
            let t = customTemplate.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return defaultTemplateFromCheckboxes()
    }

    static func defaultTemplateFromCheckboxes() -> String {
        var parts: [String] = []
        // Процент и остаток времени идут одним куском, без разделителя между
        // ними: «57% 5м · 92% 1д3ч» читается как два окна, а «57% · 5м · 92%
        // · 1д3ч» - как четыре числа подряд.
        //
        // Подпись «7д» убрана намеренно: то, что недельный лимит недельный,
        // человек знает и без неё, а место она занимает. Какое окно где,
        // говорит время до сброса - минуты у одного, дни у другого.
        if showSession { parts.append(showLeft ? "{5h} {5h.left}" : "{5h}") }
        // Процент выключили, а время до сброса нужно всё равно - иначе
        // строка вообще перестаёт отвечать на «когда отпустит».
        else if showLeft { parts.append("{5h.left}") }
        // Часы сброса идут сразу за своим окном: «37% 2ч 13м пн 03:00» -
        // это одно место, а не два разных числа.
        if showSession && showResetClock { parts[parts.count - 1] += " {5h.reset}" }
        if showWeekly  { parts.append(showLeft ? "{7d} {7d.left}" : "{7d}") }
        if showWorst   { parts.append(showLeft ? "{worst} {worst.left}" : "{worst}") }
        if showActive {
            var piece = showLeft ? "{active} {active.left}" : "{active}"
            if showResetClock { piece += " {active.reset}" }
            parts.append(piece)
        }
        if showModels  { parts.append("{models}") }
        if showExtra   { parts.append("{extra}") }
        if showExtraPct { parts.append("{extra.pct}") }
        // Деньги, токены и история сюда НЕ попадают, даже когда галочки
        // включены. У остальных галочек одно значение на обе поверхности,
        // у этих - только на выпадающее меню: в трее три-четыре знака
        // места, и занимать их числом, которое не отвечает на «работать
        // дальше или подождать», значит вытолкнуть за край то, которое
        // отвечает. Нужны в трее - дописываются вручную через «свой
        // формат»: {money} и {tokens} там работают, галочка не мешает.
        var body = parts.joined(separator: " \u{00B7} ")
        if body.isEmpty { body = "{worst}" }   // пустая строка меню бессмысленна
        if showIcon { body = "{icon} " + body }
        return body
    }
}
