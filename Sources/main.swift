import AppKit

// Точка входа. Один бинарник живёт двумя жизнями:
//   * запущен из Finder или Dock  -> иконка в строке меню;
//   * запущен из терминала         -> печатает отчёт и выходит.
//
// Различаем по наличию терминала на stdout. Launch Services запускает
// приложение без tty, поэтому проверка честная и не требует ни отдельной
// обёртки, ни второго бинарника.
//
// Служебные аргументы macOS отбрасываем: при запуске из Finder система
// подставляет -psn_0_12345, а отладочные сборки добавляют -NSxxx. Принять их
// за наши ключи - значит показать «неизвестный аргумент» на ровном месте.
let rawArgs = Array(CommandLine.arguments.dropFirst())
let args = rawArgs.filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }

if !args.isEmpty {
    exit(CLI.run(args))
}
if CLI.isTTY {
    exit(CLI.run(["--full"]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MenuBarController?
    func applicationDidFinishLaunching(_ n: Notification) {
        controller = MenuBarController()
        // Отладочный вход для снимка в CI: открыть окно настроек сразу.
        // Переменной окружения, а не ключом запуска: ключ означал бы
        // терминальный режим (см. разбор аргументов выше), и приложение
        // напечатало бы отчёт вместо запуска окна.
        let shot = ProcessInfo.processInfo.environment["CLIMITS_UI_SHOT"] ?? ""
        if shot == "1" {
            let wide = ProcessInfo.processInfo.environment["CLIMITS_UI_SHOT_WIDTH"]
                .flatMap { Double($0) }
                .map { CGFloat($0) }
            controller?.showSettingsForShot(width: wide)
        } else if shot == "menu" {
            // Через очередь, а не прямо здесь: открытие меню крутит свой
            // цикл событий и не возвращается, пока меню открыто. Вызови мы
            // его в didFinishLaunching - app.run() не начался бы вовсе.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller?.showMenuForShot()
            }
        }
    }
}

let app = NSApplication.shared
// .accessory, а не .regular: иконки в Dock и меню «Файл/Правка» приложению
// в строке меню не нужны. То же самое делает LSUIElement в Info.plist -
// дублируем в коде, чтобы запуск бинарника напрямую вёл себя так же, как
// запуск бандла.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
