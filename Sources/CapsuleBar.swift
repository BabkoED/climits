import AppKit

// Полоска лимита - картинкой, а не знаками.
//
// Зачем вообще картинка. Шкала из знаков (████░░░░) упирается в сетку
// шрифта: между клетками остаются щели, край всегда прямой, а шаг заливки -
// целый знак. При четырнадцати клетках 3% и 6% - это одна и та же картинка.
// Нарисованная капсула снимает оба ограничения разом: край скруглён,
// заливка идёт точками, а не клетками.
//
// Рисуется через NSImage(size:flipped:drawingHandler:) намеренно.
// Обработчик вызывается В МОМЕНТ отрисовки, то есть системные цвета
// разрешаются в том оформлении, в котором меню показано. Нарисуй мы
// картинку заранее, один раз - она осталась бы светлой в тёмной теме
// и наоборот.
enum CapsuleBar {

    // Толщина считается от размера шрифта меню, а не зашита в точках:
    // человек, поднявший шрифт до 20, ждёт, что полоска вырастет вместе
    // с текстом, а не останется ниткой под ним.
    static func height(fontSize: CGFloat) -> CGFloat {
        return max(5, min(9, (fontSize * 0.5).rounded()))
    }

    // Длина - в тех же клетках, что и у знаковой шкалы, чтобы настройка
    // «длина шкалы» продолжала значить ровно то же самое. Половина ширины
    // знака на клетку: знаковая шкала занимает всю ширину клетки, а рисунку
    // хватает половины - между клетками у него щелей нет.
    static func width(cells: Int, unit: CGFloat) -> CGFloat {
        return max(24, (CGFloat(cells) * unit * 0.5).rounded())
    }

    static func image(percent: Int, color: NSColor,
                      width w: CGFloat, height h: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let r = h / 2

            // Подложка - тот же цвет, приглушённый, а не серый: так видно,
            // что пустая часть принадлежит этой же полоске, и в тёмной теме
            // она не спорит с фоном меню.
            color.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                         xRadius: r, yRadius: r).fill()

            let fw = CGFloat(Fmt.fillWidth(pct: percent, total: Double(w),
                                           minVisible: Double(h)))
            if fw > 0 {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: fw, height: h),
                             xRadius: r, yRadius: r).fill()
            }
            return true
        }
        // Не шаблон: шаблонную картинку система перекрашивает в цвет текста,
        // и весь смысл цвета по нагрузке пропал бы.
        img.isTemplate = false
        return img
    }

    // Картинка внутри строки. Смещение по вертикали - от базовой линии:
    // без него полоска стоит НА ней, то есть заметно ниже середины букв.
    static func attachment(percent: Int, color: NSColor,
                           width w: CGFloat, height h: CGFloat,
                           font: NSFont) -> NSAttributedString {
        let att = NSTextAttachment()
        att.image = image(percent: percent, color: color, width: w, height: h)
        att.bounds = CGRect(x: 0, y: ((font.capHeight - h) / 2).rounded(),
                            width: w, height: h)
        return NSAttributedString(attachment: att)
    }
}
