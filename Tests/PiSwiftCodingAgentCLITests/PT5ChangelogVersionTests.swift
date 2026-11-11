import PiSwiftCodingAgent
import Testing
@testable import PiSwiftCodingAgentCLI

// v1.5.2 PT5: main.ts changelog handling; a malformed saved version is silent.
struct PT5ChangelogVersionTests {
    @Test func malformedSavedVersionIsRecordedWithoutDisplay() {
        let settings = SettingsManager.inMemory()
        settings.setLastChangelogVersion("not-a-version")
        let markdown = getChangelogForDisplay(Args(), settings)
        #expect(markdown == nil)
        #expect(settings.getLastChangelogVersion() == VERSION)
    }
}
