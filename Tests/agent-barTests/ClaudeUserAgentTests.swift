import Testing
@testable import agent_bar

struct ClaudeUserAgentTests {
    // Claude lists no reset grants for an old or unreadable CLI version (`cli_version`).
    @Test
    func olderOrUndetectedCLISendsTheMinimumResetVersion() {
        #expect(ClaudeUsageProvider.userAgentVersion(installed: nil) == "2.1.295")
        #expect(ClaudeUsageProvider.userAgentVersion(installed: "2.1.200") == "2.1.295")
        #expect(ClaudeUsageProvider.userAgentVersion(installed: "2.0.99") == "2.1.295")
    }

    @Test
    func currentOrNewerCLISendsItsOwnVersion() {
        #expect(ClaudeUsageProvider.userAgentVersion(installed: "2.1.295") == "2.1.295")
        #expect(ClaudeUsageProvider.userAgentVersion(installed: "2.1.1000") == "2.1.1000")
        #expect(ClaudeUsageProvider.userAgentVersion(installed: "2.2.0") == "2.2.0")
    }
}
