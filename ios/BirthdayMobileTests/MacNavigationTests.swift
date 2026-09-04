import Foundation
import Testing

@testable import BirthdayMobile

@Test func macNavigationKeepsSelectionWhileNarrowLayoutCollapsesDetail() {
  let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  var state = MacNavigationState()

  state.reduce(.selectSection(.birthdays))
  state.reduce(.selectRecord(id))

  #expect(state.section == .birthdays)
  #expect(state.selectedRecordID == id)
  #expect(state.showsDetail)

  state.reduce(.windowWidthChanged(900))

  #expect(state.selectedRecordID == id)
  #expect(!state.showsDetail)

  state.reduce(.windowWidthChanged(1_080))
  #expect(state.showsDetail)
}

@Test func macNavigationRoutesNewSearchSettingsAndDeleteCommands() {
  let id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  var state = MacNavigationState()

  state.reduce(.command(.newBirthday))
  #expect(state.editorRoute == .new)

  state.reduce(.dismissEditor)
  state.reduce(.command(.focusSearch))
  #expect(state.section == .birthdays)
  #expect(state.searchFocusGeneration == 1)

  state.reduce(.selectRecord(id))
  state.reduce(.command(.deleteSelection))
  #expect(state.deleteCandidateID == id)

  state.reduce(.cancelDelete)
  state.reduce(.command(.openSettings))
  #expect(state.section == .settings)
  #expect(state.deleteCandidateID == nil)
  #expect(!state.showsDetail)
}

@Test func macNavigationDoubleClickSelectsAndOpensTheRecordEditor() {
  let id = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  var state = MacNavigationState()

  state.reduce(.doubleClickRecord(id))

  #expect(state.selectedRecordID == id)
  #expect(state.editorRoute == .edit(id))
}
