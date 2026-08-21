import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    ContentUnavailableView {
      Label("设置", systemImage: "gearshape")
    } description: {
      Text("通知、Face ID 与同步设置将在下一步接入。")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("设置")
  }
}
