import Foundation

// Проверки разбора ответа API и сборки строки меню.
//
// Здесь нет ни AppKit, ни сети: только чистая логика, и потому это гоняется
// где угодно, включая Linux и CI. Смысл ровно один - поймать то, что нельзя
// увидеть глазами: единицы денег, схлопывание пустых макросов, обе формы
// ответа. Именно на этих местах прошлые версии индикатора врали молча.

var failures = 0
var checks = 0

func check(_ name: String, _ got: String, _ want: String) {
    checks += 1
    if got == want {
        print("  ok   \(name)")
    } else {
        failures += 1
        print("  FAIL \(name)\n       ждали: \(want)\n       вышло: \(got)")
    }
}

func check(_ name: String, _ cond: Bool) {
    checks += 1
    if cond { print("  ok   \(name)") }
    else { failures += 1; print("  FAIL \(name)") }
}

// Время сброса задаём от «сейчас», чтобы проверки не протухали.
let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600 + 900))
let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400))

// ---- форма 1: объекты верхнего уровня --------------------------------------
let topLevel = """
{
  "five_hour":        {"utilization": 37.4, "resets_at": "\(soon)"},
  "seven_day":        {"utilization": 62.0, "resets_at": "\(later)"},
  "seven_day_opus":   {"utilization": 81.2, "resets_at": "\(later)"},
  "seven_day_sonnet": {"utilization": 12.0, "resets_at": "\(later)"},
  "nimbus_quill":     {"utilization": 0.0,  "resets_at": null},
  "spend":       {"used": {"amount_minor": 13963, "exponent": 2, "currency": "USD"}},
  "extra_usage": {"is_enabled": true, "monthly_limit": 20000,
                  "used_credits": 13963.0, "decimal_places": 2}
}
"""

print("\nформа ответа: объекты верхнего уровня")
guard let a = UsageParser.parse(body: topLevel, fetchedAt: Date(), isStale: false) else {
    print("  FAIL разбор не состоялся вовсе"); exit(1)
}
check("нашлись все пять лимитов", a.buckets.count == 5)
check("порядок: сначала окно, потом неделя, потом модели",
      a.buckets.map { $0.key }.prefix(2).joined(separator: ","), "five_hour,seven_day")
check("процент отбрасывает дробь, как /usage", "\(a.bucket("five_hour")!.pct)", "37")
check("Fable виден, хотя пришёл нулём и без окна сброса",
      a.bucket("nimbus_quill")?.short ?? "нет", "Fable")
check("самый нагруженный - Opus", a.worst?.key ?? "", "seven_day_opus")
check("текущее окно - пятичасовое", a.session?.key ?? "", "five_hour")

// Единицы денег: 13963 при exponent=2 - это $139.63, а не $13963.
// Ровно на этом месте прежние версии завышали расход в сто раз.
check("минорные единицы переведены верно", a.extra.usedText, "$139.63")
check("месячный потолок тоже", a.extra.limitText, "$200.00")
// utilization не прислали - процент обязан посчитаться самостоятельно,
// иначе 70% выглядели бы спокойным нулём.
check("процент перерасхода посчитан сам", "\(a.extra.percent ?? -1)", "69")

// ---- форма 2: массив limits ------------------------------------------------
let arrayShape = """
{
  "limits": [
    {"kind": "five_hour", "percent": 37.4, "resets_at": "\(soon)", "is_active": true},
    {"kind": "seven_day", "percent": 62.0, "resets_at": "\(later)"},
    {"kind": "seven_day", "model": "claude-opus-4-6-20260115", "percent": 81.2,
     "resets_at": "\(later)", "title": "Opus"},
    {"kind": "seven_day", "model": "claude-fable-5", "percent": 0.0, "resets_at": null}
  ],
  "spend": {"used": {"amount_minor": 500, "exponent": 2, "currency": "USD"}},
  "extra_usage": {"is_enabled": false}
}
"""

print("\nформа ответа: массив limits")
guard let b = UsageParser.parse(body: arrayShape, fetchedAt: Date(), isStale: false) else {
    print("  FAIL разбор не состоялся вовсе"); exit(1)
}
check("разобраны все четыре", b.buckets.count == 4)
check("модель из имени вида claude-opus-4-6-... стала opus",
      b.bucket("seven_day_opus")?.short ?? "нет", "Opus")
check("Fable по имени модели, без хака nimbus_quill",
      b.bucket("seven_day_fable") != nil)
check("активный лимит взят из is_active", b.active?.key ?? "", "five_hour")
check("перерасход выключен - процента нет", b.extra.percent == nil || !b.extra.enabled)

// ---- строка меню -----------------------------------------------------------
print("\nстрока меню")
check("шаблон по умолчанию собирается",
      !BarTitle.render("{icon} {5h} \u{00B7} {5h.left} \u{00B7} {extra}", usage: a).isEmpty)

// Модель, которой нет в ответе, не должна оставлять висящий разделитель.
let withGap = BarTitle.render("{5h} \u{00B7} {haiku} \u{00B7} {7d}", usage: a)
check("пустой макрос убран вместе с разделителем", withGap, "37% \u{00B7} 62%")
check("нет двойных разделителей", !withGap.contains("\u{00B7} \u{00B7}"))

let onlyEmpty = BarTitle.render("{haiku} \u{00B7} {extra.pct}", usage: b)
check("строка из одних пустых макросов не остаётся мусором",
      !onlyEmpty.contains("\u{00B7}") && !onlyEmpty.contains("{"))

let unknown = BarTitle.render("{5h} {выдуманный} {nosuch}", usage: a)
check("неизвестный макрос не висит в трее фигурными скобками",
      !unknown.contains("{") && !unknown.contains("}"))

// Несвежие данные обязаны быть видны, иначе человек примет вчерашние цифры
// за сегодняшние.
if let stale = UsageParser.parse(body: topLevel, fetchedAt: Date(), isStale: true) {
    check("несвежие данные помечены тильдой",
          BarTitle.render("{5h}", usage: stale).hasSuffix("~"))
}

// ---- мусор на входе --------------------------------------------------------
print("\nмусор на входе")
check("пустая строка не разбирается", UsageParser.parse(body: "", fetchedAt: Date(), isStale: false) == nil)
check("не-JSON не разбирается", UsageParser.parse(body: "<html>429</html>", fetchedAt: Date(), isStale: false) == nil)
check("JSON без лимитов не разбирается",
      UsageParser.parse(body: "{\"spend\":{}}", fetchedAt: Date(), isStale: false) == nil)
check("объект без процента отбрасывается",
      UsageParser.parse(body: "{\"junk\":{\"resets_at\":\"\(soon)\"}}", fetchedAt: Date(), isStale: false) == nil)

print("\nпроверок: \(checks), провалов: \(failures)\n")
exit(failures == 0 ? 0 : 1)
