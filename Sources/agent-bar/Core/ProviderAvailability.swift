import Foundation

/// Availability checks installation only, never another app's login or Keychain.
enum ProviderAvailability {
    static func availableProviders() -> [ProviderKind] {
        ProviderKind.allCases.filter { isAvailable($0) }
    }

    static func isAvailable(_ provider: ProviderKind) -> Bool {
        (try? ProviderCLI.executable(provider)) != nil
    }
}
