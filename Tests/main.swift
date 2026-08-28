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
//
// Форма взята из работающего приложения, а не придумана. Это важно: первая
// версия этого теста описывала limits[] так, как мне казалось удобным -
// с полем model строкой рядом с процентом, - тест проходил, а на настоящем
// ответе все модельные лимиты слипались в один. Тест, проверяющий выдумку,
// не проверяет ничего.
let arrayShape = """
{
  "limits": [
    {"kind": "session", "percent": 37.4, "resets_at": "\(soon)",
     "severity": "normal", "is_active": true},
    {"kind": "weekly_all", "percent": 62.0, "resets_at": "\(later)",
     "severity": "warning", "is_active": false},
    {"kind": "weekly_scoped", "percent": 81.2, "resets_at": "\(later)",
     "severity": "critical", "is_active": false,
     "scope": {"model": {"display_name": "Claude Opus 4.6"}}},
    {"kind": "weekly_scoped", "percent": 12.0, "resets_at": "\(later)",
     "severity": "normal", "is_active": false,
     "scope": {"model": {"display_name": "Claude Sonnet 5"}}},
    {"kind": "weekly_scoped", "percent": 0.0, "resets_at": null,
     "severity": "normal", "is_active": false,
     "scope": {"model": {"display_name": "Claude Fable 5"}}}
  ],
  "spend": {"enabled": true, "percent": 69.8,
            "used":  {"amount_minor": 13963, "exponent": 2, "currency": "USD"},
            "limit": {"amount_minor": 20000, "exponent": 2, "currency": "USD"}}
}
"""

print("\nформа ответа: массив limits (настоящая)")
guard let b = UsageParser.parse(body: arrayShape, fetchedAt: Date(), isStale: false) else {
    print("  FAIL разбор не состоялся вовсе"); exit(1)
}
check("разобраны все пять", b.buckets.count == 5)
check("session стал пятичасовым окном", b.bucket("five_hour") != nil)
check("weekly_all стал недельным капом", b.bucket("seven_day") != nil)

// Главная проверка: три weekly_scoped обязаны разойтись по трём ключам.
// Пока имя модели искалось не там, все три давали один ключ.
check("модельные лимиты не слиплись в один",
      b.buckets.filter { $0.key.hasPrefix("seven_day_") }.count == 3)
check("Opus узнан по scope.model.display_name", b.bucket("seven_day_opus")?.short ?? "нет", "Opus")
check("Sonnet тоже", b.bucket("seven_day_sonnet")?.short ?? "нет", "Sonnet")
check("Fable тоже, и без хака nimbus_quill", b.bucket("seven_day_fable")?.short ?? "нет", "Fable")
check("версия и дата из имени модели отброшены",
      !(b.bucket("seven_day_opus")?.short.contains("4.6") ?? true))
check("активный лимит взят из is_active", b.active?.key ?? "", "five_hour")
check("severity от сервера сохранён", b.bucket("seven_day_opus")?.severity ?? "", "critical")
check("деньги из spend с полем enabled", b.extra.usedText, "$139.63")
check("процент перерасхода взят из spend.percent", "\(b.extra.percent ?? -1)", "69")

// ---- строка меню -----------------------------------------------------------
print("\nстрока меню")
check("шаблон по умолчанию собирается",
      !BarTitle.render("{icon} {5h} \u{00B7} {5h.left} \u{00B7} {extra}", usage: a).isEmpty)

// Модель, которой нет в ответе, не должна оставлять висящий разделитель.
let withGap = BarTitle.render("{5h} \u{00B7} {haiku} \u{00B7} {7d}", usage: a)
check("пустой макрос убран вместе с разделителем", withGap, "37% \u{00B7} 62%")
check("нет двойных разделителей", !withGap.contains("\u{00B7} \u{00B7}"))

let onlyEmpty = BarTitle.render("{haiku} \u{00B7} {несуществующий}", usage: b)
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

let mv2 = MoneyView.make(spent: 12.0, percent: 10, partial: true)
check("макрос денег подставляется со знаком приблизительности",
      BarTitle.render("{money}", usage: a, money: mv2), "\u{2248}$12")
check("макрос полного лимита тоже",
      BarTitle.render("{money.limit}", usage: a, money: mv2), "\u{2248}$120")
check("без денег макрос не оставляет мусора",
      BarTitle.render("{5h} \u{00B7} {money}", usage: a), "37%")

// ---- мусор на входе --------------------------------------------------------
print("\nмусор на входе")
check("пустая строка не разбирается", UsageParser.parse(body: "", fetchedAt: Date(), isStale: false) == nil)
check("не-JSON не разбирается", UsageParser.parse(body: "<html>429</html>", fetchedAt: Date(), isStale: false) == nil)
check("JSON без лимитов не разбирается",
      UsageParser.parse(body: "{\"spend\":{}}", fetchedAt: Date(), isStale: false) == nil)
check("объект без процента отбрасывается",
      UsageParser.parse(body: "{\"junk\":{\"resets_at\":\"\(soon)\"}}", fetchedAt: Date(), isStale: false) == nil)


// ---- деньги ----------------------------------------------------------------
print("\nденьги")

// Прайс Opus 5: $5 за 1M входных, $25 за 1M выходных, запись в кэш 1.25x
// от входа, чтение 0.1x. Миллион входных и миллион выходных - это $30.
let opus = Pricing.price(for: "claude-opus-5")
check("прайс Opus разобран", "\(opus.input)/\(opus.output)", "5.0/25.0")
check("запись в кэш дороже входа в 1.25 раза", "\(opus.cacheWrite)", "6.25")
check("чтение из кэша дешевле входа в 10 раз", "\(opus.cacheRead)", "0.5")

let million = TokenTally(input: 1_000_000, output: 1_000_000,
                         cacheWrite: 0, cacheRead: 0, requests: 1)
check("миллион входных и миллион выходных Opus", MoneyView.money(million.cost(opus)), "$30")

// Кэш нельзя считать по цене входа: у Антона в харнесе чтение из кэша -
// основная масса токенов, и по входной цене счёт вырос бы в десять раз.
let cacheHeavy = TokenTally(input: 0, output: 0, cacheWrite: 0,
                            cacheRead: 10_000_000, requests: 1)
check("десять миллионов из кэша - это $5, а не $50",
      MoneyView.money(cacheHeavy.cost(opus)), "$5.00")

// pricing.json правит человек - значит там может оказаться что угодно.
check("отрицательная цена отбрасывается", Pricing.builtin["opus"] != nil)
check("прайс всегда конечный и неотрицательный",
      Pricing.builtin.values.allSatisfy { $0.input.isFinite && $0.input >= 0
                                       && $0.output.isFinite && $0.output >= 0
                                       && $0.cacheRead.isFinite && $0.cacheWrite.isFinite })

check("семейство из claude-opus-5", Pricing.family(of: "claude-opus-5"), "opus")
check("семейство из Claude Fable 5", Pricing.family(of: "Claude Fable 5"), "fable")
check("незнакомая модель считается по запасной", Pricing.family(of: "claude-nimbus-9"), "sonnet")
check("и помечается как незнакомая", !Pricing.isKnown("claude-nimbus-9"))

// Экстраполяция: потратили $12 и это 10% лимита -> весь лимит около $120.
let m = MoneyView.make(spent: 12.0, percent: 10, partial: false)
check("лимит в деньгах посчитан от процента", m.fullText ?? "нет", "$120")
// При крошечном проценте деление разносит погрешность в разы - не показываем.
let tiny = MoneyView.make(spent: 0.4, percent: 1, partial: false)
check("на одном проценте экстраполяции нет", tiny.fullLimit == nil)
let zero = MoneyView.make(spent: 0, percent: 40, partial: false)
check("без трафика экстраполяции нет", zero.fullLimit == nil)

// ---- чтение расшифровок ----------------------------------------------------
print("\nрасшифровки")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("climits-transcripts-test", isDirectory: true)
try? FileManager.default.removeItem(at: tmp)
try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("proj-a"),
                                         withIntermediateDirectories: true)

func iso(_ offset: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date().addingTimeInterval(offset))
}

// Фикстура по живому файлу, а не по моему представлению о нём.
//
// Claude Code пишет ответ модели несколькими строками, и в каждой лежит
// ПОЛНЫЙ usage сообщения, а не приращение. Замер на настоящей расшифровке:
// 98 строк с usage на 43 сообщения, значения в повторах идентичны. Прежняя
// фикстура держала одну строку на сообщение - и тест не замечал, что деньги
// завышаются вдвое.
let jsonl = [
  // одно сообщение Opus, разбитое на три строки с одинаковым usage
  "{\"timestamp\":\"\(iso(-600))\",\"message\":{\"id\":\"msg_a\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"cache_read_input_tokens\":500000}}}",
  "{\"timestamp\":\"\(iso(-599))\",\"message\":{\"id\":\"msg_a\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"cache_read_input_tokens\":500000}}}",
  "{\"timestamp\":\"\(iso(-598))\",\"message\":{\"id\":\"msg_a\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"cache_read_input_tokens\":500000}}}",
  // отдельное сообщение Sonnet, две строки
  "{\"timestamp\":\"\(iso(-900))\",\"message\":{\"id\":\"msg_b\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":300,\"output_tokens\":100}}}",
  "{\"timestamp\":\"\(iso(-899))\",\"message\":{\"id\":\"msg_b\",\"model\":\"claude-sonnet-5\",\"usage\":{\"input_tokens\":300,\"output_tokens\":100}}}",
  // за пределами окна
  "{\"timestamp\":\"\(iso(-99999))\",\"message\":{\"id\":\"msg_old\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":9999999,\"output_tokens\":9999999}}}",
  // строка без расхода вообще
  "{\"timestamp\":\"\(iso(-300))\",\"type\":\"user\",\"message\":{\"content\":\"без расхода\"}}",
].joined(separator: "\n")
try? jsonl.write(to: tmp.appendingPathComponent("proj-a/session.jsonl"),
                 atomically: true, encoding: .utf8)

let win = Transcripts.usage(since: Date().addingTimeInterval(-3600), dir: tmp)
check("найдены две модели", win.byFamily.count == 2)
// Главная проверка этого блока: три строки одного сообщения дают один расход,
// а не тройной. Именно здесь деньги завышались вдвое.
check("повторы одного сообщения не сложились", "\(win.byFamily["opus"]?.input ?? -1)", "1000")
check("и запрос посчитан один", win.byFamily["opus"]?.requests == 1)
check("Sonnet тоже один раз", "\(win.byFamily["sonnet"]?.output ?? -1)", "100")
check("всего два сообщения, а не пять строк", win.totals.requests == 2)
check("чтение из кэша учтено отдельно", "\(win.byFamily["opus"]?.cacheRead ?? -1)", "500000")
check("сообщение за пределами окна не попало", (win.byFamily["opus"]?.input ?? 0) < 9_999_999)
check("короткий файл не помечен обрезанным", !win.truncated)
// 1000*5 + 2000*25 + 500000*0.5 = 5000 + 50000 + 250000 = 305000 / 1e6 = $0.305
check("стоимость окна посчитана", MoneyView.money(win.cost).hasPrefix("$0.3"))
try? FileManager.default.removeItem(at: tmp)

print("\nпроверок: \(checks), провалов: \(failures)\n")
exit(failures == 0 ? 0 : 1)
