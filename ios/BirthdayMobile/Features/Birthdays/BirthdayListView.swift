import SwiftUI

struct BirthdayListView: View {
  @Bindable var model: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("全部生日", systemImage: "list.bullet")
    } description: {
      Text("搜索和最近日期排序将在下一步接入。")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("全部")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.isPresentingEditor = true
        } label: {
          Image(systemName: "plus")
            .frame(width: 44, height: 44)
        }
        .accessibilityLabel("添加生日")
      }
    }
  }
}

struct BirthdayEditorView: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationStack {
      ContentUnavailableView {
        Label("添加生日", systemImage: "gift")
      } description: {
        Text("新增生日表单将在下一步接入。")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(ModernAirTheme.mist.ignoresSafeArea())
      .navigationTitle("添加生日")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            model.isPresentingEditor = false
          }
          .frame(minHeight: 44)
        }
      }
    }
  }
}
