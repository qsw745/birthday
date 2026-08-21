import Testing
@testable import BirthdayCore

@Test func exposesCoreVersion() {
    #expect(BirthdayCore.version == 1)
}
