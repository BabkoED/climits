import Foundation

// Состояние сервиса со страницы статуса - status.claude.com.
//
// ЗАЧЕМ. Когда цифры перестали обновляться или сессии встали, первый
// вопрос - «сломалось у меня или у них». Ответ на него лежит в открытом
// JSON, и спрашивать его руками, открывая страницу в браузере, незачем.
// Приём взят у CodexBar (MIT): точка на значке и строка в меню, пока
// идёт инцидент. Спокойное «всё работает» не показывается вовсе - оно
// ничего не решает и занимало бы строку каждый день.
//
// Формат - Statuspage, `/api/v2/summary.json`. Один запрос отдаёт и общий
// уровень, и открытые инциденты, и компоненты. Тот же формат у OpenAI
// (status.openai.com), поэтому разбор общий, а адрес - свойство провайдера.
//
// Разбор без Codable по той же причине, что и у ответа лимитов: одно
// переименованное поле не должно выключать весь показ. Нет уровня - нет
// и статуса, это честнее, чем нарисовать «всё хорошо».
struct ServiceStatus: Equatable {
    // 0 - всё работает, 1 - работы по плану или мелкий сбой, 2 - серьёзный,
    // 3 - авария. Ступени Statuspage, а не свои: порогов мы не выдумываем.
    let level: Int
    let indicator: String      // none | minor | major | critical | maintenance
    let description: String    // «All Systems Operational», «Partial Outage»
    let incidents: [String]    // названия открытых инцидентов, тяжёлые первыми
    let components: [String]   // что именно не работает, если сказано
    let fetchedAt: Date

    var isCalm: Bool { return level == 0 }

    // Одна строка для меню. Название инцидента важнее общего описания:
    // «Partial Outage» не говорит, что сломалось, а «Elevated errors on
    // Claude Code» говорит.
    var line: String {
        let what = incidents.first ?? description
        var s = what
        if incidents.count > 1 {
            s += L(" и ещё \(incidents.count - 1)", " and \(incidents.count - 1) more")
        }
        return s
    }

    static func level(for indicator: String) -> Int {
        switch indicator.lowercased() {
        case "none": return 0
        case "maintenance", "minor": return 1
        case "major": return 2
        case "critical": return 3
        // Незнакомое слово - не «всё хорошо». Ставим нижнюю ступень
        // тревоги: строка в меню появится, и её текст скажет, что там.
        default: return 1
        }
    }

    private static func impactRank(_ s: String) -> Int {
        switch s.lowercased() {
        case "critical": return 3
        case "major": return 2
        case "minor": return 1
        default: return 0
        }
    }

    static func parse(_ data: Data, at: Date = Date()) -> ServiceStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let st = root["status"] as? [String: Any],
              let ind = st["indicator"] as? String else { return nil }
        let desc = (st["description"] as? String) ?? ind

        // Открытые инциденты. Решённые Statuspage в summary не кладёт, но
        // полагаться на это незачем - отбрасываем их сами.
        var found: [(name: String, rank: Int)] = []
        for x in (root["incidents"] as? [[String: Any]]) ?? [] {
            let status = ((x["status"] as? String) ?? "").lowercased()
            if status == "resolved" || status == "postmortem" { continue }
            guard let name = x["name"] as? String, !name.isEmpty else { continue }
            found.append((name, impactRank((x["impact"] as? String) ?? "")))
        }
        // Идущие сейчас плановые работы - тоже повод: сервис в это время
        // может отвечать с ошибками. Запланированные на потом - нет.
        for x in (root["scheduled_maintenances"] as? [[String: Any]]) ?? [] {
            let status = ((x["status"] as? String) ?? "").lowercased()
            guard status == "in_progress" || status == "verifying" else { continue }
            guard let name = x["name"] as? String, !name.isEmpty else { continue }
            found.append((name, 0))
        }
        // Сортировка устойчивая: при равной тяжести остаётся порядок
        // страницы, иначе строка прыгала бы между обновлениями.
        let names = found.enumerated()
            .sorted { $0.element.rank != $1.element.rank
                      ? $0.element.rank > $1.element.rank
                      : $0.offset < $1.offset }
            .map { $0.element.name }

        let broken = ((root["components"] as? [[String: Any]]) ?? [])
            .filter { (($0["status"] as? String) ?? "operational") != "operational" }
            .compactMap { $0["name"] as? String }

        var lvl = level(for: ind)
        // Инцидент открыт, а общий уровень ещё «none» - так бывает первые
        // минуты, пока его не разметили. Молчать в это время нельзя.
        if lvl == 0 && !names.isEmpty { lvl = 1 }
        return ServiceStatus(level: lvl, indicator: ind, description: desc,
                             incidents: names, components: broken, fetchedAt: at)
    }
}
