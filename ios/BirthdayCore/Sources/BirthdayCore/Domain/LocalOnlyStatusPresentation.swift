public struct LocalOnlyStatusPresentation: Equatable, Sendable {
  public let title: String
  public let detail: String

  public static func make(for syncState: SyncState) -> Self {
    _ = syncState
    return Self(title: "仅存于本机", detail: "服务器同步尚未启用")
  }

  public static func deletionConfirmation(name: String) -> String {
    "确定删除“\(name)”吗？删除后只会从本机隐藏。服务器同步尚未启用。"
  }
}
