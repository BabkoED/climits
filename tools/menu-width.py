#!/usr/bin/env python3
"""Ширина выпадающего меню в точках — считается, а не прикидывается на глаз.

    python3 tools/menu-width.py
    python3 tools/menu-width.py --font 11 --cells 10

Зачем. «Меню будто крупноватое» — суждение, которое нельзя ни подтвердить,
ни опровергнуть словами. А ширина здесь ВЫЧИСЛИМА: строка лимита собрана
из табуляторов, каждый считается от ширины знака моноширинного шрифта
(см. columns() в Sources/MenuBar.swift). Значит можно назвать точное число
и увидеть, какая колонка сколько занимает.

Формулы повторяют код один в один. Если columns() меняется — менять и здесь,
иначе расчёт начнёт врать тише, чем ошибался бы человек на глаз.

Ширина знака SF Mono = 0.6 · кегль (постоянная метрика семейства).
NSMenu добавляет свои поля слева и справа — они взяты по замеру AppKit
и помечены как приближение.
"""
import argparse

SF_MONO_ADVANCE = 0.6          # доля кегля на знак, метрика SF Mono
MENU_INSET_LEFT = 21.0         # [ОЦЕНКА] поле NSMenu слева (под галочку)
MENU_INSET_RIGHT = 12.0        # [ОЦЕНКА] поле справа


def capsule_width(cells, ch):
    """CapsuleBar.width — половина клетки на ячейку, но не меньше 24."""
    return max(24.0, round(cells * ch * 0.5))


def capsule_height(font_size):
    return max(5.0, min(9.0, round(font_size * 0.5)))


def layout(font_size, cells, name_cells, capsule=True):
    """Повторяет columns() из MenuBar.swift."""
    ch = SF_MONO_ADVANCE * font_size
    cap_w = capsule_width(cells, ch)
    bar_w = cap_w if capsule else ch * cells
    x_bar = max(12.0, round(ch * 1.6))
    x_name = x_bar + bar_w + ch
    x_pct = x_name + ch * (max(4, name_cells) + 1 + 4)
    return {
        'ch': ch,
        'указатель': (0.0, x_bar),
        'полоска': (x_bar, x_bar + bar_w),
        'имя лимита': (x_name, x_pct),
        'процент': (x_pct, x_pct + ch),
        'до сброса': (x_pct + ch, x_pct + ch * 8),
        'деньги': (x_pct + ch * 8, x_pct + ch * 16),
        'токены': (x_pct + ch * 16, None),   # хвост — по содержимому
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--font', type=int, default=12, help='menuFontSize, по умолчанию 12')
    ap.add_argument('--cells', type=int, default=14, help='barWidth, по умолчанию 14')
    ap.add_argument('--name', type=int, default=6, help='длина самого длинного имени, «Sonnet» = 6')
    ap.add_argument('--tokens', type=int, default=6, help='знаков в колонке токенов, «12.4M» = 5')
    a = ap.parse_args()

    for capsule in (True, False):
        L = layout(a.font, a.cells, a.name, capsule)
        ch = L['ch']
        tail = L['токены'][0] + ch * a.tokens
        total = MENU_INSET_LEFT + tail + MENU_INSET_RIGHT
        print('\n%s  (кегль %d, шкала %d клеток, знак %.1f pt)'
              % ('КАПСУЛА' if capsule else 'ЗНАКОВАЯ ШКАЛА', a.font, a.cells, ch))
        for name in ('указатель', 'полоска', 'имя лимита', 'процент', 'до сброса', 'деньги'):
            x0, x1 = L[name]
            print('  %-12s %6.1f → %6.1f   ширина %5.1f pt' % (name, x0, x1, x1 - x0))
        print('  %-12s %6.1f → %6.1f   ширина %5.1f pt'
              % ('токены', L['токены'][0], tail, tail - L['токены'][0]))
        print('  %-12s %s' % ('', '─' * 34))
        print('  строка целиком                 %5.1f pt' % tail)
        print('  плюс поля NSMenu [ОЦЕНКА]      %5.1f pt' % total)

    print('\nОриентир: у системных меню строки статуса обычно 250–320 pt.')
    print('Больше 360 pt меню читается как окно, а не как меню.')

    print('\nЧто даёт сжатие:')
    base = layout(a.font, a.cells, a.name, True)
    base_total = MENU_INSET_LEFT + base['токены'][0] + base['ch'] * a.tokens + MENU_INSET_RIGHT
    for label, kw in [('шкала 10 клеток вместо 14', {'cells': 10}),
                      ('шкала 8 клеток', {'cells': 8}),
                      ('кегль 11 вместо 12', {'font': 11}),
                      ('кегль 11 и шкала 10', {'font': 11, 'cells': 10})]:
        f = kw.get('font', a.font)
        c = kw.get('cells', a.cells)
        L = layout(f, c, a.name, True)
        t = MENU_INSET_LEFT + L['токены'][0] + L['ch'] * a.tokens + MENU_INSET_RIGHT
        print('  %-28s %5.1f pt   (−%.0f pt, −%.0f%%)'
              % (label, t, base_total - t, (base_total - t) / base_total * 100))


if __name__ == '__main__':
    main()
