import Foundation
@testable import agent_bar

// Tests call accounts by a short handle. The app has no account names, so the handle lives here, keyed by account ID.
private let handles = Handles()
private final class Handles: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [UUID: String] = [:]
    subscript(id: UUID) -> String? {
        get { lock.lock(); defer { lock.unlock() }; return names[id] }
        set { lock.lock(); names[id] = newValue; lock.unlock() }
    }
}

extension UsageAccount {
    init(id: UUID, provider: ProviderKind, name: String, identity: AccountIdentity? = nil,
         credentialID: UUID? = nil, deletionPending: Bool = false) {
        self.init(id: id, provider: provider, identity: identity, credentialID: credentialID, deletionPending: deletionPending)
        handles[id] = name
    }
    var name: String { handles[id] ?? title }
}
