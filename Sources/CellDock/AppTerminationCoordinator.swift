import AppKit
import Foundation

@MainActor
final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    var cleanup: ((@escaping (Bool) -> Void) -> Void)?
    var onTerminationCancelled: (() -> Void)?
    private let timeout: TimeInterval
    private var terminationPending = false

    init(timeout: TimeInterval = 45) {
        self.timeout = timeout
    }

    func beginTermination(of application: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { application.reply(toApplicationShouldTerminate: $0) }
    }

    // Exercise cancellation without actually quitting NSApplication in tests.
    func beginTermination(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let cleanup else { return .terminateNow }
        terminationPending = true
        var replied = false
        let finish: (Bool) -> Void = { shouldTerminate in
            DispatchQueue.main.async {
                guard !replied else { return }
                replied = true
                self.terminationPending = false
                if !shouldTerminate { self.onTerminationCancelled?() }
                reply(shouldTerminate)
            }
        }
        cleanup(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        return .terminateLater
    }
}
