import BirthdayCore
import SwiftUI
import UniformTypeIdentifiers

struct DataExportView: View {
  @Bindable var model: AppModel
  @State private var document: BirthdayJSONExportDocument?
  @State private var defaultFileName = "岁时-生日数据.json"
  @State private var isPreparing = false
  @State private var isPresentingExporter = false
  @State private var errorMessage: String?

  var body: some View {
    Section {
      Button {
        prepareExport()
      } label: {
        HStack(spacing: 10) {
          if isPreparing {
            ProgressView()
              .accessibilityHidden(true)
          } else {
            Image(systemName: "square.and.arrow.up")
              .foregroundStyle(ModernAirTheme.tide)
              .accessibilityHidden(true)
          }

          VStack(alignment: .leading, spacing: 3) {
            Text(isPreparing ? "正在准备导出" : "导出生日数据")
              .foregroundStyle(ModernAirTheme.ink)
            Text("保存为 UTF-8 JSON 文件")
              .font(.caption)
              .foregroundStyle(ModernAirTheme.secondaryInk)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
      .disabled(isPreparing)
      .accessibilityIdentifier("exportBirthdayDataButton")
    } header: {
      Text("数据导出")
    } footer: {
      Text("只读取当前本机可见的生日，不会先请求 iCloud 或服务器，也不包含同步、账号、通知权限和隐藏邮件字段。")
    }
    .fileExporter(
      isPresented: $isPresentingExporter,
      document: document,
      contentType: .json,
      defaultFilename: defaultFileName
    ) { result in
      document = nil
      guard case .failure(let error) = result else { return }
      guard !Self.isUserCancellation(error) else { return }
      errorMessage = "无法保存导出文件，请检查目标位置是否可写后重试。"
    }
    .alert("导出失败", isPresented: exportErrorPresented) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "无法完成导出，请重试。")
    }
  }

  private var exportErrorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented { errorMessage = nil }
      }
    )
  }

  private func prepareExport() {
    guard !isPreparing else { return }
    isPreparing = true
    errorMessage = nil

    Task {
      defer { isPreparing = false }
      do {
        let artifact = try await BirthdayExportService(store: model.store).makeExport(
          timeZone: .current
        )
        document = BirthdayJSONExportDocument(data: artifact.data)
        defaultFileName = artifact.fileName
        isPresentingExporter = true
      } catch {
        errorMessage = "无法读取本机生日资料，未生成导出文件。请重试。"
      }
    }
  }

  private static func isUserCancellation(_ error: Error) -> Bool {
    let cocoaError = error as NSError
    return cocoaError.domain == NSCocoaErrorDomain
      && cocoaError.code == CocoaError.userCancelled.rawValue
  }
}

private struct BirthdayJSONExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
