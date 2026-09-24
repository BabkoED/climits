import AppKit
import Darwin

// Клик по сессии в меню - открыть её окно.
//
// ЗАЧЕМ. Меню уже говорит «ждёт меня: разрешение» и где запущено -
// Terminal, VS Code. Оставался шаг руками: найти это окно среди прочих.
// Приём из CodexBar (Agent Sessions, «focus»): от процесса сессии вверх
// по родителям до первого настоящего приложения - его и выводим вперёд.
//
// Разрешение Accessibility для этого НЕ нужно: активировать приложение
// можно и без него. Без него нельзя выбрать одно окно из нескольких
// у того же приложения - поднимется всё приложение, окно в нём человек
// найдёт сам. Просить широкое разрешение ради этого шага не стоит.
enum SessionFocus {
    // Родитель процесса. sysctl, а не `ps`: запуск программы на каждый
    // клик - сотни миллисекунд, а здесь один системный вызов.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let pp = info.kp_eproc.e_ppid
        return pp > 1 ? pp : nil
    }

    // Первое приложение с окнами вверх по цепочке. Двенадцать шагов с
    // запасом: у VS Code это claude -> node -> Code Helper -> Code, у
    // Terminal - claude -> zsh -> login -> Terminal. Помощники Electron
    // сами по себе тоже «приложения», но без окон - их пропускаем.
    static func ownerApp(of pid: Int) -> NSRunningApplication? {
        var p = pid_t(pid)
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy == .regular {
                return app
            }
            guard let pp = parent(of: p) else { return nil }
            p = pp
        }
        return nil
    }

    // true - нашли и подняли. false - сессия под tmux или без окна:
    // её родитель - служба, а не приложение, и честно сказать «не нашёл»
    // лучше, чем поднять наугад первый попавшийся терминал.
    @discardableResult
    static func focus(_ s: AgentSession) -> Bool {
        if !s.machine.isEmpty {
            // Удалённая сессия. Через Remote Control её окно - веб-страница
            // Claude Code; без моста открыть на этом маке нечего.
            guard s.bridged, let u = URL(string: "https://claude.ai/code") else { return false }
            NSWorkspace.shared.open(u)
            return true
        }
        guard let app = ownerApp(of: s.pid) else { return false }
        // С macOS 14 этот вызов помечен устаревшим, но работает; замена
        // без опций есть только с 14, а минимум у нас 13. Предупреждение
        // сборки - цена поддержки Ventura, а не ошибка.
        return app.activate(options: [.activateIgnoringOtherApps])
    }
}
