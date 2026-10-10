import AppKit

// Строка трея картинкой (1.22.0).
//
// ЗАЧЕМ. Два окна стопкой - «37% 2ч 13м» над «62% 3д» - заголовком кнопки
// трея надёжно не нарисовать: attributedTitle статус-элемента рисуется
// в одну строку, а проверить перенос отсюда нечем - Мака нет. Картинка у
// кнопки - тот же путь, что у кольца: документированный и проверенный на
// живой машине. Цвета в ней такие же динамические, как у кольца:
// обработчик рисования зовётся при отрисовке, и labelColor берётся под
// тему строки меню, а не под ту, что была при сборке картинки.
//
// Тем же путём рисуется предпросмотр в окне настроек - в любом режиме,
// и в одну строку тоже: что видно в окне, то и будет в трее.
enum BarImage {
    enum Icon {
        case none
        case glyph(String)
        case ring(Int)
    }

    // Шрифт двух строк - от высоты строки меню, а не от настройки размера:
    // две строки обязаны влезть в высоту одной. 22 точки дают 9,5 pt -
    // мельче на обычном экране уже не читается, крупнее не влезает.
    static func stackFont(height: CGFloat) -> NSFont {
        let size = max(8, min(11, (height / 2).rounded(.down) - 1.5))
        if !Prefs.fontName.isEmpty, let f = NSFont(name: Prefs.fontName, size: size) {
            return f
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }

    // «Крупно - мелко» (1.22.1): процент одного окна сверху крупно, время
    // под ним мельче. Верхняя строка берёт больше высоты.
    static func titleFonts(height: CGFloat) -> [NSFont] {
        let big = max(9, min(14, (height * 0.5).rounded(.down)))
        let small = max(7.5, min(10, (height * 0.38 * 2).rounded(.down) / 2))
        func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            if !Prefs.fontName.isEmpty, let f = NSFont(name: Prefs.fontName, size: size) { return f }
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
        return [font(big, .semibold), font(small, .regular)]
    }

    // Значок по центру высоты; рядом одна строка шрифтом трея или две
    // строки мелким шрифтом, каждая в своей половине высоты. titled - две
    // строки «крупно - мелко» вместо двух равных. trailing -
    // значок справа: свой формат может кончаться {icon}, и переносить его
    // молча в начало значит переставить человеку его же строку.
    static func image(lines: [String], color: NSColor, icon: Icon,
                      height: CGFloat, badge: NSColor? = nil,
                      trailing: Bool = false, titled: Bool = false) -> NSImage {
        let stacked = lines.count > 1
        let even = stackFont(height: height)
        let fonts: [NSFont] = !stacked ? [Palette.barFont]
            : (titled ? titleFonts(height: height) : [even, even])
        let texts = lines.prefix(2).enumerated().map { i, s in
            NSAttributedString(string: s, attributes: [.font: fonts[min(i, fonts.count - 1)],
                                                       .foregroundColor: color])
        }
        let textW = ceil(texts.map { $0.size().width }.max() ?? 0)

        var ringImage: NSImage? = nil
        var glyphText: NSAttributedString? = nil
        switch icon {
        case .none:
            break
        case .ring(let pct):
            ringImage = RingBar.image(percent: pct, color: color, font: Palette.barFont,
                                      trailing: trailing, badge: badge)
        case .glyph(let g):
            // Пробел между знаком и текстом - тот же зазор, что даёт шаблон
            // «{icon} ...».
            let gap = texts.isEmpty ? "" : " "
            glyphText = NSAttributedString(string: trailing ? gap + g : g + gap, attributes: [
                .font: Palette.barFont, .foregroundColor: color])
        }
        let iconW = ringImage?.size.width ?? ceil(glyphText?.size().width ?? 0)
        let size = NSSize(width: max(1, iconW + textW), height: height)
        let barFont = Palette.barFont

        let img = NSImage(size: size, flipped: false) { _ in
            // Текст ставится по высоте ПРОПИСНЫХ, а не по высоте строки: в
            // строке трея одни цифры, у них нет выносных вниз, и центровка по
            // строке поднимала бы их над серединой.
            func draw(_ t: NSAttributedString, _ f: NSFont, x: CGFloat, bandY: CGFloat, bandH: CGFloat) {
                let baseline = bandY + (bandH - f.capHeight) / 2
                t.draw(at: NSPoint(x: x, y: (baseline + f.descender).rounded()))
            }
            let iconX: CGFloat = trailing ? textW : 0
            let textX: CGFloat = trailing ? 0 : iconW
            if let r = ringImage {
                let y = ((height - r.size.height) / 2).rounded()
                r.draw(in: NSRect(x: iconX, y: y, width: r.size.width, height: r.size.height))
            } else if let g = glyphText {
                draw(g, barFont, x: iconX, bandY: 0, bandH: height)
            }
            if stacked {
                // Полосы высоты: поровну, а у «крупно - мелко» верхней больше.
                let top = titled ? (height * 0.56).rounded() : height / 2
                let bottom = height - top
                for (i, t) in texts.enumerated() {
                    let f = fonts[min(i, fonts.count - 1)]
                    draw(t, f, x: textX, bandY: i == 0 ? bottom : 0, bandH: i == 0 ? top : bottom)
                }
            } else if let t = texts.first {
                draw(t, fonts[0], x: textX, bandY: 0, bandH: height)
            }
            return true
        }
        // Не шаблон: шаблонную картинку система перекрашивает в цвет текста,
        // и цвет по нагрузке пропал бы вместе с сигналом.
        img.isTemplate = false
        return img
    }
}
