import Foundation
import Testing

@testable import BirthdayCore

private let apiDeviceID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let apiOperationID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let apiAccessToken = "fixture-access-token"
private let apiRefreshToken = "fixture-refresh-token"
private let apiPassword = "fixture-password"

private let tokenResponseJSON =
  #"{"deviceId":"11111111-1111-4111-8111-111111111111","accessToken":"fixture-access-token","accessExpiresAt":"2026-08-22T00:15:00.000Z","refreshToken":"fixture-refresh-token","refreshExpiresAt":"2027-02-18T00:00:00.000Z"}"#
private let deviceResponseJSON =
  #"{"devices":[{"deviceId":"11111111-1111-4111-8111-111111111111","deviceName":"QSW iPhone","createdAt":"2026-08-22T00:00:00.000Z","lastUsedAt":null,"revokedAt":null}]}"#

@Suite struct MobileAPIClientTests {
  @Test func loginUsesDocumentedRequestWithoutBearerAndDecodesTokens() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: tokenResponseJSON)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    let response = try await api.login(
      LoginRequest(
        username: "admin",
        password: apiPassword,
        deviceId: apiDeviceID,
        deviceName: "QSW iPhone"
      ))

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/mobile/auth/login")
    #expect(request.url?.query == nil)
    #expect(request.timeoutInterval == 20)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let hasNoAuthorization = request.value(forHTTPHeaderField: "Authorization") == nil
    let bodyMatchesContract = matchesLoginBody(request.httpBody)
    let responseMatchesContract = matchesTokenResponse(response)
    #expect(hasNoAuthorization)
    #expect(bodyMatchesContract)
    #expect(responseMatchesContract)
  }

  @Test func refreshUsesDocumentedRequestWithoutBearer() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: tokenResponseJSON)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    _ = try await api.refresh(RefreshRequest(refreshToken: apiRefreshToken))

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/mobile/auth/refresh")
    let hasNoAuthorization = request.value(forHTTPHeaderField: "Authorization") == nil
    let bodyMatchesContract = matchesRefreshBody(request.httpBody)
    #expect(hasNoAuthorization)
    #expect(bodyMatchesContract)
  }

  @Test func snapshotSendsBearerAndDecodesProductionWrapper() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(
        request,
        status: 200,
        body: #"{"cursor":"41","birthdays":[]}"#
      )
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    let response = try await api.snapshot(accessToken: apiAccessToken)

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/mobile/sync/snapshot")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    let bearerMatches = hasExpectedBearer(request)
    #expect(bearerMatches)
    #expect(response.cursor == 41)
    #expect(response.birthdays.isEmpty)
  }

  @Test func pushUsesProductionCompactEncoderAndDecodesResultsWrapper() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: #"{"results":[]}"#)
    }
    defer { fixture.close() }
    let push = PushRequest(
      operations: [
        PushOperationDTO(
          operationId: apiOperationID,
          entityId: apiDeviceID,
          type: .delete,
          baseVersion: Int64.max,
          payload: nil
        )
      ])

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    let response = try await api.push(push, accessToken: apiAccessToken)

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/mobile/sync/push")
    let bearerMatches = hasExpectedBearer(request)
    let bodyMatchesContract = matchesExactPushBody(request.httpBody)
    #expect(bearerMatches)
    #expect(bodyMatchesContract)
    #expect(response.results.isEmpty)
  }

  @Test func pullUsesCanonicalCursorAndExplicitMaximumLimit() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(
        request,
        status: 200,
        body: #"{"changes":[],"nextCursor":"9223372036854775807","hasMore":false}"#
      )
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    let response = try await api.pull(cursor: Int64.max, accessToken: apiAccessToken)

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/mobile/sync/pull")
    #expect(request.url?.query == "cursor=9223372036854775807&limit=200")
    #expect(request.httpBody == nil)
    let bearerMatches = hasExpectedBearer(request)
    #expect(bearerMatches)
    #expect(response.nextCursor == Int64.max)
    #expect(response.changes.isEmpty)
    #expect(response.hasMore == false)
  }

  @Test func negativePullCursorFailsClosedWithoutSendingRequest() async {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(
        request,
        status: 200,
        body: #"{"changes":[],"nextCursor":"0","hasMore":false}"#
      )
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.invalidResponse) {
      try await api.pull(cursor: -1, accessToken: apiAccessToken)
    }
    #expect(recorder.count == 0)
  }

  @Test func revokeSendsDeviceBodyAndRequiresExplicitTrueSuccess() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: #"{"success":true}"#)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    try await api.revoke(deviceId: apiDeviceID, accessToken: apiAccessToken)

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/mobile/auth/revoke")
    let bearerMatches = hasExpectedBearer(request)
    let bodyMatchesContract = matchesRevokeBody(request.httpBody)
    #expect(bearerMatches)
    #expect(bodyMatchesContract)
  }

  @Test(arguments: malformedRevokeBodies)
  func revokeRejectsFalseMissingOrMalformedSuccess(value: MalformedBodyFixture) async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(request, status: 200, body: value.body)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.invalidResponse) {
      try await api.revoke(deviceId: apiDeviceID, accessToken: apiAccessToken)
    }
  }

  @Test func devicesUsesBearerAndDecodesDevicesWrapper() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: deviceResponseJSON)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    let devices = try await api.devices(accessToken: apiAccessToken)

    let request = try #require(recorder.onlyRequest)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/api/mobile/auth/devices")
    #expect(request.httpBody == nil)
    let bearerMatches = hasExpectedBearer(request)
    #expect(bearerMatches)
    #expect(devices.count == 1)
    #expect(devices.first?.deviceId == apiDeviceID)
    #expect(devices.first?.deviceName == "QSW iPhone")
  }

  @Test(arguments: ["mobile_access_expired", "mobile_auth_required"])
  func unauthorizedAccessCodesRequestRefresh(code: String) async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(request, status: 401, body: stableErrorBody(code))
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.accessExpired) {
      try await api.snapshot(accessToken: apiAccessToken)
    }
  }

  @Test func invalidRefreshCodeIsClassifiedSeparately() async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(
        request,
        status: 401,
        body: stableErrorBody("mobile_refresh_invalid")
      )
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.refreshInvalid) {
      try await api.refresh(RefreshRequest(refreshToken: apiRefreshToken))
    }
  }

  @Test(
    arguments: [
      ServerErrorFixture(status: 401, code: "mobile_login_invalid"),
      ServerErrorFixture(status: 409, code: "mobile_device_ownership_conflict"),
      ServerErrorFixture(status: 429, code: "api_rate_limited"),
      ServerErrorFixture(status: 429, code: "mobile_login_rate_limited"),
      ServerErrorFixture(status: 413, code: "payload_too_large"),
      ServerErrorFixture(status: 500, code: "server_error"),
    ])
  func preservesStableServerErrorCodeAndStatus(value: ServerErrorFixture) async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(request, status: value.status, body: stableErrorBody(value.code))
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.server(code: value.code, status: value.status)) {
      try await api.snapshot(accessToken: apiAccessToken)
    }
  }

  @Test(arguments: malformedErrorBodies)
  func malformedErrorBodiesFailClosed(value: MalformedBodyFixture) async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(request, status: 400, body: value.body)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.invalidResponse) {
      try await api.snapshot(accessToken: apiAccessToken)
    }
  }

  @Test(arguments: malformedSuccessBodies)
  func malformedOrWrongTypeSuccessBodiesFailClosed(value: MalformedBodyFixture) async {
    let fixture = APIProtocolFixture { request in
      try httpResponse(request, status: 200, body: value.body)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.invalidResponse) {
      try await api.snapshot(accessToken: apiAccessToken)
    }
  }

  @Test func nonHTTPResponsesAreInvalid() async {
    let fixture = APIProtocolFixture { request in
      let response = URLResponse(
        url: request.url!,
        mimeType: "application/json",
        expectedContentLength: 2,
        textEncodingName: "utf-8"
      )
      return ProtocolPayload(response: response, data: Data("{}".utf8))
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    await #expect(throws: MobileAPIError.invalidResponse) {
      try await api.snapshot(accessToken: apiAccessToken)
    }
  }

  @Test func transportErrorsUseStableSanitizedCodes() async {
    let timedOut = APIProtocolFixture { _ in throw URLError(.timedOut) }
    defer { timedOut.close() }
    let timedOutAPI = MobileAPIClient(baseURL: timedOut.baseURL, session: timedOut.session)

    await #expect(throws: MobileAPIError.transport("url_error_-1001")) {
      try await timedOutAPI.snapshot(accessToken: apiAccessToken)
    }

    let secretMarker = "must-not-escape-transport"
    let unknown = APIProtocolFixture { _ in throw SecretTransportError(marker: secretMarker) }
    defer { unknown.close() }
    let unknownAPI = MobileAPIClient(baseURL: unknown.baseURL, session: unknown.session)
    let error = await captureError {
      try await unknownAPI.snapshot(accessToken: apiAccessToken)
    }

    #expect(error == .transport("unknown"))
    let descriptionIsSanitized = isSanitized(error, excluding: secretMarker)
    #expect(descriptionIsSanitized)
  }

  @Test func trailingSlashBaseURLStillAppendsKnownComponentsOnce() async throws {
    let recorder = RequestRecorder()
    let fixture = APIProtocolFixture(basePath: "/api/mobile/") { request in
      try recorder.append(request)
      return try httpResponse(request, status: 200, body: tokenResponseJSON)
    }
    defer { fixture.close() }

    let api = MobileAPIClient(baseURL: fixture.baseURL, session: fixture.session)
    _ = try await api.refresh(RefreshRequest(refreshToken: apiRefreshToken))

    let request = try #require(recorder.onlyRequest)
    #expect(request.url?.path == "/api/mobile/auth/refresh")
    #expect(!request.url!.absoluteString.contains("mobile//auth"))
  }
}

struct ServerErrorFixture: Sendable {
  let status: Int
  let code: String
}

struct MalformedBodyFixture: Sendable, CustomTestStringConvertible {
  let label: String
  let body: String

  var testDescription: String { label }
}

private let malformedRevokeBodies = [
  MalformedBodyFixture(label: "false", body: #"{"success":false}"#),
  MalformedBodyFixture(label: "missing", body: #"{}"#),
  MalformedBodyFixture(label: "wrong-type", body: #"{"success":"true"}"#),
  MalformedBodyFixture(label: "invalid-json", body: "not-json"),
]

private let malformedErrorBodies = [
  MalformedBodyFixture(label: "empty", body: ""),
  MalformedBodyFixture(label: "invalid-json", body: "not-json"),
  MalformedBodyFixture(label: "missing-error", body: #"{}"#),
  MalformedBodyFixture(label: "wrong-error-type", body: #"{"error":1}"#),
  MalformedBodyFixture(label: "wrong-outer-type", body: #"[]"#),
]

private let malformedSuccessBodies = [
  MalformedBodyFixture(label: "empty", body: ""),
  MalformedBodyFixture(label: "invalid-json", body: "not-json"),
  MalformedBodyFixture(label: "wrong-outer-type", body: #"[]"#),
  MalformedBodyFixture(label: "unquoted-cursor", body: #"{"cursor":0,"birthdays":[]}"#),
]

private struct SecretTransportError: Error, Sendable, CustomStringConvertible {
  let marker: String
  var description: String { marker }
}

private func captureError(
  operation: () async throws -> some Sendable
) async -> MobileAPIError? {
  do {
    _ = try await operation()
    return nil
  } catch let error as MobileAPIError {
    return error
  } catch {
    return nil
  }
}

private func isSanitized(_ error: MobileAPIError?, excluding marker: String) -> Bool {
  guard let error else { return false }
  return !String(describing: error).contains(marker)
    && !String(reflecting: error).contains(marker)
}

private func hasExpectedBearer(_ request: URLRequest) -> Bool {
  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiAccessToken)"
}

private func matchesTokenResponse(_ response: TokenResponse) -> Bool {
  response.deviceId == apiDeviceID
    && response.accessToken == apiAccessToken
    && response.refreshToken == apiRefreshToken
}

private func matchesLoginBody(_ data: Data?) -> Bool {
  guard let object = jsonObject(data) else { return false }
  return Set(object.keys) == ["username", "password", "deviceId", "deviceName"]
    && object["username"] as? String == "admin"
    && object["password"] as? String == apiPassword
    && object["deviceId"] as? String == apiDeviceID.uuidString.lowercased()
    && object["deviceName"] as? String == "QSW iPhone"
}

private func matchesRefreshBody(_ data: Data?) -> Bool {
  guard let object = jsonObject(data) else { return false }
  return Set(object.keys) == ["refreshToken"]
    && object["refreshToken"] as? String == apiRefreshToken
}

private func matchesRevokeBody(_ data: Data?) -> Bool {
  guard let object = jsonObject(data) else { return false }
  return Set(object.keys) == ["deviceId"]
    && object["deviceId"] as? String == apiDeviceID.uuidString.lowercased()
}

private func matchesExactPushBody(_ data: Data?) -> Bool {
  guard let data, let object = jsonObject(data), Set(object.keys) == ["operations"],
    let operations = object["operations"] as? [[String: Any]], operations.count == 1,
    let operation = operations.first
  else { return false }

  let exactKeys = Set(["operationId", "entityId", "type", "baseVersion"])
  return Set(operation.keys) == exactKeys
    && operation["operationId"] as? String == apiOperationID.uuidString.lowercased()
    && operation["entityId"] as? String == apiDeviceID.uuidString.lowercased()
    && operation["type"] as? String == "delete"
    && operation["baseVersion"] as? String == "9223372036854775807"
    && !String(decoding: data, as: UTF8.self).contains("\n")
    && !String(decoding: data, as: UTF8.self).contains("  ")
}

private func jsonObject(_ data: Data?) -> [String: Any]? {
  guard let data else { return nil }
  return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func stableErrorBody(_ code: String) -> String {
  let data = try! JSONSerialization.data(withJSONObject: ["error": code])
  return String(decoding: data, as: UTF8.self)
}

private func httpResponse(
  _ request: URLRequest,
  status: Int,
  body: String
) throws -> ProtocolPayload {
  let response = try #require(
    HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )
  )
  return ProtocolPayload(response: response, data: Data(body.utf8))
}

private struct ProtocolPayload: @unchecked Sendable {
  let response: URLResponse
  let data: Data
}

private final class RequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [URLRequest] = []

  var onlyRequest: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    guard requests.count == 1 else { return nil }
    return requests[0]
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }

  func append(_ request: URLRequest) throws {
    var captured = request
    captured.httpBody = try requestBody(request)
    lock.lock()
    requests.append(captured)
    lock.unlock()
  }
}

private func requestBody(_ request: URLRequest) throws -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }

  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while true {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 {
      throw stream.streamError ?? URLError(.cannotDecodeRawData)
    }
    if count == 0 { return data }
    data.append(buffer, count: count)
  }
}

private final class URLProtocolRegistry: @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> ProtocolPayload

  static let shared = URLProtocolRegistry()

  private let lock = NSLock()
  private var handlers: [String: Handler] = [:]

  func register(host: String, handler: @escaping Handler) {
    lock.lock()
    handlers[host] = handler
    lock.unlock()
  }

  func unregister(host: String) {
    lock.lock()
    handlers.removeValue(forKey: host)
    lock.unlock()
  }

  func handler(for request: URLRequest) -> Handler? {
    guard let host = request.url?.host else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return handlers[host]
  }
}

private final class IsolatedURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    return URLProtocolRegistry.shared.handler(for: request) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    guard let handler = URLProtocolRegistry.shared.handler(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    do {
      let payload = try handler(request)
      client?.urlProtocol(self, didReceive: payload.response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: payload.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class APIProtocolFixture: @unchecked Sendable {
  let baseURL: URL
  let session: URLSession
  private let host: String

  init(
    basePath: String = "/api/mobile",
    handler: @escaping URLProtocolRegistry.Handler
  ) {
    host = "client-\(UUID().uuidString.lowercased()).example"
    baseURL = URL(string: "https://\(host)\(basePath)")!
    URLProtocolRegistry.shared.register(host: host, handler: handler)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [IsolatedURLProtocol.self]
    session = URLSession(configuration: configuration)
  }

  func close() {
    session.invalidateAndCancel()
    URLProtocolRegistry.shared.unregister(host: host)
  }
}
