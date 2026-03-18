import Foundation

protocol UsageProviding {
    func load() async -> ProviderSnapshot
}
