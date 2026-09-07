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

func check(_ name: String, _ got: Double, _ want: Double) {
    check(name, String(format: "%.3f", got), String(format: "%.3f", want))
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

let mv2 = MoneyView.make(spent: 12.0, partial: true)
check("макрос денег подставляется со знаком приблизительности",
      BarTitle.render("{money}", usage: a, money: mv2), "\u{2248}$12")
// Макроса {money.limit} больше нет - лимит в деньгах был выведен делением
// на процент и врал в разы. У людей он мог остаться в своём шаблоне,
// поэтому проверяем не отсутствие макроса, а то, что от него не остаётся
// мусора в строке меню.
check("снятый макрос полного лимита не оставляет мусора",
      BarTitle.render("{5h} \u{00B7} {money.limit}", usage: a, money: mv2), "37%")
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

// Деньги - только измеренное. Экстраполяции «весь лимит = потрачено/процент»
// здесь больше нет: числитель считался по видимым машинам, знаменатель - по
// всему аккаунту, и на замере 28.08 это занижало лимит вчетверо.
let m = MoneyView.make(spent: 12.0, partial: false)
check("деньги - это потрачено, и ничего больше", m.spentText, "$12")
check("копейки не округляются до нуля", MoneyView.make(spent: 0.4, partial: false).spentText, "$0.40")
check("сотни без ложной точности", MoneyView.make(spent: 258.37, partial: false).spentText, "$258")

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


// ---- нефинитные числа: главный дефект ревью безопасности ------------------
print("\nнефинитные значения")

// В Swift Int(Double.nan) - это trap, а не мусорное значение. Путь до падения
// короткий: "nan" в кэше или в любом .jsonl -> Bucket.pct в строке меню.
check("nan из JSON отбрасывается", jsonNumber("nan") == nil)
check("inf тоже", jsonNumber("inf") == nil)
check("-inf тоже", jsonNumber("-inf") == nil)
check("обычное число проходит", "\(jsonNumber("62.5") ?? -1)", "62.5")
check("safeInt на nan не валится", "\(safeInt(Double.nan))", "0")
check("safeInt отбрасывает дробь, а не округляет", "\(safeInt(69.8))", "69")
check("бесконечность считается негодной и даёт 0", "\(safeInt(Double.infinity))", "0")
// Зажатие относится к ФИНИТНЫМ, но огромным: 1e300 конечно, а в Int не влезает.
check("огромное конечное число зажимается, а не валит",
      safeInt(1e300) == Int(Int32.max))
check("огромное отрицательное тоже", safeInt(-1e300) == -Int(Int32.max))

// Лимит с испорченным процентом должен исчезнуть, а не обрушить разбор.
let poisoned = """
{
  "five_hour":  {"utilization": "nan", "resets_at": "\(soon)"},
  "seven_day":  {"utilization": 62.0,  "resets_at": "\(later)"}
}
"""
if let u = UsageParser.parse(body: poisoned, fetchedAt: Date(), isStale: false) {
    check("испорченный лимит отброшен, целый остался", u.buckets.count == 1)
    check("остался именно недельный", u.bucket("seven_day") != nil)
    check("строка меню строится без падения", !BarTitle.render("{5h} {7d}", usage: u).isEmpty)
} else {
    check("разбор с одним испорченным лимитом не должен возвращать nil", false)
}

// Все лимиты испорчены - разбора нет, но и падения нет.
let allBad = "{\"five_hour\": {\"utilization\": \"nan\", \"resets_at\": \"\(soon)\"}}"
check("сплошь испорченный ответ не разбирается и не валит",
      UsageParser.parse(body: allBad, fetchedAt: Date(), isStale: false) == nil)

// exponent из pricing.json или из ответа может быть любым.
let wildExp = Extra(enabled: true, usedMinor: 13963, limitMinor: 20000,
                    exponent: 1_000_000, currency: "USD", percentGiven: nil)
check("огромный exponent не уводит формат в мегабайтную строку",
      wildExp.usedText.count < 20)
let negExp = Extra(enabled: true, usedMinor: 13963, limitMinor: 20000,
                   exponent: -5, currency: "USD", percentGiven: nil)
check("отрицательный exponent не даёт невалидный спецификатор",
      !negExp.usedText.isEmpty)


// ---- отсчёт до сброса ------------------------------------------------------
//
// «вот-вот» заменено числом: по «~1м» видно, успеваешь ты дописать запрос
// или нет, а по «вот-вот» - нет. Дробь по-прежнему ОТБРАСЫВАЕТСЯ: это
// остаток, и завышать его нельзя.
print("\nотсчёт до сброса")
func at(_ secs: Int) -> Date { return Date().addingTimeInterval(TimeInterval(secs) + 0.5) }
check("полминуты - это «~1м», а не «вот-вот»", Fmt.left(at(30)), L("~1м", "~1m"))
check("59 секунд тоже", Fmt.left(at(59)), L("~1м", "~1m"))
check("минута с секундами не округляется вверх", Fmt.left(at(119)), L("1м", "1m"))
check("две минуты", Fmt.left(at(120)), L("2м", "2m"))
check("часы с минутами", Fmt.left(at(2 * 3600 + 14 * 60)), L("2ч 14м", "2h 14m"))
check("сутки с часами", Fmt.left(at(27 * 3600)), L("1д 3ч", "1d 3h"))
check("нет времени сброса - прочерк, а не выдумка", Fmt.left(nil), "\u{2014}")
check("перед шкалой стоит голый отсчёт, без «через»",
      Fmt.untilReset(at(2 * 3600 + 14 * 60)), L("2ч 14м", "2h 14m"))

// ---- короткая запись чисел -------------------------------------------------
print("\nкороткая запись чисел")
check("миллионы с одним знаком после запятой", Fmt.compact(1_234_567), L("1,2м", "1.2M"))
check("тысячи целыми", Fmt.compact(12_345), L("12к", "12K"))
check("сотни как есть", Fmt.compact(999), "999")
// Живой случай 29.08.2026: недельный расход активного аккаунта - за
// миллиард токенов. Без этой ступени «1739,0м» читалось бы как ошибка
// в счёте, а не как крупное, но верное число.
check("миллиард переключает ступень на «млрд»",
      Fmt.compact(1_739_000_000), L("1,7млрд", "1.7B"))
check("девятьсот девять миллионов ещё не миллиард",
      Fmt.compact(999_000_000), L("999,0м", "999.0M"))

// ---- буква вместо имени модели ---------------------------------------------
print("\nбуквы моделей")
check("Opus - это O", a.bucket("seven_day_opus")?.tiny ?? "", "O")
check("Sonnet - это S", a.bucket("seven_day_sonnet")?.tiny ?? "", "S")
check("Fable - это F", a.bucket(UsageParser.fableKey)?.tiny ?? "", "F")
check("окно не сокращается: сокращать нечего",
      a.bucket("five_hour")?.tiny ?? "", L("5ч", "5h"))
// Порядок моделей - по алфавиту короткого имени, как и был: он не зависит
// от того, чем сегодня больше пользовались, и потому строка в трее не
// переставляется на глазах.
check("макрос моделей идёт буквами",
      BarTitle.render("{models}", usage: a),
      "F 0% \u{00B7} O 81% \u{00B7} S 12%")

// ---- токены ----------------------------------------------------------------
//
// Сколько токенов в тарифе, не публикует никто - ни справка, ни админ
// в Enterprise. Раньше мы это делили и получали «полный лимит»; теперь
// показываем только то, что прошло через видимые машины.
print("\nтокены")
let tv = TokensView(spent: 1_240_000)
check("токены - это расход, а не доля лимита", tv.text, L("1,2м", "1.2M"))
check("пусто, когда расхода нет", TokensView(spent: 0).isEmpty)
check("макрос токенов подставляется",
      BarTitle.render("{tokens}", usage: a, tokens: tv), L("1,2м", "1.2M"))
check("без токенов макрос не оставляет мусора",
      BarTitle.render("{5h} \u{00B7} {tokens}", usage: a), "37%")

// ---- перерасход выше потолка -----------------------------------------------
//
// Присланное utilization режется по сотне. Живой случай 28.08.2026:
// $200.17 из $100.00 приезжали как спокойные 100%.
print("\nперерасход")
let over = Extra(enabled: true, usedMinor: 20017, limitMinor: 10000,
                 exponent: 2, currency: "USD", percentGiven: 100)
check("двукратный перерасход не выглядит как ровно упёрся", "\(over.percent ?? -1)", "200")
let noLimit = Extra(enabled: true, usedMinor: 20017, limitMinor: nil,
                    exponent: 2, currency: "USD", percentGiven: 42)
check("без потолка берётся присланное", "\(noLimit.percent ?? -1)", "42")

// ---- шаблон из галочек -----------------------------------------------------
print("\nшаблон из галочек")
Prefs.showIcon = false; Prefs.showSession = true; Prefs.showLeft = true
Prefs.showWeekly = true; Prefs.showModels = false; Prefs.showTokens = false
Prefs.showExtra = false; Prefs.showMoney = false
let built = Prefs.defaultTemplateFromCheckboxes()
check("процент и остаток идут одним куском", built, "{5h} {5h.left} \u{00B7} {7d} {7d.left}")
// Проверяем по тому, что видно в трее, а не по тексту шаблона: «7d» есть
// и в самом макросе {7d}, и такая проверка прошла бы, ничего не проверив.
check("подписи «7д» перед процентом больше нет",
      !BarTitle.render(built, usage: a).contains(L("7д ", "7d ")))
check("галочка остатка действует на оба окна",
      BarTitle.render(built, usage: a).contains("62%"))
Prefs.showLeft = false
check("без остатка остаются одни проценты",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} \u{00B7} {7d}")
Prefs.showLeft = true

// ---- две машины ------------------------------------------------------------
//
// Лимит у аккаунта один, а расшифровки на каждой машине свои. Замер
// 28.08.2026: за одно недельное окно мак насчитал $258, сервер - $924.
print("\nдве машины")
var machineA = WindowUsage()
machineA.byFamily["opus"] = TokenTally(input: 100, output: 10, cacheWrite: 0, cacheRead: 0, requests: 1)
var machineB = WindowUsage()
machineB.byFamily["opus"] = TokenTally(input: 200, output: 20, cacheWrite: 0, cacheRead: 0, requests: 2)
machineB.byFamily["fable"] = TokenTally(input: 5, output: 5, cacheWrite: 0, cacheRead: 0, requests: 1)
machineB.truncated = true
let both = machineA + machineB
check("токены одной модели сложились", "\(both.byFamily["opus"]?.input ?? -1)", "300")
check("запросы тоже", "\(both.byFamily["opus"]?.requests ?? -1)", "3")
check("модель, которой не было у первой, добавилась", both.byFamily["fable"] != nil)
check("обрезание переносится: итог занижен у обоих", both.truncated)

let answer = """
{"windows": [{"families": {"opus": {"input": 1, "output": 2, "cache_write": 3,
 "cache_read": 4, "requests": 5}}, "unknown": ["<весёлая>"], "truncated": false}]}
"""
switch RemoteScan.parse(Data(answer.utf8), expected: 1) {
case .success(let a):
    check("ответ второй машины разобран", a.windows.count == 1)
    check("чтение из кэша не потерялось", "\(a.windows[0].byFamily["opus"]?.cacheRead ?? -1)", "4")
    check("незнакомые модели доехали", a.windows[0].unknownModels.contains("<весёлая>"))
    // Старая версия скрипта на той стороне сессий не пришлёт. Это не
    // повод отказаться от денег и токенов, которые пришли.
    check("ответ без сессий принимается, раздел просто пуст", a.sessions.isEmpty)
case .failure(let e):
    check("ответ второй машины разобран: \(e.text)", false)
}

let withSessions = """
{"windows": [{"families": {}, "unknown": [], "truncated": false}],
 "sessions": [{"pid": 4242, "name": "work-71", "cwd": "harness",
               "entrypoint": "sdk-cli", "status": "waiting",
               "waitingFor": "разрешение на запись"}]}
"""
switch RemoteScan.parse(Data(withSessions.utf8), expected: 1, host: "vps7") {
case .success(let a):
    check("серверная сессия доехала", a.sessions.count == 1)
    check("состояние разобрано", a.sessions.first?.state == .waiting)
    check("машина подписана адресом хоста", a.sessions.first?.machine ?? "", "vps7")
    // Живость на той стороне проверил тот же скрипт. Проверять pid
    // с сервера здесь нельзя: он либо не значит ничего, либо значит
    // чужой процесс на этой машине.
    check("живость серверной сессии тут не перепроверяется", a.sessions.count == 1)
case .failure(let e):
    check("серверная сессия доехала: \(e.text)", false)
}
switch RemoteScan.parse(Data("не json".utf8), expected: 1) {
case .success: check("мусор вместо ответа не принимается за ноль", false)
case .failure: check("мусор вместо ответа не принимается за ноль", true)
}
switch RemoteScan.parse(Data("{\"windows\": []}".utf8), expected: 2) {
case .success: check("ответ не на то число окон отвергается", false)
case .failure: check("ответ не на то число окон отвергается", true)
}

// ---- обновление ------------------------------------------------------------
print("\nобновление")
check("v убирается из тега", Version.number("v1.2.0"), "1.2.0")
check("1.2.0 новее 1.1.9", Version.isNewer("1.2.0", than: "1.1.9"))
check("1.10.0 новее 1.9.0, а не наоборот", Version.isNewer("1.10.0", than: "1.9.0"))
check("1.9.0 не новее 1.10.0", !Version.isNewer("1.9.0", than: "1.10.0"))
check("та же версия не новее себя", !Version.isNewer("1.1.2", than: "1.1.2"))
check("1.2 новее 1.1.9", Version.isNewer("1.2", than: "1.1.9"))
check("сборку из исходников релизом не подменяем", !Version.isNewer("1.2.0", than: "dev"))
let notes = """
Скачай `climits.zip`.

SHA-256 архива:
```
E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855
```
"""
check("сумма найдена в тексте релиза", Version.sha256(inNotes: notes) ?? "",
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("нет суммы - нет и обновления", Version.sha256(inNotes: "просто текст") == nil)


// ---- разбор ~/.ssh/config --------------------------------------------------
//
// Отсюда берётся выпадающий список адресов в настройках. Опечатка в адресе
// выглядит как «не работает», поэтому набирать его руками человек не должен.
print("\nразбор ~/.ssh/config")
let sshCfg = """
# комментарий
Host vps7
    HostName 51.38.110.54
    User babko

host  lowercase-тоже-хост
Host *
    ServerAliveInterval 60
Host bastion prod-web
  User deploy
Host !secret wildcard-?
  User x
Host=cравнение-через-равно
"""
let found = SSHConfig.hosts(inText: sshCfg)
check("обычная запись найдена", found.contains("vps7"))
check("регистр слова Host не важен", found.contains("lowercase-тоже-хост"))
check("две записи в одной строке - это два адреса",
      found.contains("bastion") && found.contains("prod-web"))
check("шаблон * не адрес", !found.contains("*"))
check("шаблон с ? не адрес", !found.contains("wildcard-?"))
check("отрицание не адрес", !found.contains("!secret"))
check("Host через знак равенства тоже разбирается", found.contains("cравнение-через-равно"))
check("комментарии не попали", !found.contains("#"))
check("HostName - это не Host", !found.contains("51.38.110.54"))
check("несуществующий файл даёт пустой список, а не падение",
      SSHConfig.hosts(at: URL(fileURLWithPath: "/nope/нет/config")).isEmpty)

// ---- отказ ssh словами -----------------------------------------------------
print("\nотказ ssh словами")
check("ключ не пущен",
      RemoteScan.explain("babko@x: Permission denied (publickey).") != nil)
check("незнакомый хост",
      RemoteScan.explain("Host key verification failed.") != nil)
check("имя не находится",
      RemoteScan.explain("ssh: Could not resolve hostname nope: Name or service not known") != nil)
check("нет python3 на той стороне",
      RemoteScan.explain("env: ‘python3’: No such file or directory") != nil)
check("незнакомую ошибку не выдумываем",
      RemoteScan.explain("что-то пошло не так, но что - неизвестно") == nil)



// ---- живой прайс -----------------------------------------------------------
//
// Встроенная таблица цен однажды начнёт врать МОЛЧА - это записано прямо
// в Pricing.swift. Здесь проверяется то, что должно эту молчаливость снять:
// разбор прайса LiteLLM. Ошибка тут не видна глазами - счёт, завышенный
// втрое, выглядит ровно так же убедительно, как правильный.
print("\nживой прайс")

// Сравнение дробных - через порог, а не «равно»: 4.1 в двоичной записи
// не представимо точно, и строгое равенство здесь ловило бы не ошибку
// разбора, а последний бит мантиссы.
func near(_ a: Double?, _ b: Double) -> Bool {
    guard let a = a else { return false }
    return abs(a - b) < 0.0001
}
check("версия из ключа с датой", near(PricingFeed.version(of: "claude-opus-4-1-20250805"), 4.1))
check("версия из старого имени", near(PricingFeed.version(of: "claude-3-5-sonnet-20241022"), 3.5))
check("версия без минорной", near(PricingFeed.version(of: "claude-opus-5"), 5.0))
check("восьмизначная дата за версию не принимается",
      PricingFeed.version(of: "claude-sonnet-20250101") == nil)
check("семейство из ключа", PricingFeed.family(ofKey: "claude-sonnet-4-5") ?? "", "sonnet")
check("чужая модель семейства не получает", PricingFeed.family(ofKey: "gpt-4o") == nil)

let feedJSON = """
{
  "claude-opus-4-20250514": {"litellm_provider": "anthropic",
     "input_cost_per_token": 0.000015, "output_cost_per_token": 0.000075},
  "claude-opus-5": {"litellm_provider": "anthropic",
     "input_cost_per_token": 0.000005, "output_cost_per_token": 0.000025,
     "cache_creation_input_token_cost": 0.00000625,
     "cache_read_input_token_cost": 0.0000005},
  "bedrock/claude-opus-5": {"litellm_provider": "bedrock",
     "input_cost_per_token": 0.000009, "output_cost_per_token": 0.000045},
  "gpt-5": {"litellm_provider": "openai",
     "input_cost_per_token": 0.00001, "output_cost_per_token": 0.00003},
  "claude-haiku-broken": {"litellm_provider": "anthropic",
     "input_cost_per_token": 0, "output_cost_per_token": 0}
}
"""
let feed = PricingFeed.parse(Data(feedJSON.utf8))

// Главное здесь: НЕ максимум по цене. У Opus 4 было $15/$75, у Opus 5 стало
// $5/$25 - выбор по «самой дорогой записи» дал бы прошлогоднюю модель
// и завысил счёт втрое, причём молча.
check("из двух версий Opus берётся старшая, а не дорогая", near(feed["opus"]?.input, 5.0))
check("выход тоже от старшей версии", near(feed["opus"]?.output, 25.0))
check("цена за токен переведена в цену за миллион", near(feed["opus"]?.cacheRead, 0.5))
check("запись кэша взята из файла, а не выведена", near(feed["opus"]?.cacheWrite, 6.25))
check("чужой провайдер не попадает вовсе", feed["openai"] == nil && feed.count == 1)
check("нулевая цена отбрасывается", feed["haiku"] == nil)

check("мусор вместо JSON даёт пустую таблицу",
      PricingFeed.parse(Data("не json".utf8)).isEmpty)
check("пустой объект даёт пустую таблицу", PricingFeed.parse(Data("{}".utf8)).isEmpty)

// Кэш пишется в нашем формате, а не исходником LiteLLM: тот весит мегабайты
// и почти весь про чужих провайдеров.
if let enc = PricingFeed.encode(feed, at: 1_700_000_000) {
    check("отметка времени переживает запись и чтение",
          near(PricingFeed.decodeStamp(enc), 1_700_000_000))
    let back = PricingFeed.parse(enc)
    check("наш собственный файл прайсом LiteLLM не считается", back.isEmpty)
} else {
    check("кэш прайса сериализуется", false)
}



// ---- столбики, темп, прогноз -----------------------------------------------
//
// Три разных ответа на три разных вопроса, и ни один из них не требует
// знать размер лимита - именно поэтому они и появились вместо экстраполяции.
print("\nстолбики, темп, прогноз")

check("столбики от максимума недели", Fmt.spark([1, 2, 4, 8]), "\u{2581}\u{2582}\u{2584}\u{2588}")
// Ноль и «немного» - разные ответы. Нижний блок читается как «немного»,
// поэтому пустой день рисуется точкой.
check("пустой день - точка, а не полоска", Fmt.spark([0, 8]), "\u{00B7}\u{2588}")
check("всё по нулям - одни точки", Fmt.spark([0, 0, 0]), "\u{00B7}\u{00B7}\u{00B7}")
check("день с одним запросом всё равно виден", Fmt.spark([1, 1_000_000]).first != "\u{00B7}")
check("пустой список не ломает", Fmt.spark([]), "")

// ---- заливка нарисованной полоски ------------------------------------------
//
// Единственная арифметика капсулы. Само рисование не проверяется ничем -
// AppKit на Linux нет, - поэтому весь счёт вынесен сюда, где он виден.
print("\nполоска лимита")

check("пусто - это пусто, а не ниточка", Fmt.fillWidth(pct: 0, total: 50, minVisible: 6), 0.0)
check("половина - половина", Fmt.fillWidth(pct: 50, total: 50, minVisible: 6), 25.0)
check("сто процентов - вся длина", Fmt.fillWidth(pct: 100, total: 50, minVisible: 6), 50.0)
// 1% от пятидесяти точек - полточки, то есть невидимо. Начавшееся окно
// не должно выглядеть как нетронутое.
check("один процент виден", Fmt.fillWidth(pct: 1, total: 50, minVisible: 6), 6.0)
check("процент больше порога видимости не подтягивается",
      Fmt.fillWidth(pct: 40, total: 50, minVisible: 6), 20.0)
check("мусор снизу зажимается", Fmt.fillWidth(pct: -20, total: 50, minVisible: 6), 0.0)
check("мусор сверху тоже", Fmt.fillWidth(pct: 300, total: 50, minVisible: 6), 50.0)
// Короткая полоска не должна вылезать за собственную длину: длину меняет
// настройка, а порог видимости считается от толщины.
check("порог видимости не длиннее самой полоски",
      Fmt.fillWidth(pct: 1, total: 4, minVisible: 6), 4.0)

// Сутки берутся у календаря: при переходе на летнее время они длиной
// 23 и 25 часов, и вычитание 86400 разъехалось бы дважды в год.
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let noon = Date(timeIntervalSince1970: 1_700_000_000)
let cuts = Trend.dayCutoffs(days: 7, now: noon, calendar: utc)
check("семь границ на семь дней", cuts.count == 7)
check("границы идут от старых к свежим", cuts == cuts.sorted())
check("последняя граница - сегодняшняя полночь",
      utc.startOfDay(for: noon) == cuts.last)
check("между границами ровно сутки",
      cuts[1].timeIntervalSince(cuts[0]) == 86400)

// Вычитание вложенных окон: «с понедельника» минус «со вторника» = понедельник.
func win(_ family: String, _ n: Int) -> WindowUsage {
    var w = WindowUsage()
    w.byFamily[family] = TokenTally(input: n, output: 0, cacheWrite: 0, cacheRead: 0, requests: 1)
    return w
}
let cumulative = [win("opus", 100), win("opus", 60), win("opus", 25)]
let perDay = Trend.split(cumulative)
check("первые сутки - разность окон", perDay[0].totals.total == 40)
check("вторые сутки - тоже разность", perDay[1].totals.total == 35)
check("последние сутки берутся как есть", perDay[2].totals.total == 25)
check("суммы сходятся с исходным окном",
      perDay.reduce(0) { $0 + $1.totals.total } == 100)

check("темп за час", Trend.perHour(tokens: 120_000, over: 3600) == 120_000)
check("темп за полчаса пересчитан в час", Trend.perHour(tokens: 60_000, over: 1800) == 120_000)
// На трёх минутах один длинный ответ модели превращается в «два миллиона
// в час». Это не темп, а всплеск, и ответ здесь - «пока не знаю».
check("на трёх минутах темпа нет", Trend.perHour(tokens: 100_000, over: 180) == nil)
check("без расхода темпа нет", Trend.perHour(tokens: 0, over: 3600) == nil)

let reset2h = noon.addingTimeInterval(2 * 3600)
check("к сбросу набежит потрачено плюс темп на остаток",
      near(Trend.projected(spent: 10, perHour: 5, until: reset2h, now: noon), 20.0))
check("без времени сброса прогноза нет",
      Trend.projected(spent: 10, perHour: 5, until: nil, now: noon) == nil)
check("сброс в прошлом прогноза не даёт",
      Trend.projected(spent: 10, perHour: 5, until: noon.addingTimeInterval(-60), now: noon) == nil)

// Прогноз по процентам. Проценты делятся на проценты - размер лимита
// в этой арифметике не участвует вовсе.
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func sample(_ minutes: Double, _ pct: Int, _ key: String = "five_hour") -> PctSample {
    return PctSample(at: t0.addingTimeInterval(minutes * 60), key: key, pct: pct)
}
let straight = [sample(0, 40), sample(30, 46), sample(60, 52)]
check("темп в процентах за час", near(History.rate(straight, key: "five_hour"), 12.0))
check("чужой лимит темпа не даёт", History.rate(straight, key: "seven_day") == nil)
// Меньше четверти часа - шум: между соседними замерами процент часто
// не меняется вовсе.
check("на пяти минутах темпа нет",
      History.rate([sample(0, 40), sample(5, 41)], key: "five_hour") == nil)
check("падение процента темпа не даёт",
      History.rate([sample(0, 90), sample(60, 5)], key: "five_hour") == nil)

// Сброс окна - это падение процента, а не отрицательный расход. Считать
// наклон через границу окна значит получить «расход идёт назад».
let acrossReset = [sample(0, 80), sample(60, 90), sample(120, 4), sample(180, 16)]
check("после сброса считаем заново, а не через границу",
      near(History.rate(acrossReset, key: "five_hour"), 12.0))
check("сегмент начинается после сброса",
      History.currentSegment(acrossReset, key: "five_hour").count == 2)

let hit = History.hitsFull(pct: 52, rate: 12.0, now: t0)
check("до сотни при 12% в час - четыре часа",
      hit.map { Int($0.timeIntervalSince(t0) / 60) } == 240)
check("на сотне прогноза нет", History.hitsFull(pct: 100, rate: 12.0, now: t0) == nil)
// Темп 0.1% в час дал бы «упрёшься через сорок суток». Это не прогноз,
// а деление на почти ноль.
check("почти нулевой темп прогноза не даёт",
      History.hitsFull(pct: 50, rate: 0.05, now: t0) == nil)
check("успеваем, если сброс раньше",
      History.beatsReset(hit: t0.addingTimeInterval(3600),
                         reset: t0.addingTimeInterval(1800)) == true)
check("не успеваем, если сброс позже",
      History.beatsReset(hit: t0.addingTimeInterval(1800),
                         reset: t0.addingTimeInterval(3600)) == false)

check("старьё выбрасывается",
      History.prune([sample(0, 10), sample(-20 * 24 * 60, 10)], now: t0).count == 1)
if let enc = History.encode(straight) {
    check("замеры переживают запись и чтение", History.decode(enc) == straight)
} else {
    check("замеры сериализуются", false)
}



// ---- предложенные значения -------------------------------------------------
//
// Поля вида - свободный текст, и по пустому полю не догадаться, что туда
// вписывают. Список подсказывает; проверяется здесь то, что из него нельзя
// выбрать заведомо сломанное значение.
print("\nпредложенные значения")

check("пояснение снимается", Presets.value(of: Presets.item("\u{25CF}", "кружок")), "\u{25CF}")
// Человек мог не выбирать из списка, а вписать своё - тогда возвращаем
// вписанное как есть.
check("своё значение остаётся собой", Presets.value(of: "\u{25D4},\u{25D1},\u{25D5}"),
      "\u{25D4},\u{25D1},\u{25D5}")
check("значение с дефисом внутри не режется", Presets.value(of: "a-b"), "a-b")

// Набор кружков из двух или четырёх знаков приложение молча отбросит
// и возьмёт свой - то есть выбор из списка выглядел бы как «не работает».
for item in Presets.iconSet {
    let parts = Presets.value(of: item).split(separator: ",")
    check("набор кружков «\(Presets.value(of: item))» - ровно три знака",
          parts.count == 3 && parts.allSatisfy { !$0.isEmpty })
}
for item in Presets.barFilled + Presets.barEmpty {
    check("знак шкалы не пуст", !Presets.value(of: item).isEmpty)
}
check("у каждого предложенного есть пояснение",
      (Presets.barFilled + Presets.barEmpty + Presets.iconSet + Presets.fontName
        + Presets.templates).allSatisfy { $0.contains(Presets.separator) })

// Предложенный формат обязан давать осмысленную строку: макрос с опечаткой
// вырезался бы молча, и человек увидел бы полупустую строку меню.
for item in Presets.templates {
    let t = Presets.value(of: item)
    let rendered = BarTitle.render(t, usage: a,
                                   money: MoneyView.make(spent: 12.0, partial: true),
                                   tokens: TokensView(spent: 1_240_000))
    check("формат «\(t)» даёт непустую строку", !rendered.isEmpty)
    check("и в ней не остаётся фигурных скобок", !rendered.contains("{"))
}



// ---- конструктор шаблона ---------------------------------------------------
//
// Галочка при включённом «своём формате» ДОПОЛНЯЕТ строку, а не заменяет.
// До этого любая галочка выключала свой формат и затирала написанное:
// человек, собравший строку руками, терял её от одного случайного клика.
print("\nконструктор шаблона")

check("в пустую строку кладём как есть", TemplateEdit.add(["{5h}"], to: ""), "{5h}")
check("к готовой строке - через разделитель",
      TemplateEdit.add(["{extra}"], to: "{5h}"), "{5h} \u{00B7} {extra}")
// Кружок - индикатор, а не число: его место слева от всего.
check("кружок встаёт слева", TemplateEdit.add(["{icon}"], to: "{5h}"), "{icon} {5h}")
// Время идёт вплотную к своему проценту: «57% 5м · 92% 1д3ч» читается
// как два окна, а «57% · 5м · 92% · 1д3ч» - как четыре числа подряд.
check("время прижато к своему проценту",
      TemplateEdit.add(["{5h}", "{5h.left}"], to: ""), "{5h} {5h.left}")
check("повторно тот же макрос не добавляется",
      TemplateEdit.add(["{5h}"], to: "{icon} {5h}"), "{icon} {5h}")

check("снятое убирается вместе с разделителем",
      TemplateEdit.remove(["{7d}", "{7d.left}"], from: "{5h} \u{00B7} {7d} {7d.left}"), "{5h}")
check("снятое из середины не оставляет дыры",
      TemplateEdit.remove(["{extra}"], from: "{5h} \u{00B7} {extra} \u{00B7} {7d}"),
      "{5h} \u{00B7} {7d}")
check("снятие последнего оставляет пусто",
      TemplateEdit.remove(["{5h}"], from: "{5h}"), "")

check("галочка окна знает про своё время",
      TemplateEdit.macros(for: "showSession", withLeft: true) == ["{5h}", "{5h.left}"])
check("без времени - только процент",
      TemplateEdit.macros(for: "showSession", withLeft: false) == ["{5h}"])
// Деньги, токены и история в строку меню не идут по отдельному правилу,
// и конструктор его не обходит.
check("деньги галочкой в шаблон не попадают",
      TemplateEdit.macros(for: "showMoney", withLeft: true).isEmpty)
check("история тоже", TemplateEdit.macros(for: "showHistory", withLeft: true).isEmpty)

// ---- время до сброса у «упрётся первым» ------------------------------------
//
// «7д 62%» не отвечает, шесть часов до сброса или три дня, а решение
// «работать дальше или подождать» держится ровно на этом.
print("\nвремя у активного лимита")
check("активный лимит показывает и время",
      !BarTitle.render("{active} {active.left}", usage: a).isEmpty)
check("и не оставляет фигурных скобок",
      !BarTitle.render("{active} {active.left} \u{00B7} {active.reset}", usage: a).contains("{"))
check("у самого нагруженного время тоже есть",
      !BarTitle.render("{worst.left}", usage: a).isEmpty)
// Пустое время не должно оставлять висящий разделитель.
check("без времени разделитель не висит",
      BarTitle.render("{5h} \u{00B7} {nonexistent}", usage: a), "37%")


// ---- деньги и токены не просачиваются в трей -------------------------------
//
// В строке меню места три-четыре знака, и заняты они тем, что отвечает на
// «работать дальше или подождать»: процентом и временем до сброса. Деньги,
// токены и история отвечают на другой вопрос и живут в выпадающем меню.
print("\nденьги и токены не просачиваются в трей")
Prefs.showMoney = true
Prefs.showTokens = true
Prefs.showHistory = true
let withBoth = Prefs.defaultTemplateFromCheckboxes()
check("галочка «Деньги» не добавляет {money} в трей", !withBoth.contains("{money}"))
check("галочка «Токены» не добавляет {tokens} в трей", !withBoth.contains("{tokens}"))
// Выключенный процент не должен уносить с собой время до сброса: без него
// строка вообще перестаёт отвечать на «когда отпустит».
Prefs.showSession = false
Prefs.showLeft = true
let noPct = Prefs.defaultTemplateFromCheckboxes()
check("без процента остаётся время до сброса", noPct.contains("{5h.left}"))
check("а самого процента в строке нет", !noPct.contains("{5h}"))
Prefs.showSession = true
Prefs.showHistory = false
Prefs.showMoney = false
Prefs.showTokens = false


// ---- галочки собирают всю строку -------------------------------------------
//
// «Доступно, если знаешь имя макроса и впишешь его руками» - это не
// доступно: имя надо где-то увидеть, а увидеть его было негде, кроме
// README. Теперь у каждого куска есть галочка.
print("\nгалочки собирают всю строку")

Prefs.showIcon = false
Prefs.showSession = true
Prefs.showLeft = true
Prefs.showWeekly = false
Prefs.showModels = false
Prefs.showExtra = false
Prefs.showWorst = false
Prefs.showActive = false
Prefs.showResetClock = false
Prefs.showExtraPct = false

check("окно и время", Prefs.defaultTemplateFromCheckboxes(), "{5h} {5h.left}")
// Часы сброса цепляются к своему окну, а не встают отдельным куском:
// «пн 03:00» в отрыве от процента не говорит, чей это сброс.
Prefs.showResetClock = true
check("часы сброса прижаты к окну",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} {5h.left} {5h.reset}")
Prefs.showResetClock = false

Prefs.showActive = true
check("«что упрётся первым» со своим временем",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} {5h.left} \u{00B7} {active} {active.left}")
Prefs.showResetClock = true
check("и со своими часами",
      Prefs.defaultTemplateFromCheckboxes(),
      "{5h} {5h.left} {5h.reset} \u{00B7} {active} {active.left} {active.reset}")
Prefs.showActive = false
Prefs.showResetClock = false

Prefs.showWorst = true
check("самый нагруженный - тоже со временем",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} {5h.left} \u{00B7} {worst} {worst.left}")
Prefs.showLeft = false
check("без времени - только он сам",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} \u{00B7} {worst}")
Prefs.showLeft = true
Prefs.showWorst = false

Prefs.showExtra = true
Prefs.showExtraPct = true
check("процент перерасхода идёт после самой суммы",
      Prefs.defaultTemplateFromCheckboxes(), "{5h} {5h.left} \u{00B7} {extra} \u{00B7} {extra.pct}")
Prefs.showExtra = false
Prefs.showExtraPct = false

// Конструктор знает про новые галочки: без этого тик по ним при включённом
// «своём формате» не делал бы ничего.
check("конструктор знает «что упрётся первым»",
      TemplateEdit.macros(for: "showActive", withLeft: true) == ["{active}", "{active.left}"])
check("и самый нагруженный",
      TemplateEdit.macros(for: "showWorst", withLeft: false) == ["{worst}"])
check("и часы сброса",
      TemplateEdit.macros(for: "showResetClock", withLeft: true) == ["{5h.reset}"])
check("и процент перерасхода",
      TemplateEdit.macros(for: "showExtraPct", withLeft: true) == ["{extra.pct}"])

// Всё собранное галочками обязано давать осмысленную строку - без
// висящих скобок и пустых разделителей.
Prefs.showIcon = true
Prefs.showWeekly = true
Prefs.showWorst = true
Prefs.showActive = true
Prefs.showModels = true
Prefs.showExtra = true
Prefs.showExtraPct = true
Prefs.showResetClock = true
let everything = BarTitle.render(Prefs.defaultTemplateFromCheckboxes(), usage: a)
check("всё сразу рисуется без скобок", !everything.contains("{"))
check("и не пусто", !everything.isEmpty)


// ---- срок жизни кэша и быстрый режим ---------------------------------------
//
// Два места, где приложение молча занижало расход. Найдены 29.08.2026 не
// глазами, а сверкой: реконструкция стоимости восьми парных прогонов из
// токенов дала $4.71 против $5.75, названных самим Claude Code. Разница
// целиком объяснилась ценой записи в кэш.
print("\nсрок жизни кэша и быстрый режим")

let opusP = Pricing.price(for: "claude-opus-5")
check("пятиминутная запись - вход x1.25", "\(opusP.cacheWrite)", "6.25")
check("часовая запись - вход x2", "\(opusP.cacheWrite1h)", "10.0")

// Миллион записанных в кэш токенов: по старой цене $6.25, по часовой $10.
let write5m = TokenTally(input: 0, output: 0, cacheWrite: 1_000_000,
                         cacheRead: 0, requests: 1, cacheWrite1h: 0)
let write1h = TokenTally(input: 0, output: 0, cacheWrite: 1_000_000,
                         cacheRead: 0, requests: 1, cacheWrite1h: 1_000_000)
check("миллион пятиминутной записи", MoneyView.money(write5m.cost(opusP)), "$6.25")
check("миллион часовой записи", MoneyView.money(write1h.cost(opusP)), "$10")

// Смешанное сообщение: половина туда, половина сюда.
let mixed = TokenTally(input: 0, output: 0, cacheWrite: 1_000_000,
                       cacheRead: 0, requests: 1, cacheWrite1h: 500_000)
// $8.125 округляется к чётному - это поведение форматтера, не счёта.
check("половина на половину", MoneyView.money(mixed.cost(opusP)), "$8.12")

// Битые данные не должны давать отрицательное слагаемое.
let broken = TokenTally(input: 0, output: 0, cacheWrite: 1_000_000,
                        cacheRead: 0, requests: 1, cacheWrite1h: 9_000_000)
check("часовая доля больше всей записи - зажимается",
      MoneyView.money(broken.cost(opusP)), "$10")

// Старые записи без разбивки считаются как раньше, а не в ноль.
let legacy = TokenTally(input: 0, output: 0, cacheWrite: 1_000_000, cacheRead: 0, requests: 1)
check("без разбивки - по пятиминутной цене", MoneyView.money(legacy.cost(opusP)), "$6.25")

let fastP = Pricing.price(for: "opus-fast")
check("быстрый режим вдвое дороже по входу", "\(fastP.input)", "10.0")
check("и по выходу", "\(fastP.output)", "50.0")
check("обычный ключ остался прежним", "\(Pricing.price(for: "opus").input)", "5.0")
// Незнакомое семейство с суффиксом не должно проваливаться в sonnet:
// это занизило бы втрое, а не на надбавку.
check("незнакомый быстрый не падает на запасную цену",
      Pricing.price(for: "haiku-fast").input == Pricing.price(for: "haiku").input)

// Разбор живой формы записи: разбивка лежит в usage.cache_creation,
// признак быстрого режима - в usage.speed.
let tmp2 = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("climits-cache-ttl-test", isDirectory: true)
try? FileManager.default.removeItem(at: tmp2)
try? FileManager.default.createDirectory(at: tmp2.appendingPathComponent("proj"),
                                         withIntermediateDirectories: true)
let jsonl2 = [
  "{\"timestamp\":\"\(iso(-600))\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"cache_creation_input_tokens\":16350,\"cache_creation\":{\"ephemeral_1h_input_tokens\":16350,\"ephemeral_5m_input_tokens\":0},\"speed\":\"standard\"}}}",
  "{\"timestamp\":\"\(iso(-500))\",\"message\":{\"id\":\"m2\",\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":7,\"output_tokens\":9,\"speed\":\"fast\"}}}",
].joined(separator: "\n")
try? jsonl2.write(to: tmp2.appendingPathComponent("proj/session.jsonl"),
                  atomically: true, encoding: .utf8)
let win2 = Transcripts.usage(since: Date().addingTimeInterval(-3600), dir: tmp2)
check("часовая запись вычитана из разбивки", "\(win2.byFamily["opus"]?.cacheWrite1h ?? -1)", "16350")
check("общее поле записи тоже на месте", "\(win2.byFamily["opus"]?.cacheWrite ?? -1)", "16350")
check("быстрый режим ушёл в своё семейство", win2.byFamily["opus-fast"] != nil)
check("и не смешался с обычным", "\(win2.byFamily["opus"]?.output ?? -1)", "20")
try? FileManager.default.removeItem(at: tmp2)


// ---- запись из связки ключей -----------------------------------------------
//
// Разбор записи проверяется на записи ТОГО ЖЕ размера и строения, что на
// живой машине: у активного пользователя к токену Claude Code примешана
// гора mcpOAuth, и запись выходит за двадцать килобайт. Повод к проверке
// был настоящий: 06.09.2026 приложение сказало «запись есть, но токен из
// неё не читается» ровно на такой записи.
print("\nсвязка ключей")

var mcp: [String: Any] = [:]
for i in 0..<60 {
    mcp["plugin:group\(i):srv|\(String(format: "%016x", i))"] = [
        "accessToken": String(repeating: "a", count: 220),
        "clientId": "cid-\(i)",
        "discoveryState": ["authorizationServerUrl": "https://example.com/\(i)",
                           "oauthMetadataFound": true],
        "serverName": "srv\(i)",
    ]
}
let far = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
let nested: [String: Any] = [
    "claudeAiOauth": [
        "accessToken": "sk-ant-oat01-" + String(repeating: "x", count: 300),
        "expiresAt": far,
        "refreshToken": "sk-ant-ort01-" + String(repeating: "y", count: 300),
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "team",
    ],
    "mcpOAuth": mcp,
]
let bigRaw = String(data: try! JSONSerialization.data(withJSONObject: nested), encoding: .utf8)!
check("запись за 20 килобайт разбирается", bigRaw.count > 20_000)
check("токен вынут из большой записи", "\(Keychain.parse(bigRaw)?.value.count ?? 0)", "313")
check("живой токен не считается истёкшим", Keychain.parse(bigRaw)?.isExpired == false)

// Срок приходит в МИЛЛИСЕКУНДАХ. Без деления дата уезжает в 57-й тысячный
// год, и «истёк ли токен» перестаёт значить что-либо.
let stale = ["claudeAiOauth": ["accessToken": "tok", "expiresAt": 1_600_000_000_000.0]]
let staleRaw = String(data: try! JSONSerialization.data(withJSONObject: stale), encoding: .utf8)!
check("истёкший токен виден истёкшим", Keychain.parse(staleRaw)?.isExpired == true)

// Плоская форма и голый токен - обе встречались на живых машинах.
check("плоская форма тоже разбирается",
      Keychain.parse("{\"accessToken\": \"tok-flat\"}")?.value ?? "", "tok-flat")
check("запись без обёртки - это сам токен",
      Keychain.parse("sk-ant-oat01-abc")?.value ?? "", "sk-ant-oat01-abc")
check("битый JSON не выдаётся за токен", Keychain.parse("{\"accessToken\":") == nil)

// Почему не разобралось. Настоящий случай 06.09.2026: поле accessToken в
// записи есть, отчёт это показывает, а токена нет - и по отчёту нельзя
// понять, чинить логином или приложением.
check("у целой записи причины нет", Keychain.why(bigRaw) == nil)
check("пустой токен назван пустым",
      Keychain.why("{\"claudeAiOauth\":{\"accessToken\":\"\"}}") ?? "",
      L("accessToken пустой", "accessToken is empty"))
check("не строка названа не строкой",
      Keychain.why("{\"claudeAiOauth\":{\"accessToken\":12345}}") ?? "",
      L("accessToken не строка", "accessToken is not a string"))
check("нет поля - так и сказано",
      Keychain.why("{\"claudeAiOauth\":{\"expiresAt\":1}}") ?? "",
      L("нет поля accessToken", "no accessToken field"))
check("не JSON назван не JSON", Keychain.why("хлам") ?? "", L("запись не JSON", "entry is not JSON"))

// Выкладка строения не должна выносить наружу ни одного значения строки -
// её копируют в чат целиком.
let shape = Keychain.structure(bigRaw)
check("в выкладке нет самого токена", !shape.contains("sk-ant-oat01-"))
check("и нет чужих токенов из mcpOAuth", !shape.contains(String(repeating: "a", count: 220)))
check("длина токена видна", shape.contains("claudeAiOauth.accessToken=" + L("строка 313", "string 313")))
check("посторонние разделы свёрнуты в счёт",
      shape.contains(L("mcpOAuth: 60 разделов", "mcpOAuth: 60 sections")))
// Ради этого всё и затевалось: с телефона выкладка должна читаться целиком.
check("выкладка короткая, а не двадцать килобайт", shape.count < 500)

// ---- обрезка имени лимита ----------------------------------------------
// Ширина колонки имени считается по самому длинному имени, а имя приходит
// снаружи: ключ API или заголовок от Anthropic. Без верхней границы меню
// растягивается ровно настолько, насколько длинно назовут следующую модель.
print("\nобрезка имени")
check("короткое имя не трогаем", Fmt.clip("Opus", 10), "Opus")
check("ровно по границе не трогаем", Fmt.clip("Sonnet 4.5", 10), "Sonnet 4.5")
check("длинное обрезается с многоточием", Fmt.clip("Claude Opus Extended", 10), "Claude Op\u{2026}")
check("считаем знаки, а не байты", Fmt.clip("Неделя, всего", 10), "Неделя, в\u{2026}")
check("многоточие занимает один знак", Fmt.clip("abcdefghijklm", 10).count == 10)
check("пустое имя переживает обрезку", Fmt.clip("", 10), "")
check("граница 1 не роняет", Fmt.clip("abc", 1), "abc")


// ---- сессии: кто работает, кто ждёт ----------------------------------------
//
// Главное здесь - не потерять разницу между «сказано, что простаивает» и
// «статуса нет». Свалив их в одно, раздел показывал бы вечное
// «простаивает» на сессиях, про которые нам ничего не говорили, - и это
// был бы индикатор, который ничего не измеряет, а выглядит как измеряющий.
print("\nсессии")

// Ровно та форма, что лежит на этой машине: 7 живых файлов, CLI 2.1.241.
// Полей status/tempo/waitingFor в ней НЕТ - они пишутся условно.
let sdkSession: [String: Any] = [
    "pid": 998885, "cwd": "/home/babko/Work", "name": "work-71",
    "entrypoint": "sdk-cli", "kind": "interactive", "startedAt": 1788741838489,
]
if let s = Sessions.parse(json: sdkSession) {
    check("без статуса это «неизвестно», а не «простаивает»", s.state == .unknown)
    check("имя берётся из файла", s.name, "work-71")
    check("sdk-запуск назван своим словом", s.surface, "SDK")
    check("время статуса без поля пусто", s.since == nil)
} else {
    check("запись без статуса всё равно разобрана", false)
}

let waiting: [String: Any] = [
    "pid": 1, "cwd": "/tmp/budget-app", "name": "bapp",
    "entrypoint": "cli", "status": "waiting", "waitingFor": "разрешение",
    "statusUpdatedAt": Date().addingTimeInterval(-180).timeIntervalSince1970 * 1000,
]
if let s = Sessions.parse(json: waiting) {
    check("ждёт человека", s.state == .waiting)
    check("чего именно ждёт - доехало", s.waitingFor ?? "", "разрешение")
    check("терминал назван терминалом", s.surface, "Terminal")
} else {
    check("ждущая сессия разобрана", false)
}

// tempo - нормализованная форма того же самого; она главнее status.
check("tempo=blocked это «ждёт»",
      Sessions.parse(json: ["pid": 2, "cwd": "/x", "tempo": "blocked"])?.state == .waiting)
check("tempo=active это «работает»",
      Sessions.parse(json: ["pid": 3, "cwd": "/x", "tempo": "active"])?.state == .busy)
// Незнакомое значение - это «сказали, но не то, что мы знаем». Не unknown:
// про эту сессию нам ответили, просто словом, которого мы не понимаем.
check("незнакомый статус не выдаётся за отсутствие статуса",
      Sessions.parse(json: ["pid": 4, "cwd": "/x", "status": "мурлычет"])?.state == .idle)
check("без pid это не запись о сессии", Sessions.parse(json: ["cwd": "/x"]) == nil)
check("без cwd тоже", Sessions.parse(json: ["pid": 5]) == nil)
// Чужая программа отдаёт числа то Int, то строкой - оба раза это pid.
check("pid строкой тоже читается",
      Sessions.parse(json: ["pid": "77", "cwd": "/x"])?.pid == 77)

let mix = [
    AgentSession(pid: 1, name: "a", folder: "a", surface: "", state: .idle,
                 waitingFor: nil, since: nil, machine: ""),
    AgentSession(pid: 2, name: "b", folder: "b", surface: "", state: .waiting,
                 waitingFor: "ответ", since: nil, machine: ""),
    AgentSession(pid: 3, name: "c", folder: "c", surface: "", state: .busy,
                 waitingFor: nil, since: nil, machine: ""),
    AgentSession(pid: 4, name: "d", folder: "d", surface: "", state: .unknown,
                 waitingFor: nil, since: nil, machine: ""),
]
let order = Sessions.sorted(mix).map { $0.pid }
check("первым идёт то, что требует действия", "\(order)", "[2, 3, 1, 4]")

let sum = Sessions.summary(mix)
check("сводка считает по состояниям", "\(sum.waiting)/\(sum.busy)/\(sum.idle)/\(sum.unknown)",
      "1/1/1/1")
check("в сводке сначала ждущие", sum.text.hasPrefix(L("ждёт меня 1", "waiting 1")))
// Пустая сводка при одних unknown читалась бы как «никто не работает».
let onlyUnknown = Sessions.summary([mix[3]])
check("одни unknown не молчат", !onlyUnknown.text.isEmpty)
check("одни unknown не выдаются за простой", !onlyUnknown.text.contains(L("работает", "working")))
check("а вот один простаивающий сводке сказать нечего", Sessions.summary([mix[0]]).text, "")

// Раздел, который каждый раз отвечает «не знаю», хуже отсутствующего:
// объяснение этому месту - в --doctor, а не в пяти одинаковых строках.
let allUnknown = Sessions.lines([mix[3]])
check("одни unknown - раздела нет совсем", allUnknown.rows.isEmpty && allUnknown.header.isEmpty)
check("но при смешанном составе раздел есть",
      !Sessions.lines([mix[1], mix[3]]).rows.isEmpty)

let lines = Sessions.lines(mix, nameLimit: 10, remoteHost: "vps7", remoteScanAt: Date())
check("указатель стоит у ждущего", lines.rows.first?.hasPrefix("\u{25B8}") ?? false)
check("у остальных указателя нет", lines.rows.dropFirst().allSatisfy { !$0.hasPrefix("\u{25B8}") })
check("про неизвестный статус сказано словами",
      lines.notes.contains { $0.contains(L("без статуса", "without status")) })
// Оговорка про сервер появляется только если серверные строки в списке есть.
check("нет серверных сессий - нет и оговорки про обход",
      !lines.notes.contains { $0.contains("vps7") })

// Ширина строки не должна зависеть от того, как чужая программа назовёт
// проект или чего попросит. Рост ширины меню от содержимого закрывался
// в 1.6.2 - завести его заново с другой стороны нельзя.
let longest = Sessions.lines([
    AgentSession(pid: 7, name: "budget-app", folder: "budget-app",
                 surface: "Terminal", state: .waiting,
                 waitingFor: "разрешение на запись в каталог проекта",
                 since: Date().addingTimeInterval(-260), machine: "vps7-длинный-адрес")])
check("строка сессии не шире предела",
      longest.rows.allSatisfy { $0.count <= Sessions.maxLine })
check("оговорка не шире строк сессий",
      longest.notes.allSatisfy { $0.count <= Sessions.maxLine + 8 })
// Жертвуем «через что запущено», а не тем, чего сессия хочет.
let tight = Sessions.composeLine(mark: "\u{25B8} ", machine: "vps7",
                                 name: "budget-app", surface: "Terminal",
                                 state: "ждёт меня", waitingFor: "разрешение на запись",
                                 age: "4м")
check("длинной строке «через что» не досталось", !tight.contains("Terminal"))
// Возраст важнее текста просьбы: он один говорит, насколько всё плохо.
check("сколько ждёт - уцелело", tight.contains("4м"))
check("а просьба урезана, а не выкинута", tight.contains("разреш"))
check("строка всё равно в пределе", tight.count <= Sessions.maxLine)
// Совсем нет места на просьбу - лучше без неё, чем огрызок в три знака.
let noRoom = Sessions.composeLine(mark: "\u{25B8} ", machine: "очень-длинный-хост",
                                  name: "имя-проекта", surface: "",
                                  state: "ждёт меня", waitingFor: "разрешение", age: "12ч 30м")
check("огрызка просьбы не остаётся", !noRoom.hasSuffix(":") && noRoom.count <= Sessions.maxLine)
// Короткой строке хватает места на всё.
let roomy = Sessions.composeLine(mark: "  ", machine: "", name: "cl",
                                 surface: "VS Code", state: "работает",
                                 waitingFor: nil, age: "1м")
check("короткой строке «через что» досталось", roomy.contains("VS Code"))

var many: [AgentSession] = []
for i in 1...20 {
    many.append(AgentSession(pid: i, name: "s\(i)", folder: "f", surface: "",
                             state: .busy, waitingFor: nil, since: nil, machine: ""))
}
let capped = Sessions.lines(many)
check("список не растёт без предела", capped.rows.count == Sessions.maxRows + 1)
check("и говорит, сколько скрыл",
      capped.rows.last?.contains(L("и ещё 14", "14 more")) ?? false)

// Мёртвый pid: файл остаётся лежать после падения процесса, и без проверки
// живости трей показывал бы «работает» на сессии, которой нет неделю.
check("pid 0 не живой", !Sessions.isAlive(pid: 0))
check("свой процесс живой", Sessions.isAlive(pid: Int(getpid())))

// ---- возраст против остатка ------------------------------------------------
// Две функции, потому что округлять их надо в разные стороны: остаток
// нельзя завышать, возраст нельзя занижать.
print("\nвозраст")
check("59 секунд ожидания - это уже не ноль", Fmt.ago(Date().addingTimeInterval(-59)),
      L("<1м", "<1m"))
check("три минуты", Fmt.ago(Date().addingTimeInterval(-185)), L("3м", "3m"))
check("часы с минутами", Fmt.ago(Date().addingTimeInterval(-3600 - 120)),
      L("1ч 02м", "1h 02m"))
check("сутки с часами", Fmt.ago(Date().addingTimeInterval(-86400 - 7200)),
      L("1д 2ч", "1d 2h"))
check("будущее не даёт отрицательного возраста",
      Fmt.ago(Date().addingTimeInterval(600)), L("<1м", "<1m"))

// ---- вёрстка кольца --------------------------------------------------------
//
// Числа кольца проверяются здесь по той же причине, по которой вынесены
// из рисовалки: Мака нет, посмотреть нельзя, а AppKit на Linux не
// типизируется вовсе. Это единственная проверка кольца до чужой машины.
print("\nкольцо в строке меню")
check("ноль - пустое кольцо, а не волосок", Layout.ringSweep(pct: 0), 0)
check("сто процентов - полный круг", Layout.ringSweep(pct: 100), 360)
check("половина - половина круга", Layout.ringSweep(pct: 50), 180)
// Тот же приём, что у полоски: любой ненулевой процент виден.
check("один процент виден, а не пропадает", Layout.ringSweep(pct: 1), Layout.ringMinSweep)
check("процент выше ста не даёт дуги длиннее круга", Layout.ringSweep(pct: 150), 360)
check("отрицательный процент не даёт отрицательной дуги", Layout.ringSweep(pct: -5), 0)
// Кольцо растёт вместе со шрифтом трея: иначе поднявший шрифт до 20
// получает нитку под цифрами.
check("диаметр растёт от шрифта",
      Layout.ringDiameter(capHeight: 20) > Layout.ringDiameter(capHeight: 9))
check("на мелком шрифте кольцо всё равно не исчезает",
      Layout.ringDiameter(capHeight: 1) >= 8)
// Строка меню - 22 точки. Без потолка шрифт трея, поднятый до 28, давал
// кольцо больше строки, и его срезало бы краем.
check("выше строки меню кольцо не растёт",
      Layout.ringDiameter(capHeight: 28) <= Layout.ringMaxDiameter)
check("и потолок ниже самой строки меню", Layout.ringMaxDiameter < 22)
check("обод не тоньше видимого", Layout.ringStroke(diameter: 8) >= Layout.ringStrokeMin)
// Обод рисуется по средней линии: радиус меньше на половину толщины,
// иначе половина обода уходит за край картинки.
check("обод умещается в диаметр", Layout.ringStroke(diameter: 16) < 16 / 2)

// ---- опора числа -----------------------------------------------------------
// Знак «≈» у денег стоял тремя литералами в трёх файлах. Теперь правило
// одно, и проверяется оно здесь.
print("\nопора числа")
check("у нашего счёта знак есть", Fidelity.derived.mark, "\u{2248}")
check("у числа от Anthropic знака нет", Fidelity.official.mark, "")
check("деньги помечены как наш счёт",
      MoneyView.make(spent: 12.5, partial: false).spentMarked, "\u{2248}$12.5")
check("токены знака не получают: их слабость в охвате, а не в оценке",
      TokensView(spent: 1000).text, "1" + L("к", "K"))

print("\nпроверок: \(checks), провалов: \(failures)\n")
exit(failures == 0 ? 0 : 1)
