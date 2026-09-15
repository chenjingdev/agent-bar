import AppKit
import Foundation
import SwiftUI
import Testing
@testable import agent_bar

struct AccountViewRenderingTests {
    @Test @MainActor func accountSettingsAndListRenderAtSupportedSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-render-\(UUID())")
        let files = AccountFiles(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "agentbar-render-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let examples = [
            UsageAccount(id: UUID(), provider: .codex, name: "개인 계정", identity: .init(email: "personal@example.test"), credentialID: UUID()),
            UsageAccount(id: UUID(), provider: .codex, name: "업무 계정 — 긴 이름 표시 확인", identity: .init(email: "work@example.test", organization: "Example Team"), credentialID: UUID()),
            UsageAccount(id: UUID(), provider: .claude, name: "Claude 개인 계정", identity: .init(email: "claude@example.test"), credentialID: UUID())
        ]
        var registry = AccountRegistry(accounts: examples); registry.repairRepresentatives()
        try files.write(registry, to: files.registryURL)
        let store = UsageStore(settings: settings, availableProviders: [], files: files, autoRefresh: false)
        try render(SettingsView().environmentObject(settings).environmentObject(store), size: NSSize(width: 430, height: 320), name: "settings")
        try render(AccountListView(provider: .codex).environmentObject(store), size: NSSize(width: 392, height: 568), name: "codex-list")
        let emptyFiles = AccountFiles(root: root.appendingPathComponent("empty"))
        let empty = UsageStore(settings: settings, availableProviders: [], files: emptyFiles, autoRefresh: false)
        try render(AccountListView(provider: .claude).environmentObject(empty), size: NSSize(width: 392, height: 568), name: "empty-list")
    }
    @MainActor private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        if let destination = ProcessInfo.processInfo.environment["AGENTBAR_QA_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
