import CryptoKit
import Foundation

public enum CloudAccountMarkerComparison: Equatable, Sendable {
  case established
  case matches
  case changed
}

public enum CloudAccountMarkerStoreError: Error, Equatable, Sendable {
  case invalidRecordName
}

public struct CloudAccountMarkerStore: Sendable {
  static let secureAccount = "icloud-private-account-marker"

  private let secure: any SecureTokenStore

  public init(secure: any SecureTokenStore = KeychainStore()) {
    self.secure = secure
  }

  public func compareAndEstablish(recordName: String) throws -> CloudAccountMarkerComparison {
    let candidate = try digest(recordName: recordName)
    guard let current = try secure.read(account: Self.secureAccount) else {
      try secure.save(candidate, account: Self.secureAccount)
      return .established
    }
    return current == candidate ? .matches : .changed
  }

  public func replaceAfterConfirmation(recordName: String) throws {
    try secure.save(try digest(recordName: recordName), account: Self.secureAccount)
  }

  private func digest(recordName: String) throws -> Data {
    guard !recordName.isEmpty else { throw CloudAccountMarkerStoreError.invalidRecordName }
    return Data(SHA256.hash(data: Data(recordName.utf8)))
  }
}
