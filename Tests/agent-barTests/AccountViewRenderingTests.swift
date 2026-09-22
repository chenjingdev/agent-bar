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
        let store = UsageStore(settings: settings, files: files, autoRefresh: false)
        try render(SettingsView(tab: .general).environmentObject(settings).environmentObject(store), size: NSSize(width: 430, height: 620), name: "settings-general")
        try render(SettingsView(tab: .accounts).environmentObject(settings).environmentObject(store), size: NSSize(width: 430, height: 620), name: "settings-accounts")
        try render(AccountPopoverView(accountID: examples[1].id).environmentObject(store), size: NSSize(width: 392, height: 520), name: "popover")
        let emptyFiles = AccountFiles(root: root.appendingPathComponent("empty"))
        let empty = UsageStore(settings: settings, files: emptyFiles, autoRefresh: false)
        try render(SettingsView(tab: .accounts).environmentObject(settings).environmentObject(empty), size: NSSize(width: 430, height: 620), name: "settings-empty")
        try render(AccountPopoverView(accountID: examples[0].id).environmentObject(empty), size: NSSize(width: 392, height: 520), name: "popover-removed")
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
