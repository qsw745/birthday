import Foundation

public enum MobileAPIError: Error, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  case accessExpired
  case refreshInvalid
  case invalidResponse
  case server(code: String, status: Int)
  case transport(String)

  public var description: String {
    switch self {
    case .accessExpired:
      "mobile API access expired"
    case .refreshInvalid:
      "mobile API refresh invalid"
    case .invalidResponse:
      "mobile API invalid response"
    case .server(let code, let status):
      "mobile API server error \(code) (\(status))"
    case .transport(let code):
      "mobile API transport error \(code)"
    }
  }

  public var debugDescription: String { description }
}

public protocol MobileAPI: Sendable {
  func login(_ request: LoginRequest) async throws -> TokenResponse
  func refresh(_ request: RefreshRequest) async throws -> TokenResponse
  func snapshot(accessToken: String) async throws -> SnapshotResponse
  func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse
  func pull(cursor: Int64, accessToken: String) async throws -> PullResponse
  func revoke(deviceId: UUID, accessToken: String) async throws
  func devices(accessToken: String) async throws -> [MobileDevice]
}

public struct MobileAPIClient: MobileAPI {
  private static let requestTimeout: TimeInterval = 20
  private static let pullLimit = 200

  private let baseURL: URL
  private let session: URLSession

  public init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  public func login(_ request: LoginRequest) async throws -> TokenResponse {
    try await send(
      method: "POST",
      path: ["auth", "login"],
      body: try encode(request),
      accessToken: nil,
      response: TokenResponse.self
    )
  }

  public func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
    try await send(
      method: "POST",
      path: ["auth", "refresh"],
      body: try encode(request),
      accessToken: nil,
      response: TokenResponse.self
    )
  }

  public func snapshot(accessToken: String) async throws -> SnapshotResponse {
    try await send(
      method: "GET",
      path: ["sync", "snapshot"],
      accessToken: accessToken,
      response: SnapshotResponse.self
    )
  }

  public func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse {
    try await send(
      method: "POST",
      path: ["sync", "push"],
      body: try encode(request),
      accessToken: accessToken,
      response: PushResponse.self
    )
  }

  public func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
    guard cursor >= 0 else { throw MobileAPIError.invalidResponse }

    var components = try urlComponents(path: ["sync", "pull"])
    components.queryItems = [
      URLQueryItem(name: "cursor", value: String(cursor)),
      URLQueryItem(name: "limit", value: String(Self.pullLimit)),
    ]
    guard let url = components.url else { throw MobileAPIError.invalidResponse }

    return try await send(
      method: "GET",
      url: url,
      accessToken: accessToken,
      response: PullResponse.self
    )
  }

  public func revoke(deviceId: UUID, accessToken: String) async throws {
    let response = try await send(
      method: "POST",
      path: ["auth", "revoke"],
      body: try encode(RevokeRequest(deviceId: deviceId)),
      accessToken: accessToken,
      response: RevokeResponse.self
    )
    guard response.success else { throw MobileAPIError.invalidResponse }
  }

  public func devices(accessToken: String) async throws -> [MobileDevice] {
    try await send(
      method: "GET",
      path: ["auth", "devices"],
      accessToken: accessToken,
      response: DevicesResponse.self
    ).devices
  }

  private func encode<Value: Encodable>(_ value: Value) throws -> Data {
    do {
      return try MobileJSON.encoder.encode(value)
    } catch {
      throw MobileAPIError.invalidResponse
    }
  }

  private func send<Response: Decodable>(
    method: String,
    path: [String],
    body: Data? = nil,
    accessToken: String?,
    response: Response.Type
  ) async throws -> Response {
    let url = path.reduce(baseURL) { partial, component in
      partial.appendingPathComponent(component, isDirectory: false)
    }
    return try await send(
      method: method,
      url: url,
      body: body,
      accessToken: accessToken,
      response: response
    )
  }

  private func send<Response: Decodable>(
    method: String,
    url: URL,
    body: Data? = nil,
    accessToken: String?,
    response: Response.Type
  ) async throws -> Response {
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body
    if body != nil {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let accessToken {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }

    let data: Data
    let urlResponse: URLResponse
    do {
      (data, urlResponse) = try await session.data(for: request)
    } catch let error as URLError {
      throw MobileAPIError.transport("url_error_\(error.code.rawValue)")
    } catch {
      throw MobileAPIError.transport("unknown")
    }

    guard let http = urlResponse as? HTTPURLResponse else {
      throw MobileAPIError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw try classifyError(status: http.statusCode, data: data)
    }

    do {
      return try MobileJSON.decoder.decode(Response.self, from: data)
    } catch {
      throw MobileAPIError.invalidResponse
    }
  }

  private func urlComponents(path: [String]) throws -> URLComponents {
    let url = path.reduce(baseURL) { partial, component in
      partial.appendingPathComponent(component, isDirectory: false)
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw MobileAPIError.invalidResponse
    }
    return components
  }

  private func classifyError(status: Int, data: Data) throws -> MobileAPIError {
    let envelope: ErrorResponse
    do {
      envelope = try MobileJSON.decoder.decode(ErrorResponse.self, from: data)
    } catch {
      throw MobileAPIError.invalidResponse
    }
    guard Self.isStableErrorCode(envelope.error) else {
      throw MobileAPIError.invalidResponse
    }

    if status == 401 {
      switch envelope.error {
      case "mobile_access_expired", "mobile_auth_required":
        return .accessExpired
      case "mobile_refresh_invalid":
        return .refreshInvalid
      default:
        break
      }
    }
    return .server(code: envelope.error, status: status)
  }

  private static func isStableErrorCode(_ code: String) -> Bool {
    let bytes = Array(code.utf8)
    guard (1...64).contains(bytes.count), let first = bytes.first,
      first >= Character("a").asciiValue!, first <= Character("z").asciiValue!
    else { return false }
    return bytes.dropFirst().allSatisfy { byte in
      (byte >= Character("a").asciiValue! && byte <= Character("z").asciiValue!)
        || (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
        || byte == Character("_").asciiValue!
    }
  }
}

private struct ErrorResponse: Decodable {
  let error: String
}

private struct RevokeRequest: Encodable {
  let deviceId: String

  init(deviceId: UUID) {
    self.deviceId = deviceId.uuidString.lowercased()
  }
}

private struct RevokeResponse: Decodable {
  let success: Bool
}

private struct DevicesResponse: Decodable {
  let devices: [MobileDevice]
}
