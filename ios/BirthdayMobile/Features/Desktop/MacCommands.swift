import SwiftUI

struct MacCommandHandler {
  let perform: (MacCommand) -> Void
}

private struct MacCommandHandlerKey: FocusedValueKey {
  typealias Value = MacCommandHandler
}

extension FocusedValues {
  var macCommandHandler: MacCommandHandler? {
    get { self[MacCommandHandlerKey.self] }
    set { self[MacCommandHandlerKey.self] = newValue }
  }
}

struct MacCommands: Commands {
  @FocusedValue(\.macCommandHandler) private var handler

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("新建生日") {
        handler?.perform(.newBirthday)
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(handler == nil)
    }

    CommandMenu("导航") {
      Button("搜索生日") {
        handler?.perform(.focusSearch)
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(handler == nil)

      Button("设置") {
        handler?.perform(.openSettings)
      }
      .keyboardShortcut(",", modifiers: .command)
      .disabled(handler == nil)

      Divider()

      Button("删除所选生日") {
        handler?.perform(.deleteSelection)
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(handler == nil)
    }
  }
}
