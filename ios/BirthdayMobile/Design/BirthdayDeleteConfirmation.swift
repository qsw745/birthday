import SwiftUI

/// Keeps desktop confirmations centered in the presenting surface, including the editor.
private struct BirthdayDeleteConfirmation: ViewModifier {
  @Binding var isPresented: Bool
  let message: String
  let confirm: () -> Void

  func body(content: Content) -> some View {
    #if targetEnvironment(macCatalyst)
      content
        .disabled(isPresented)
        .accessibilityHidden(isPresented)
        .overlay {
          if isPresented {
            ZStack {
              Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)

              DesktopDeleteDialog(message: message) {
                isPresented = false
              } confirm: {
                // The caller captures the candidate before this binding clears it.
                confirm()
                isPresented = false
              }
              .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
    #else
      content.confirmationDialog(
        "确认删除",
        isPresented: $isPresented,
        titleVisibility: .visible
      ) {
        Button("确认删除", role: .destructive, action: confirm)
        Button("取消", role: .cancel) {}
      } message: {
        Text(message)
      }
    #endif
  }
}

private struct DesktopDeleteDialog: View {
  let message: String
  let cancel: () -> Void
  let confirm: () -> Void
  @AccessibilityFocusState private var titleIsFocused: Bool

  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "trash")
        .font(.system(size: 25, weight: .medium))
        .foregroundStyle(.red)
        .frame(width: 58, height: 58)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityHidden(true)

      VStack(spacing: 10) {
        Text("确认删除")
          .font(.system(.title3, design: .rounded, weight: .semibold))
          .foregroundStyle(ModernAirTheme.ink)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($titleIsFocused)

        Text(message)
          .font(.body)
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 12) {
        Button("取消", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("cancelBirthdayDeletion")

        Button("确认删除", role: .destructive, action: confirm)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .accessibilityIdentifier("confirmBirthdayDeletion")
      }
      .controlSize(.large)
      .buttonBorderShape(.roundedRectangle(radius: 10))
    }
    .padding(28)
    .frame(width: 380)
    .background(ModernAirTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    .overlay {
      RoundedRectangle(cornerRadius: 24)
        .strokeBorder(ModernAirTheme.outline, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.16), radius: 32, y: 14)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("centeredBirthdayDeleteDialog")
    .onAppear { titleIsFocused = true }
  }
}

extension View {
  func birthdayDeleteConfirmation(
    isPresented: Binding<Bool>,
    message: String,
    confirm: @escaping () -> Void
  ) -> some View {
    modifier(
      BirthdayDeleteConfirmation(
        isPresented: isPresented,
        message: message,
        confirm: confirm
      )
    )
  }
}
