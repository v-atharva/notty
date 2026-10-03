import UIKit

@MainActor
final class NotebookBackgroundLease {
    struct Token: Equatable { fileprivate let id = UUID() }
    typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    typealias End = @MainActor (UIBackgroundTaskIdentifier) -> Void

    @MainActor
    private final class Lease {
        let token = Token()
        var identifier: UIBackgroundTaskIdentifier?
        var finished = false
    }

    private let begin: Begin
    private let end: End
    private var active: Lease?

    init(
        begin: @escaping Begin = { expiration in
            UIApplication.shared.beginBackgroundTask(
                withName: "Save notebook", expirationHandler: expiration
            )
        },
        end: @escaping End = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    func start() -> Token? {
        if let active { return active.token }
        let lease = Lease()
        active = lease
        let identifier = begin { [weak self, lease] in
            self?.finish(lease)
        }
        lease.identifier = identifier
        if identifier == .invalid {
            lease.finished = true
            if active === lease { active = nil }
            return nil
        }
        // An immediate expiration can arrive before begin returns its identifier.
        if lease.finished { end(identifier) }
        return lease.finished ? nil : lease.token
    }

    func finish(_ token: Token) {
        guard let active, active.token == token else { return }
        finish(active)
    }

    private func finish(_ lease: Lease) {
        guard !lease.finished else { return }
        lease.finished = true
        if let identifier = lease.identifier, identifier != .invalid { end(identifier) }
        if active === lease { active = nil }
    }
}
