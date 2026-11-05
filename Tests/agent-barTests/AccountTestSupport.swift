import Foundation
@testable import agent_bar

// Tests name an account by the name the account itself carries (its identity's `name`).
extension UsageAccount {
    init(id: UUID, provider: ProviderKind, name: String, identity: AccountIdentity? = nil,
         credentialID: UUID? = nil, deletionPending: Bool = false) {
        var identity = identity ?? AccountIdentity()
        identity.name = name
        self.init(id: id, provider: provider, identity: identity, credentialID: credentialID, deletionPending: deletionPending)
    }
    var name: String { identity?.name ?? title }
}
