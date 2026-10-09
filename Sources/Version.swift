import Foundation

// Сравнение версий и вытаскивание контрольной суммы из текста релиза.
//
// Вынесено из Updater отдельным файлом ровно по одной причине: Updater
// тянет AppKit, а значит не собирается ни на Linux, ни в проверках логики.
// А ошибиться тут проще всего, и ошибка будет тихой: приложение просто
// перестанет замечать обновления, и никто этого не увидит.
enum Version {
    // «v1.2.0» -> «1.2.0».
    static func number(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    // Сравнение по частям, а не строкой: «1.10.0» строкой МЕНЬШЕ «1.9.0»,
    // и на десятом выпуске обновление молча перестало бы находиться.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        // «dev» - сборка из исходников, цифр в ней нет. Подменять её релизом
        // молча нельзя: человек собрал её сам и, скорее всего, с правками.
        if x.isEmpty || y.isEmpty { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parts(_ s: String) -> [Int] {
        let p = s.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? -1 }
        return p.contains(-1) || p.isEmpty ? [] : p
    }

    // Сумма из текста релиза: 64 шестнадцатеричных знака где угодно в тексте.
    //
    // Именно поиском, а не разбором формата: текст релиза пишет человек,
    // и обрамление вокруг суммы менялось уже дважды. Не нашли - значит
    // проверять нечем, и автообновление обязано отказаться, а не «ну ладно».
    static func sha256(inNotes notes: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b[a-fA-F0-9]{64}\\b") else { return nil }
        let range = NSRange(notes.startIndex..., in: notes)
        guard let m = re.firstMatch(in: notes, range: range),
              let r = Range(m.range, in: notes) else { return nil }
        return String(notes[r]).lowercased()
    }
}

// Что делать, когда Sparkle отказал.
//
// ЗАЧЕМ. До 1.21.0 любой отказ сам открывал путь через GitHub, в том числе
// «подпись не сошлась». А на пути через GitHub сверяется только сумма из
// текста того же релиза: кто может править релиз, подменит и архив, и
// сумму. Подпись EdDSA - единственная проверка, ключ от которой не лежит
// на GitHub, и обходить её запасным путём нельзя (ревью 09.10.2026).
//
// Вынесено сюда, а не в SparkleBridge: там AppKit и Sparkle, и решение
// не проверялось бы ничем, кроме живой поломки. Коды - из SUErrors.h
// Sparkle 2.9.6, домен - из SUConstants.m.
enum UpdateAbort: Equatable {
    case fallback   // обычный отказ: сеть, лента, распаковка - можно GitHub
    case stop       // подпись или проверка архива не сошлись - стоп
    case quiet      // человек сам отменил установку - не отказ вовсе

    static let sparkleDomain = "SUSparkleErrorDomain"

    // Одно звено цепочки ошибки: домен и код.
    struct Link: Equatable {
        let domain: String
        let code: Int
    }

    // Ошибка со всеми вложенными - сверху вниз по NSUnderlyingErrorKey.
    //
    // ЗАЧЕМ. Sparkle 2.9.6 сообщает несошедшуюся подпись НЕ кодом 3002
    // наверху: делегат получает общий 4005 «The update is improperly
    // signed», а 3002 лежит на два уровня глубже (AppInstaller.m заворачивает
    // провал проверки в SPUInstallerError, SPUInstallerDriver - ещё раз в
    // SUInstallationError). Первая версия правки смотрела только наверх и
    // подпись пропускала - поймало ревью правки 09.10.2026. Глубина ограничена:
    // кольцевая или бесконечная цепочка не должна вешать главный поток.
    static func chain(of error: Error, limit: Int = 8) -> [Link] {
        var out: [Link] = []
        var e: NSError? = error as NSError
        while let x = e, out.count < limit {
            out.append(Link(domain: x.domain, code: x.code))
            e = x.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return out
    }

    static func decide(_ chain: [Link]) -> UpdateAbort {
        // Отмену Sparkle присылает верхним звеном.
        if let top = chain.first, top.domain == sparkleDomain, top.code == 4007 { return .quiet }
        // Подпись или проверка архива - на любой глубине.
        if chain.contains(where: { $0.domain == sparkleDomain && ($0.code == 3001 || $0.code == 3002) }) {
            return .stop                   // SUSignatureError, SUValidationError
        }
        return .fallback
    }

    static func decide(domain: String, code: Int) -> UpdateAbort {
        return decide([Link(domain: domain, code: code)])
    }
}
