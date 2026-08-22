import Testing

@testable import BirthdayCore

@Test(arguments: [SyncState.synced, .pending, .conflict, .pendingDelete])
func planOneStatusNeverPromisesCloudSynchronization(_ state: SyncState) {
  let presentation = LocalOnlyStatusPresentation.make(for: state)

  #expect(presentation.title == "仅存于本机")
  #expect(presentation.detail == "资料只保存在这台设备上")
}
@Test func deletionCopyStatesTheLocalOnlyBoundary() {
  #expect(
    LocalOnlyStatusPresentation.deletionConfirmation(name: "妈妈")
      == "确定删除“妈妈”吗？删除后将从本机生日列表移除。"
  )
}
