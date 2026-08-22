import Foundation

public struct AppConfiguration: Equatable, Sendable {
  public static let invalidEndpointMessage = "服务器地址未安全配置，当前仅使用本机数据。"

  public let remoteBaseURL: URL?
  public let localOnlyMessage: String?

  public init(apiBaseURLValue: Any?) {
    guard
      let rawValue = apiBaseURLValue as? String,
      let components = URLComponents(
        string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      ),
      components.scheme?.lowercased() == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let url = components.url
    else {
      remoteBaseURL = nil
      localOnlyMessage = Self.invalidEndpointMessage
      return
    }

    remoteBaseURL = url
    localOnlyMessage = nil
  }
}
