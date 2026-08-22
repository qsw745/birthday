public struct LocalOnlyStatusPresentation: Equatable, Sendable {
  public let title: String
  public let detail: String

  public static func make(for syncState: SyncState) -> Self {
    _ = syncState
    return Self(title: "仅存于本机", detail: "资料只保存在这台设备上")
  }

  public static func deletionConfirmation(name: String) -> String {
    "确定删除“\(name)”吗？删除后将从本机生日列表移除。"
  }
}
