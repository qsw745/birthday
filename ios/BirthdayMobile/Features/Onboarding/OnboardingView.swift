import SwiftUI

struct OnboardingView: View {
  @Bindable var model: AppModel
  @State private var page = 0

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        stepIndicator

        if page == 0 {
          introduction(
            systemImage: "iphone.gen3",
            title: "离线也能完整使用",
            message: "生日资料保存在这台 iPhone 上。没有网络时，查看、添加、编辑和删除仍可立即完成。"
          )

          Button("继续") {
            page = 1
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(ModernAirTheme.tide)
          .frame(maxWidth: .infinity, minHeight: 44)
        } else if page == 1 {
          introduction(
            systemImage: "bell.badge.fill",
            title: "由 iPhone 按时提醒",
            message: "允许通知后，提醒会直接安排在本机。是否开启由你决定，也可以稍后在系统设置中更改。"
          )

          if let errorMessage = model.onboardingErrorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
              .font(.subheadline)
              .foregroundStyle(ModernAirTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .padding(16)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
              .accessibilityElement(children: .combine)
          }

          VStack(spacing: 12) {
            Button {
              continueAfterNotifications(requestNotifications: true)
            } label: {
              onboardingActionLabel("开启通知", systemImage: "bell.badge")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ModernAirTheme.tide)

            Button("暂不开启") {
              continueAfterNotifications(requestNotifications: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(ModernAirTheme.tide)
          }
          .disabled(model.isCompletingOnboarding)
        } else if page == 2 {
          ServerBindingView(
            model: model,
            onSkip: {
              model.finishOnboarding()
            },
            onBound: {
              page = 3
            }
          )
        } else {
          snapshotPreviewHook
        }
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 24)
      .padding(.top, 40)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity)
    }
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      Capsule()
        .fill(ModernAirTheme.tide)
        .frame(width: page == 0 ? 32 : 12, height: 6)
      Capsule()
        .fill(page == 1 ? ModernAirTheme.tide : ModernAirTheme.outline)
        .frame(width: page == 1 ? 32 : 12, height: 6)
      Capsule()
        .fill(page >= 2 ? ModernAirTheme.tide : ModernAirTheme.outline)
        .frame(width: page >= 2 ? 32 : 12, height: 6)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("引导进度")
    .accessibilityValue("第 \(min(page, 2) + 1) 页，共 3 页")
  }

  private func introduction(systemImage: String, title: String, message: String) -> some View {
    VStack(spacing: 22) {
      Image(systemName: systemImage)
        .font(.system(size: 46, weight: .medium))
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 92, height: 92)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 28))
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text(title)
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.ink)

        Text(message)
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity)
    .modernAirSurface(radius: 30)
  }

  private func onboardingActionLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 9) {
      if model.isCompletingOnboarding {
        ProgressView()
          .tint(.white)
          .accessibilityHidden(true)
      } else {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
      }
      Text(model.isCompletingOnboarding ? "正在设置" : title)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
  }

  private var snapshotPreviewHook: some View {
    VStack(spacing: 22) {
      introduction(
        systemImage: "checkmark.icloud.fill",
        title: "设备已绑定，尚未导入",
        message: "同步凭据已安全保存。首次快照预览将在下一步提供；目前没有写入服务器生日资料，也没有推进同步游标。"
      )

      Label("你可以先继续使用本地模式，查看、添加和提醒都不依赖服务器。", systemImage: "iphone.gen3")
        .font(.subheadline)
        .foregroundStyle(ModernAirTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)

      Button("先使用本地模式") {
        model.finishOnboarding()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(ModernAirTheme.tide)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityIdentifier("continueLocalAfterBindingButton")
    }
  }

  private func continueAfterNotifications(requestNotifications: Bool) {
    guard !model.isCompletingOnboarding else { return }
    Task {
      if await model.prepareOnboardingNotifications(
        requestNotifications: requestNotifications
      ) {
        page = 2
      }
    }
  }
}
