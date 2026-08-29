import Foundation

// Чтение локальных расшифровок Claude Code: ~/.claude/projects/**/*.jsonl.
//
// Отсюда берутся две вещи:
//   1) оценка расхода, когда API недоступен и кэша нет;
//   2) деньги - сколько бы стоил тот же трафик по прайсу API.
//
// ГЛАВНОЕ ОГРАНИЧЕНИЕ, и его нельзя прятать: здесь лежит только то, что
// происходило НА ЭТОЙ МАШИНЕ. Проценты лимита сервер считает по всему
// аккаунту. Если человек работает с двух машин, локальные токены меньше
// настоящих, и всякий вывод «а сколько всего» будет занижен. Поэтому в
// интерфейсе это всегда помечено как оценка, а не как факт.

struct WindowUsage {
    // Токены по семействам моделей: opus, sonnet, fable, haiku.
    var byFamily: [String: TokenTally] = [:]
    var unknownModels: Set<String> = []
    // Хотя бы один файл пришлось читать не целиком - значит часть окна
    // не увидели, и итог занижен. Молча этого показывать нельзя.
    var truncated = false

    var totals: TokenTally {
        return byFamily.values.reduce(TokenTally()) { $0 + $1 }
    }

    // Стоимость по прайсу API.
    var cost: Double {
        return byFamily.reduce(0.0) { sum, kv in
            sum + kv.value.cost(Pricing.price(for: kv.key))
        }
    }

    func cost(family: String) -> Double {
        guard let t = byFamily[family] else { return 0 }
        return t.cost(Pricing.price(for: family))
    }

    var isEmpty: Bool { return byFamily.isEmpty }

    // Вычитание вложенных окон: «расход с понедельника» минус «расход
    // со вторника» даёт расход за понедельник. Так из накопительных окон,
    // которые считаются одним проходом по файлам, получаются суточные -
    // без второго обхода тех же сотен мегабайт.
    //
    // Отрицательного тут быть не может по построению (уменьшаемое включает
    // вычитаемое), но если вдруг - зажимаем нулём: минус токенов в графике
    // нарисовался бы столбиком вниз и выглядел как поломка данных, а не
    // как наша ошибка.
    static func - (a: WindowUsage, b: WindowUsage) -> WindowUsage {
        var out = a
        for (family, tally) in b.byFamily {
            guard let have = out.byFamily[family] else { continue }
            out.byFamily[family] = TokenTally(
                input: max(0, have.input - tally.input),
                output: max(0, have.output - tally.output),
                cacheWrite: max(0, have.cacheWrite - tally.cacheWrite),
                cacheRead: max(0, have.cacheRead - tally.cacheRead),
                requests: max(0, have.requests - tally.requests))
        }
        out.byFamily = out.byFamily.filter { $0.value.total > 0 || $0.value.requests > 0 }
        return out
    }

    // Сложение окон с разных машин. Лимит у аккаунта один, а расшифровки
    // лежат на каждой машине свои - без этого сложения приложение считает
    // только тот кусок расхода, который видит под собой.
    static func + (a: WindowUsage, b: WindowUsage) -> WindowUsage {
        var out = a
        for (family, tally) in b.byFamily {
            out.byFamily[family] = (out.byFamily[family] ?? TokenTally()) + tally
        }
        out.unknownModels.formUnion(b.unknownModels)
        out.truncated = a.truncated || b.truncated
        return out
    }
}

enum Transcripts {
    // Читаем только хвост файла: расшифровки длинных проектов вырастают до
    // сотен мегабайт, а в интересующее нас окно попадает только конец.
    //
    // Восемь мегабайт было мало: недельное окно у активного пользователя
    // не влезает, и деньги за неделю занижались молча. Шестьдесят четыре
    // покрывают неделю с запасом, а если всё же не покрыли - в WindowUsage
    // поднимается флаг truncated, и в меню появляется оговорка.
    private static let maxTailBytes = 64 * 1024 * 1024

    static var projectsDir: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // Все каталоги расшифровок на ЭТОЙ машине.
    //
    // Обычно один - «~/.claude/projects». Но у человека может быть второй
    // аккаунт со своим CLAUDE_CONFIG_DIR: рабочий и личный. Пока мы читали
    // только домашний, половина расхода не попадала в счёт молча - той же
    // природы ошибка, что и работа со второй машины, только ближе.
    static func localRoots() -> [URL] {
        var out = [projectsDir]
        var seen = Set([projectsDir.standardizedFileURL.path])
        for line in Prefs.extraRoots.split(separator: "\n") {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let expanded = (raw as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            // Тот же каталог, записанный иначе, посчитался бы дважды: дедуп
            // идёт по message.id и спас бы от двойного счёта, но обход
            // сотен мегабайт всё равно прошёл бы впустую.
            guard !seen.contains(url.path) else { continue }
            seen.insert(url.path)
            out.append(url)
        }
        return out
    }

    // Расход за промежуток [since, now].
    static func usage(since: Date, dir: URL? = nil) -> WindowUsage {
        return usage(cutoffs: [since], dir: dir)[0]
    }

    // Несколько окон за один проход по файлам.
    //
    // Окна вложены друг в друга - пятичасовое внутри недельного, - и читать
    // одни и те же сотни мегабайт дважды незачем. Строка попадает во все
    // окна, чья граница её младше.
    static func usage(cutoffs: [Date], dir: URL? = nil) -> [WindowUsage] {
        guard let earliest = cutoffs.min() else { return [] }
        var out = [WindowUsage](repeating: WindowUsage(), count: cutoffs.count)
        // Общий на все файлы: один и тот же message.id не должен посчитаться
        // дважды, даже если строки разъехались по двум файлам.
        var seen = Set<String>()
        let roots = dir.map { [$0] } ?? localRoots()
        let since = earliest
        for root in roots {
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for case let url as URL in walker {
                guard url.pathExtension == "jsonl" else { continue }
                // Только обычные файлы. Символьная ссылка на /dev/zero даёт
                // seekToEnd() == 0, потолок в 64 МБ не срабатывает вовсе,
                // и чтение съедает память; на FIFO чтение просто блокируется,
                // а в терминальном режиме обход синхронный - климитс вешается.
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      rv.isRegularFile == true, rv.isSymbolicLink != true else { continue }
                // Файл, не тронутый с начала окна, точно не содержит нужных строк.
                if let v = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = v.contentModificationDate, m < since { continue }
                scan(url: url, cutoffs: cutoffs, into: &out, seen: &seen)
            }
        }
        return out
    }

    private static func scan(url: URL, cutoffs: [Date], into out: inout [WindowUsage],
                             seen: inout Set<String>) {
        let since = cutoffs.min() ?? Date.distantPast
        let (text, truncated) = tail(of: url)
        if truncated { for i in out.indices { out[i].truncated = true } }

        for line in text.split(separator: "\n") {
            // Дешёвый отсев до разбора JSON: строк в файле десятки тысяч,
            // а с расходом - единицы процентов от них.
            guard line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let ts = row["timestamp"] as? String,
                  let when = UsageParser.parseDate(ts), when >= since else { continue }
            guard let message = row["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            // ОДНО СООБЩЕНИЕ - НЕСКОЛЬКО СТРОК.
            //
            // Claude Code пишет ответ модели порциями, и в каждой строке
            // лежит ПОЛНЫЙ usage этого сообщения, а не приращение. Считать
            // построчно - значит сложить одно и то же по нескольку раз.
            // Замер на живом файле: 98 строк с usage на 43 сообщения, то есть
            // завышение в 2.28 раза. Значения в повторах идентичны, поэтому
            // берём первое вхождение и остальные пропускаем.
            if let mid = message["id"] as? String, !mid.isEmpty {
                if seen.contains(mid) { continue }
                seen.insert(mid)
            }
            // Строка без id дедупу не поддаётся. В замере таких не было
            // ни одной, но если появятся - лучше посчитать, чем потерять.

            let model = (message["model"] as? String) ?? ""
            // «<synthetic>» и прочее в угловых скобках - служебные записи
            // самого Claude Code: отказ, ошибка, локальное сообщение. Это
            // не работа модели, считать их по запасной цене значит выдумывать
            // расход, а оговорка «нет цены для <synthetic>» в меню - шум.
            if model.hasPrefix("<") { continue }
            let family = Pricing.family(of: model)

            let add = TokenTally(input: intOf(usage["input_tokens"]),
                                 output: intOf(usage["output_tokens"]),
                                 cacheWrite: intOf(usage["cache_creation_input_tokens"]),
                                 cacheRead: intOf(usage["cache_read_input_tokens"]),
                                 requests: 1)
            for (i, cutoff) in cutoffs.enumerated() where when >= cutoff {
                out[i].byFamily[family] = (out[i].byFamily[family] ?? TokenTally()) + add
                if !model.isEmpty && !Pricing.isKnown(model) { out[i].unknownModels.insert(model) }
            }
        }
    }

    private static func intOf(_ any: Any?) -> Int {
        return Int(jsonNumber(any) ?? 0)
    }

    private static func tail(of url: URL) -> (text: String, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ("", false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxTailBytes)
        try? handle.seek(toOffset: truncated ? size - UInt64(maxTailBytes) : 0)
        // Читаем не больше потолка явно: readToEnd() на нерегулярном источнике
        // не имеет конца, и потолок, посчитанный из size, его не ограничивает.
        let want = Int(min(size, UInt64(maxTailBytes)))
        guard want > 0, let data = try? handle.read(upToCount: want) else { return ("", truncated) }
        return (String(decoding: data, as: UTF8.self), truncated)
    }
}

// Деньги за окно.
//
// Считается ровно одно: во что обошёлся трафик, который мы ВИДЕЛИ, - эта
// машина плюс те, что настроены как удалённые. Ни во что другое это число
// не переводится.
//
// Здесь был ещё шаг: «если этот расход съел N процентов лимита, то весь
// лимит стоит потрачено/(N/100)». Шаг убран 29.08.2026. Причина не в
// точности, а в том, что делились несопоставимые величины: числитель -
// расход, который видим мы, знаменатель - процент, который Anthropic
// считает по ВСЕМУ аккаунту. Замер 28.08: мак видел $258 при общем расходе
// $1182, то есть «весь лимит» занижался вчетверо. И выглядела эта цифра
// убедительнее всего остального в меню - она была там самой круглой.
//
// Размер лимита Anthropic не публикует нигде: ни в тарифе, ни в справке,
// ни админом в Enterprise. Честный ответ на «сколько всего» - «неизвестно»,
// и он полезнее подделки. Что осталось - два числа с разной природой
// ошибки: процент от сервера (полный, но без масштаба) и деньги с токенами
// (точные, но только по видимым машинам). Расходятся - значит есть машина,
// которую мы не читаем.
struct MoneyView {
    let spent: Double        // прямой счёт по прайсу
    let partial: Bool        // расшифровки могут не покрывать весь аккаунт

    static func make(spent: Double, partial: Bool) -> MoneyView {
        return MoneyView(spent: spent, partial: partial)
    }

    // Значащие цифры важнее единообразия: это счёт по нашему прайсу, и
    // «$139.63» на недельном расходе - ложная точность, а «$0.5» на копейках
    // прячет разницу между двумя запросами и двадцатью.
    static func money(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 10 {
            var s = String(format: "%.1f", v)
            if s.hasSuffix(".0") { s.removeLast(2) }
            return "$" + s
        }
        return String(format: "$%.2f", v)
    }

    var spentText: String { return MoneyView.money(spent) }
}

// Токены за то же окно и тем же способом: сколько прошло через машины,
// которые мы читаем. Полного лимита в токенах здесь тоже больше нет -
// он выводился тем же делением на процент и врал ровно так же.
struct TokensView {
    let spent: Int

    var isEmpty: Bool { return spent <= 0 }
    var text: String { return Fmt.compact(spent) }
}


// Деньги по одному лимиту.
//
// Окно берём от времени сброса назад: сервер сам говорит, когда лимит
// обнулится, и это точнее, чем «последние пять часов от сейчас» - к моменту,
// когда до сброса осталось десять минут, эти два промежутка расходятся почти
// полностью.
enum Money {
    // isSession, а не сравнение с «five_hour»: длительность окна задаёт
    // Anthropic, имя ключа уже менялось, и ровно поэтому в Usage есть
    // отдельное свойство session. Полагаться здесь на литерал - значит
    // однажды поделить недельный расход на пятичасовой процент.
    static func duration(isSession: Bool) -> TimeInterval {
        return isSession ? 5 * 3600 : 7 * 86400
    }

    static func windowStart(for b: Bucket, isSession: Bool) -> Date {
        let d = duration(isSession: isSession)
        if let reset = b.resetsAt { return reset.addingTimeInterval(-d) }
        return Date().addingTimeInterval(-d)
    }

    // Какая часть расшифровок относится к этому лимиту: у модельных - только
    // трафик самой модели, у общих - весь.
    static func spent(for b: Bucket, in window: WindowUsage) -> Double {
        if b.key.hasPrefix("seven_day_") {
            let family = String(b.key.dropFirst("seven_day_".count))
            return window.cost(family: family)
        }
        if b.key == UsageParser.fableKey { return window.cost(family: "fable") }
        return window.cost
    }

    static func view(for b: Bucket, in window: WindowUsage) -> MoneyView {
        return MoneyView.make(spent: spent(for: b, in: window), partial: true)
    }

    // Токены той же долей расшифровок, что и деньги: у модельных лимитов -
    // только своя модель, у общих - всё окно.
    static func spentTokens(for b: Bucket, in window: WindowUsage) -> Int {
        if b.key.hasPrefix("seven_day_") {
            let family = String(b.key.dropFirst("seven_day_".count))
            return window.byFamily[family]?.total ?? 0
        }
        if b.key == UsageParser.fableKey { return window.byFamily["fable"]?.total ?? 0 }
        return window.totals.total
    }

    static func tokens(for b: Bucket, in window: WindowUsage) -> TokensView {
        return TokensView(spent: spentTokens(for: b, in: window))
    }
}

// Посуточная разбивка и темп.
//
// Оба ответа берутся из того же прохода по файлам, что и деньги: в
// Transcripts.usage(cutoffs:) можно передать сколько угодно границ, а
// стоит это столько же, сколько одна. Отдельный обход ради графика был бы
// вторым чтением тех же сотен мегабайт.
enum Trend {
    // Границы суток, от самых старых к свежим: для семи дней это семь
    // полуночей, начиная с полуночи шесть дней назад.
    //
    // Полночи берутся у календаря, а не вычитанием 86400: сутки бывают
    // длиной 23 и 25 часов при переходе на летнее время, и график поехал
    // бы ровно два раза в год - то есть тогда, когда объяснить это уже
    // некому.
    static func dayCutoffs(days: Int, now: Date = Date(),
                           calendar: Calendar = .current) -> [Date] {
        let d = max(1, min(31, days))
        let today = calendar.startOfDay(for: now)
        var out: [Date] = []
        for back in stride(from: d - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            out.append(day)
        }
        return out
    }

    // Накопительные окна -> расход за каждые сутки.
    //
    // На входе то, что вернул usage(cutoffs:) для dayCutoffs: первое окно
    // самое широкое (с самой старой полуночи), последнее - «сегодня».
    // Расход за сутки i - это окно i минус окно i+1.
    static func split(_ cumulative: [WindowUsage]) -> [WindowUsage] {
        guard !cumulative.isEmpty else { return [] }
        var out: [WindowUsage] = []
        for i in cumulative.indices {
            out.append(i + 1 < cumulative.count ? cumulative[i] - cumulative[i + 1] : cumulative[i])
        }
        return out
    }

    // Токенов в час по последнему часу. Меньше десяти минут наблюдения -
    // отвечаем «неизвестно»: на трёх минутах один длинный ответ модели
    // превращается в «два миллиона в час», и это не темп, а всплеск.
    static let minSpan: TimeInterval = 600

    static func perHour(tokens: Int, over span: TimeInterval) -> Int? {
        guard span >= minSpan, tokens > 0 else { return nil }
        return Int(Double(tokens) / (span / 3600.0))
    }

    // Во что обойдётся окно к сбросу, если темп не изменится.
    //
    // Это НЕ предсказание лимита - размер лимита мы не знаем и не выдумываем.
    // Это ответ на «сколько набежит к концу окна, если так и продолжу»:
    // потрачено плюс темп на остаток времени.
    static func projected(spent: Double, perHour: Double, until reset: Date?,
                          now: Date = Date()) -> Double? {
        guard let reset = reset, perHour > 0 else { return nil }
        let hours = reset.timeIntervalSince(now) / 3600.0
        guard hours > 0, hours < 24 * 8 else { return nil }
        return spent + perHour * hours
    }
}
