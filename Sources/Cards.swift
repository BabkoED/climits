import AppKit

// Карточки в выпадающем меню - вид, взятый у CodexBar (MIT).
//
// ЗАЧЕМ. Строка лимита в одну линию табуляторами плотная, но читается
// как таблица: имя, полоска, процент и остаток стоят в одном ряду, и
// глазу приходится разбирать колонки. Антон 24.09.2026: «дизайн там мне
// понравился, аккуратный и понятный». У CodexBar на лимит три ряда:
// заголовок, полоса, под ней «сколько использовано» слева и «когда
// сброс» справа. Выше, зато каждый ряд отвечает на один вопрос.
//
// Прежний вид остаётся - галочка «Карточки в меню» в настройках. Он
// был выбран 05.09.2026 ради высоты меню, и отбирать его молча нельзя.
//
// ПОЧЕМУ НЕ SwiftUI, как у CodexBar. SwiftUI внутри NSMenu живёт на
// обходных путях: у них отдельные файлы на замер высоты, подсветку и
// перерисовку открытого меню. Здесь вид рисуется сам, одним draw():
// высота считается явно, ширина следует за меню, тёмная тема приходит
// через системные цвета. Меньше движущихся частей - меньше того, что
// проверяется только глазами на снимке.
enum CardStyle {
    // Ширина по умолчанию. Меню шире - карточка растягивается вместе
    // с ним (autoresizingMask), уже - не сжимается ниже этой.
    static let width: CGFloat = 320
    static let padX: CGFloat = 16
    static let barH: CGFloat = 6

    static var title: NSFont { return .systemFont(ofSize: 13, weight: .semibold) }
    static var body: NSFont { return .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    static var small: NSFont { return .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    static var big: NSFont { return .systemFont(ofSize: 15, weight: .bold) }
}

// Текст одной строкой с обрезкой по ширине. Выравнивание вправо - по
// правому краю области: у «сброс через 2ч» и «3д 3ч» разная длина.
private func drawText(_ s: String, font: NSFont, color: NSColor,
                      x: CGFloat, y: CGFloat, width: CGFloat, right: Bool = false) -> CGFloat {
    guard !s.isEmpty, width > 4 else { return 0 }
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byTruncatingTail
    para.alignment = right ? .right : .left
    let a = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: para,
    ])
    let h = ceil(font.ascender - font.descender + font.leading) + 1
    a.draw(with: NSRect(x: x, y: y, width: width, height: h),
           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    return min(width, ceil(a.size().width))
}

private func lineHeight(_ f: NSFont) -> CGFloat {
    return ceil(f.ascender - f.descender + f.leading) + 1
}

// --- шапка ------------------------------------------------------------------

struct HeaderCard {
    var title: String      // «Claude»
    var right: String      // тариф: «Max»; пусто - нет
    var sub: String        // «обновлено только что» или причина несвежести
    var subAlarm: Bool     // подпись про беду - цветом
}

final class HeaderCardView: NSView {
    let card: HeaderCard
    override var isFlipped: Bool { return true }

    init(_ c: HeaderCard) {
        card = c
        let h = 8 + lineHeight(CardStyle.big) + 2 + lineHeight(CardStyle.small) + 8
        super.init(frame: NSRect(x: 0, y: 0, width: CardStyle.width, height: h))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        let x = CardStyle.padX
        let w = bounds.width - 2 * x
        var y: CGFloat = 8
        let rw = drawText(card.right, font: CardStyle.body, color: .secondaryLabelColor,
                          x: x, y: y + 2, width: w, right: true)
        _ = drawText(card.title, font: CardStyle.big, color: .labelColor,
                     x: x, y: y, width: w - rw - 8)
        y += lineHeight(CardStyle.big) + 2
        _ = drawText(card.sub, font: CardStyle.small,
                     color: card.subAlarm ? .systemOrange : .secondaryLabelColor,
                     x: x, y: y, width: w)
    }
}

// --- лимит ------------------------------------------------------------------

struct LimitCard {
    var title: String       // «5-часовое окно»
    var first: Bool         // упрётся первым - указатель перед заголовком
    var corner: String      // справа от заголовка: деньги и токены
    var pct: Int?           // nil - полосы нет (потолок не задан)
    var color: NSColor
    var marker: Int?        // где был бы ровный темп, %
    var left: String        // «57% использовано»
    var right: String       // «сброс через 2ч 13м»
    var note: String        // строка темпа; пусто - нет
    var noteAlarm: Bool     // темп обгоняет - цветом полосы
}

final class LimitCardView: NSView {
    let card: LimitCard
    override var isFlipped: Bool { return true }

    static func height(_ c: LimitCard) -> CGFloat {
        var h: CGFloat = 6 + lineHeight(CardStyle.title) + 4
        if c.pct != nil { h += CardStyle.barH + 5 }
        if !c.left.isEmpty || !c.right.isEmpty { h += lineHeight(CardStyle.body) }
        if !c.note.isEmpty { h += 1 + lineHeight(CardStyle.small) }
        return h + 6
    }

    init(_ c: LimitCard) {
        card = c
        super.init(frame: NSRect(x: 0, y: 0, width: CardStyle.width, height: LimitCardView.height(c)))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        let x = CardStyle.padX
        let w = bounds.width - 2 * x
        var y: CGFloat = 6

        // Заголовок и угол. Угол рисуется первым и узнаёт свою ширину:
        // заголовок режется по остатку, а не наезжает на деньги.
        // Угол не шире половины карточки: деньги с токенами длинные, а
        // заголовок важнее них.
        let cornerW = card.corner.isEmpty ? 0
            : min(w * 0.5, ceil(NSAttributedString(string: card.corner,
                                                   attributes: [.font: CardStyle.small]).size().width))
        if !card.corner.isEmpty {
            _ = drawText(card.corner, font: CardStyle.small, color: .secondaryLabelColor,
                         x: x + w - cornerW, y: y + 2, width: cornerW + 1)
        }
        var tx = x
        if card.first {
            // Указатель - цветом этого же лимита, как в строках: «вот он».
            tx += drawText("\u{25B8} ", font: CardStyle.title, color: card.color,
                           x: tx, y: y, width: 20)
        }
        _ = drawText(card.title, font: CardStyle.title, color: .labelColor,
                     x: tx, y: y, width: max(20, w - (tx - x) - cornerW - 8))
        y += lineHeight(CardStyle.title) + 4

        if let p = card.pct {
            let r = NSRect(x: x, y: y, width: w, height: CardStyle.barH)
            let radius = CardStyle.barH / 2
            // Подложка - тот же цвет, приглушённый: как у капсулы и кольца,
            // пустая часть принадлежит этой же шкале, а не сером фону.
            card.color.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            let fillW = w * CGFloat(max(0, min(100, p))) / 100
            if fillW > 0 {
                // Узкая заливка короче скругления рисуется кружком, а не
                // сплющенной каплей: так 1-2% всё равно видны точкой.
                let fw = max(fillW, CardStyle.barH)
                card.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fw, height: CardStyle.barH),
                             xRadius: radius, yRadius: radius).fill()
            }
            if let m = card.marker, m > 0, m < 100 {
                // Метка ровного темпа: где была бы заливка, если тратить
                // равномерно до сброса. Заливка левее метки - с запасом.
                let mx = (x + w * CGFloat(m) / 100).rounded() + 0.5
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: mx, y: y - 2))
                tick.line(to: NSPoint(x: mx, y: y + CardStyle.barH + 2))
                tick.lineWidth = 1.5
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                tick.stroke()
            }
            y += CardStyle.barH + 5
        }

        if !card.left.isEmpty || !card.right.isEmpty {
            let rw = drawText(card.right, font: CardStyle.body, color: .secondaryLabelColor,
                              x: x, y: y, width: w, right: true)
            _ = drawText(card.left, font: CardStyle.body, color: .labelColor,
                         x: x, y: y, width: w - rw - 8)
            y += lineHeight(CardStyle.body)
        }

        if !card.note.isEmpty {
            y += 1
            _ = drawText(card.note, font: CardStyle.small,
                         color: card.noteAlarm ? card.color : .secondaryLabelColor,
                         x: x, y: y, width: w)
        }
    }
}

// Пункт меню с видом-карточкой. Отдельная функция, потому что у всех
// карточек одинаково: включён (иначе система гасит вид серым), без
// действия - карточка читается, а не нажимается.
func cardItem(_ v: NSView) -> NSMenuItem {
    let i = NSMenuItem()
    i.view = v
    i.isEnabled = true
    return i
}
