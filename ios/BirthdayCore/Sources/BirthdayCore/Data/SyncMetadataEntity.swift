import Foundation
import SwiftData

@Model
public final class SyncMetadataEntity {
  @Attribute(.unique) public var key: String
  public var cursor: Int64

  public init(key: String, cursor: Int64) {
    self.key = key
    self.cursor = cursor
  }
}
