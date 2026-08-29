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
case .success(let w):
    check("ответ второй машины разобран", w.count == 1)
    check("чтение из кэша не потерялось", "\(w[0].byFamily["opus"]?.cacheRead ?? -1)", "4")
    check("незнакомые модели доехали", w[0].unknownModels.contains("<весёлая>"))
case .failure(let e):
    check("ответ второй машины разобран: \(e.text)", false)
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

print("\nпроверок: \(checks), провалов: \(failures)\n")
exit(failures == 0 ? 0 : 1)
