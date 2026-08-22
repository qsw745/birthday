import Foundation
import Testing

@testable import BirthdayCore

@Test func validHTTPSAPIEndpointEnablesRemoteSync() throws {
  let configuration = AppConfiguration(
    apiBaseURLValue: "https://example.com/api/mobile"
  )

  #expect(configuration.remoteBaseURL == URL(string: "https://example.com/api/mobile"))
  #expect(configuration.localOnlyMessage == nil)
}

@Test(
  arguments: [
    nil,
    "",
    "http://example.com/api/mobile",
    "https:///api/mobile",
    "$(BIRTHDAY_API_BASE_URL)",
  ] as [String?]
)
func missingOrInvalidAPIEndpointFallsBackToVisibleLocalOnlyMode(value: String?) {
  let configuration = AppConfiguration(apiBaseURLValue: value)

  #expect(configuration.remoteBaseURL == nil)
  #expect(configuration.localOnlyMessage == "服务器地址未安全配置，当前仅使用本机数据。")
}
