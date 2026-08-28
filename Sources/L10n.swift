import Foundation

// Язык интерфейса берётся из системы: русский, если система русская, иначе
// английский. Отдельного переключателя нет намеренно - лишняя настройка,
// которая всегда расходится с системной.
//
// Почему словарь, а не .strings/NSLocalizedString: приложение собирается
// одним вызовом swiftc, без Xcode-проекта и без .lproj-каталогов в бандле.
// Таблица в коде переживает любую сборку и не может «потеряться» при копировании.
enum Lang {
    case ru, en

    static let current: Lang = {
        for code in Locale.preferredLanguages {
            let low = code.lowercased()
            if low.hasPrefix("ru") { return .ru }
            if low.hasPrefix("en") { return .en }
        }
        return .en
    }()
}

func L(_ ru: String, _ en: String) -> String {
    return Lang.current == .ru ? ru : en
}

// Короткие названия дней недели для строки «сброс пн 03:00».
func weekdayShort(_ index: Int) -> String {
    let ru = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
    let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let list = Lang.current == .ru ? ru : en
    let i = max(1, min(7, index)) - 1
    return list[i]
}
