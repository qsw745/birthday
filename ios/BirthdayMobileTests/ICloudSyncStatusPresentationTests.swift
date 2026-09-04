import Foundation
import Testing
@testable import BirthdayMobile

struct ICloudSyncStatusPresentationTests {
  @Test
  func synchronizedDetailUsesStableChineseDateAndDeviceTimeZone() throws {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

    #expect(
      ICloudSyncStatusPresentation.synchronizedDetail(date, timeZone: timeZone)
        == "最近完成：2027年1月15日 16:00"
    )
  }
}
