import AppKit

// Цвета и пороги в одном месте.
//
// Раньше «если больше 80 - красный» было рассыпано по трём файлам, и любое
// изменение приходилось помнить в трёх местах. Теперь решение принимается
// здесь, а остальные только спрашивают.
//
// Два источника правды, и порядок между ними важен: если сервер прислал
// severity, слушаем его. Наши пороги - выдумка, удобная по умолчанию;
// severity считает тот, кто считает и сам лимит.
enum Palette {

    // Цвет по имени или по HEX из настроек. Пусто - системный.
    private static func resolve(_ spec: String, fallback: NSColor) -> NSColor {
        let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return fallback }
        switch s {
        case "green":  return .systemGreen
        case "orange": return .systemOrange
        case "red":    return .systemRed
        case "yellow": return .systemYellow
        case "blue":   return .systemBlue
        case "purple": return .systemPurple
        case "pink":   return .systemPink
        case "teal":   return .systemTeal
        case "gray", "grey": return .systemGray
        case "label", "auto": return .labelColor
        default: return hex(s) ?? fallback
        }
    }

    // «#ff3b30» и «ff3b30» одинаково. Мусор - молча системный цвет:
    // опечатка в настройке не должна делать строку меню невидимой.
    private static func hex(_ raw: String) -> NSColor? {
        var s = raw
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green:   CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue:    CGFloat(v & 0xFF) / 255.0,
                       alpha:   1.0)
    }

    static var calm: NSColor { resolve(Prefs.colorCalm, fallback: .systemGreen) }
    static var warn: NSColor { resolve(Prefs.colorWarn, fallback: .systemOrange) }
    static var alarm: NSColor { resolve(Prefs.colorAlarm, fallback: .systemRed) }

    static func color(forPercent p: Int, severity: String) -> NSColor {
        switch styleLevel(percent: p, severity: severity) {
        case 2: return alarm
        case 1: return warn
        default: return calm
        }
    }

    static func color(for b: Bucket) -> NSColor {
        return color(forPercent: b.pct, severity: b.severity)
    }

    // Строка меню молчит, пока всё спокойно: постоянный цвет перестаёт
    // читаться как сигнал уже на второй день.
    static func titleColor(for b: Bucket) -> NSColor {
        return styleLevel(percent: b.pct, severity: b.severity) == 0
            ? .labelColor
            : color(for: b)
    }

    // Шрифт строки меню. Моноширинные цифры обязательны: на пропорциональных
    // строка дёргается по ширине при каждом изменении процента.
    static var barFont: NSFont {
        let size = CGFloat(Prefs.fontSize)
        if let name = Prefs.fontName.isEmpty ? nil : Prefs.fontName,
           let f = NSFont(name: name, size: size) {
            return f
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static var menuFont: NSFont {
        return NSFont.monospacedSystemFont(ofSize: CGFloat(Prefs.menuFontSize), weight: .regular)
    }
}
