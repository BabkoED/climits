import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// Второй путь обновления - Sparkle. Рядом с первым, а НЕ вместо него.
//
// ЗАЧЕМ ВООБЩЕ. Свой обновлятор (Updater.swift) писан вслепую, и однажды он
// сам себя запер: в 1.2.1 стоял `codesign --quiet`, а такого ключа нет.
// Sparkle - чужой, обкатанный годами код в том же месте.
//
// ПОЧЕМУ РЯДОМ, А НЕ ВМЕСТО. Обновление выполняет ТА версия, которая уже
// стоит. Если новый путь откажет на позднем шаге, самообновление запрётся
// насовсем и лечится только установкой руками. Поэтому:
//
//   * по умолчанию Sparkle ВЫКЛЮЧЕН. Выпуск с ним ничего не меняет,
//     пока человек не поставит галочку;
//   * пункт «через GitHub» из меню не исчезает никогда - это и есть
//     запасной путь, и им управляет человек, а не наша догадка о том,
//     что считать отказом;
//   * весь код Sparkle спрятан за `canImport`. Не собралось с фреймворком -
//     приложение работает как раньше, просто без второго пути.
//
// ЧТО ПРОВЕРЕНО ДО ЭТОГО КОДА (разведочный прогон на macos-14, 07.09.2026):
//   * [ФАКТ] порядок ad-hoc подписи изнутри наружу проходит
//     `codesign --verify --deep --strict`;
//   * [ФАКТ] подпись релиза можно делать на сервере обычным ed25519:
//     подписи сошлись побайтово, и sign_update принял нашу. Значит
//     приватный ключ в GitHub не попадает вовсе;
//   * [ФАКТ] лента читается и версии сравниваются - 07.09.2026 на Маке
//     Антона Sparkle сходил по нашему appcast.xml, разобрал его и верно
//     ответил «версия последняя», сравнив CFBundleVersion со сборкой
//     в лете. То есть публикация, подпись в XML и нумерация - рабочие;
//   * [ПРЕДПОЛОЖЕНИЕ] что Sparkle доведёт СКАЧИВАНИЕ И УСТАНОВКУ до конца
//     на неподписанном Developer ID приложении. Это единственное, что
//     осталось непроверенным, и проверяется только двумя версиями подряд
//     на живой машине. Ровно поэтому галочка и выключена по умолчанию.
enum SparkleState {
    case notBuilt          // собрано без фреймворка
    case off               // фреймворк есть, галочка снята
    case ready             // работает
    case failed(String)    // сказал об ошибке

    var word: String {
        switch self {
        case .notBuilt: return L("не собран", "not built in")
        case .off:      return L("выключен", "off")
        case .ready:    return L("готов", "ready")
        case .failed(let e): return L("ошибка: \(e)", "error: \(e)")
        }
    }
}

#if canImport(Sparkle)
// Делегат слушает два вызова и различает их: «версия последняя» - это
// ответ, «прекратил с ошибкой» - это отказ. Раньше слушался только второй,
// и нормальный ответ выводился как поломка.
//
// Решать за человека, переключаться ли на запасной путь, делегат всё равно
// НЕ будет: отказы бывают разные, а угадывать их коды по памяти - то же
// самое, что выдумывать ключи codesign. Он только называет причину.
private final class BridgeDelegate: NSObject, SPUUpdaterDelegate {
    var onAbort: ((String) -> Void)?
    var onNoUpdate: (() -> Void)?

    // «У тебя последняя версия» - это НОРМАЛЬНЫЙ ответ, а не отказ.
    //
    // Sparkle сообщает об этом отдельным вызовом, а потом всё равно
    // прекращает проверку через didAbortWithError. Первая версия слушала
    // только второй вызов - и на живой машине в меню появилось «Sparkle
    // не смог: You're up to date!». То есть работающий механизм был
    // подписан как сломанный, ровно наоборот.
    //
    // Я тогда отказался разбирать коды чужих ошибок, чтобы не угадывать.
    // Осторожность была верной, вывод из неё - нет: у Sparkle для этого
    // случая есть свой вызов, и слушать надо было его, а не мириться
    // с неверным ярлыком.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        onNoUpdate?()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        onAbort?(error.localizedDescription)
    }
}
#endif

final class SparkleBridge {
    static let shared = SparkleBridge()
    private init() {}

    private var lastError: String?
    // Отметка «нам только что сказали, что версия последняя». Гасит
    // следующий за этим отказ: он про ту же самую проверку.
    private var sawNoUpdate = false

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private let delegate = BridgeDelegate()
    #endif

    // Собрано ли приложение с фреймворком вообще.
    var isBuiltIn: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    var state: SparkleState {
        guard isBuiltIn else { return .notBuilt }
        if let e = lastError { return .failed(e) }
        return Prefs.sparkleEnabled ? .ready : .off
    }

    // Поднимается только по галочке и только один раз. Держать чужой
    // апдейтер запущенным при снятой галочке незачем: он сам ходит в сеть
    // по своему расписанию, а расписание здесь наше.
    func startIfEnabled() {
        #if canImport(Sparkle)
        guard Prefs.sparkleEnabled, controller == nil else { return }
        delegate.onNoUpdate = { [weak self] in
            self?.sawNoUpdate = true
            self?.lastError = nil
        }
        delegate.onAbort = { [weak self] text in
            guard let self = self else { return }
            // Отказ сразу после «версия последняя» - это конец той же
            // проверки, а не поломка.
            if self.sawNoUpdate { self.sawNoUpdate = false; return }
            self.lastError = text
        }
        let c = SPUStandardUpdaterController(startingUpdater: false,
                                             updaterDelegate: delegate,
                                             userDriverDelegate: nil)
        c.startUpdater()
        controller = c
        #endif
    }

    // Вернёт false, если проверить нечем - тогда зовущий идёт запасным путём.
    @discardableResult
    func checkForUpdates() -> Bool {
        #if canImport(Sparkle)
        guard Prefs.sparkleEnabled else { return false }
        lastError = nil
        sawNoUpdate = false
        startIfEnabled()
        guard let c = controller else { return false }
        c.checkForUpdates(nil)
        return true
        #else
        return false
        #endif
    }
}
