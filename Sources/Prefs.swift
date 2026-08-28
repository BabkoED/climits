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
    static let d = UserDefaults.standard

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
    static var showTokens: Bool {
        get { bool("showTokens", false) } set { d.set(newValue, forKey: "showTokens") } }

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
    // с настоящей ровно в тот момент, когда её забыли обновить.
    static var appVersion: String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
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
    static var remoteHost: String {
        get { str("remoteHost", "").trimmingCharacters(in: .whitespaces) }
        set { d.set(newValue, forKey: "remoteHost") } }
    // Каталог расшифровок на той машине. Пусто - «~/.claude/projects».
    static var remotePath: String {
        get { str("remotePath", "").trimmingCharacters(in: .whitespaces) }
        set { d.set(newValue, forKey: "remotePath") } }

    // --- деньги, уведомления, вид строк ---
    //
    // Деньги выключены по умолчанию намеренно: это оценка по локальным
    // расшифровкам, и включать её без объяснения значит показать человеку
    // цифру, которую он примет за счёт.
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
    static var barWidth: Int {
        get { max(4, min(40, int("barWidth", 14))) } set { d.set(newValue, forKey: "barWidth") } }

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
        if showWeekly  { parts.append(showLeft ? "{7d} {7d.left}" : "{7d}") }
        if showModels  { parts.append("{models}") }
        if showExtra   { parts.append("{extra}") }
        // Деньги и токены сюда НЕ попадают, даже когда обе галочки включены.
        //
        // У остальных галочек одно значение на обе поверхности: включил
        // «Лимиты по моделям» - строки моделей появились и в трее, и в
        // раскрывающемся меню, потому что меню показывает вообще все buckets
        // всегда, а трей - только то, что в шаблоне. Деньги и токены особые:
        // их вычисление стоит дорого (обход расшифровок), поэтому у них
        // ОДНА галочка на «считать и показывать в меню», и она не значит
        // «значит показывать и в трее» - там всегда мало места, а сумма
        // и пара токенов только сталкивают другие макросы за край строки.
        // Нужны в трее - дописываются вручную через «свой формат»: {money}
        // и {tokens} там работают точно так же, галочка ничего не блокирует.
        var body = parts.joined(separator: " \u{00B7} ")
        if body.isEmpty { body = "{worst}" }   // пустая строка меню бессмысленна
        if showIcon { body = "{icon} " + body }
        return body
    }
}
