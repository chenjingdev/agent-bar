import Foundation

protocol UsageProviding: Sendable {
    func load() async -> ProviderSnapshot
}
