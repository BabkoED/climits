import Foundation

// Готовые значения для полей вида.
//
// Зачем. Поля «шкала», «фон», «кружки», «имя шрифта» и «свой формат» - это
// свободный текст, и по пустому полю невозможно догадаться, что туда можно
// вписать. Человек видит «шкала: █» и не знает, допустимо ли туда «●», а
// в «кружках» - что это вообще три знака через запятую, а не один.
//
// Поэтому у каждого такого поля список предложенного, но поле остаётся
// редактируемым: выпадающий список даёт понять, ЧТО ждут, а руками можно
// вписать что угодно, включая эмодзи.
//
// Список - пара «значение + пояснение», а показывается одной строкой:
// «● - кружок». Разделитель длинный и с пробелами намеренно: короткое тире
// встречается в самих значениях (например в наборе кружков), и по нему
// строка разъехалась бы.
enum Presets {
    static let separator = "  \u{2014} "

    static func item(_ value: String, _ hint: String) -> String {
        return value + separator + hint
    }

    // Обратно из показанной строки в значение. Человек мог и не выбирать
    // из списка, а вписать своё - тогда вернём то, что он вписал.
    static func value(of item: String) -> String {
        guard let r = item.range(of: separator) else { return item }
        return String(item[item.startIndex..<r.lowerBound])
    }

    static func items(_ pairs: [(String, String)]) -> [String] {
        return pairs.map { item($0.0, $0.1) }
    }

    static var barFilled: [String] {
        return items([
            ("\u{2588}", L("блок", "block")),
            ("\u{2593}", L("блок пореже", "dense shade")),
            ("\u{25A0}", L("квадрат", "square")),
            ("\u{25CF}", L("кружок", "dot")),
            ("\u{2501}", L("линия", "line")),
            ("=", L("равно, для узких шрифтов", "equals, for narrow fonts")),
        ])
    }

    static var barEmpty: [String] {
        return items([
            ("\u{2591}", L("светлый блок", "light shade")),
            ("\u{00B7}", L("точка", "middle dot")),
            ("\u{2500}", L("тонкая линия", "thin line")),
            ("\u{25CB}", L("пустой кружок", "empty dot")),
            (" ", L("пробел - шкала без фона", "space - bar with no track")),
        ])
    }

    // Три знака через запятую: спокойно, внимание, тревога. Именно три -
    // набор из двух или четырёх приложение молча отбросит и возьмёт свой.
    static var iconSet: [String] {
        return items([
            ("\u{25D4},\u{25D1},\u{25D5}", L("четверти круга", "clock quarters")),
            ("\u{25CB},\u{25D1},\u{25CF}", L("от пустого к полному", "empty to full")),
            ("\u{1F7E2},\u{1F7E1},\u{1F534}", L("светофор", "traffic light")),
            ("\u{2581},\u{2584},\u{2588}", L("столбики", "bars")),
            ("\u{00B7},\u{2022},\u{25CF}", L("точки", "dots")),
        ])
    }

    static var fontName: [String] {
        return items([
            ("SF Mono", L("системный от Apple", "Apple system mono")),
            ("Menlo", L("есть на любом маке", "on every Mac")),
            ("Monaco", L("классический", "the classic")),
            ("Courier New", L("узкий", "narrow")),
            ("JetBrains Mono", L("если ставил сам", "if you installed it")),
        ])
    }

    // Формат строки. Первым - то, что собрано из галочек: чаще всего человек
    // открывает этот список, чтобы подсмотреть синтаксис, а не сменить вид.
    static var templates: [String] {
        return items([
            ("{icon} {5h} {5h.left}", L("окно: процент и время", "window: percent and time")),
            ("{icon} {worst}", L("самый нагруженный лимит", "the busiest limit")),
            ("{icon} {5h} {5h.left} \u{00B7} {7d} {7d.left}",
             L("окно и неделя", "window and week")),
            ("{icon} {models}", L("по моделям: O, S, F", "per model: O, S, F")),
            ("{icon} {5h} {5h.left} \u{00B7} {money}",
             L("окно и деньги", "window and money")),
            ("{icon} {active} \u{00B7} {tokens}", L("что упрётся первым, и токены",
                                                    "what hits first, and tokens")),
        ])
    }
}
