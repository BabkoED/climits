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
    static var refreshInterval: Int {
        get { int("refreshInterval", 300) } set { d.set(newValue, forKey: "refreshInterval") } }
    // Как представляемся эндпоинту.
    //
    // Есть распространённое мнение, что запросы без User-Agent вида
    // «claude-code/<версия>» попадают в жёстко лимитируемый бакет и ловят
    // постоянный 429. По первоисточникам оно не подтверждается: в issues
    // claude-code про 429 на этом эндпоинте User-Agent не упоминается вовсе.
    // Поэтому по умолчанию представляемся своим именем - честно и проверяемо,
    // а если 429 будет мешать, значение меняется в настройках без пересборки.
    static let defaultUserAgent = "climits/1.0.0 (+https://github.com/BabkoED/climits)"
    static var userAgent: String {
        get {
            let s = (d.string(forKey: "userAgent") ?? "").trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? defaultUserAgent : s
        }
        set { d.set(newValue, forKey: "userAgent") }
    }

    static var warnAt: Int {
        get { int("warnAt", 50) } set { d.set(newValue, forKey: "warnAt") } }
    static var alertAt: Int {
        get { int("alertAt", 80) } set { d.set(newValue, forKey: "alertAt") } }

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
        if showSession { parts.append("{5h}") }
        if showLeft    { parts.append("{5h.left}") }
        if showWeekly  { parts.append(L("7д ", "7d ") + "{7d}") }
        if showModels  { parts.append("{models}") }
        if showExtra   { parts.append("{extra}") }
        var body = parts.joined(separator: " \u{00B7} ")
        if body.isEmpty { body = "{worst}" }   // пустая строка меню бессмысленна
        if showIcon { body = "{icon} " + body }
        return body
    }
}
