import ReaderCore
import SwiftUI

let companionPairingCodeAccount = "companion-pairing-code"

extension Notification.Name {
  static let companionPairingCodeDidChange = Notification.Name("PDFMathReaderCompanionPairingCodeDidChange")
}

extension ReaderTranslationService {
  /// The service PDFMathReader on the computer uses for a page. API keys stay
  /// on this device, so OpenAI-compatible translation lets the computer choose.
  var companionService: String {
    switch self {
    case .siliconFlowFree: "siliconflow-free"
    case .appleOnDevice: "apple-local"
    case .openAICompatible: "auto"
    }
  }
}

/// PDFMathReader on the user's computer, which shares its Fast and Precise kernels.
struct ComputerKernelSettingsSection: View {
  @Binding var preferences: ReaderPreferences
  @State private var pairingCode = ""
  @State private var savedPairingCode = ""
  @State private var didLoad = false
  @State private var health: CompanionHealth?
  @State private var isChecking = false
  private let credentialStore = KeychainCredentialStore()

  var body: some View {
    Section {
      TextField(L10n.string("ios.computerAddress"), text: $preferences.companionURL, prompt: Text(verbatim: "my-mac.local"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
      SecureField(L10n.string("ios.pairingCode"), text: $pairingCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .onSubmit { savePairingCode() }
      KernelCheckRow(
        isChecking: isChecking,
        ok: health?.ok,
        message: health.map { $0.ok ? L10n.string("ios.connected") : $0.reason },
        action: check
      )
      if let health, health.ok {
        ForEach([ReaderEngine.fast, .precise], id: \.self) { engine in
          let id = engine == .fast ? CompanionKernel.fast : CompanionKernel.precise
          let status = health.kernels.first { $0.id == id }
          LabeledContent {
            Text(status?.available == true ? (status?.version ?? "") : (status?.reason ?? ""))
              .font(.footnote)
              .lineLimit(2)
          } label: {
            Label(
              engine.displayName,
              systemImage: status?.available == true ? "checkmark.circle.fill" : "xmark.circle"
            )
            .foregroundStyle(status?.available == true ? .green : .secondary)
          }
        }
      }
    } header: {
      Text(L10n.string("ios.computerKernel"))
    } footer: {
      Text(L10n.string("ios.computerKernelDescription"))
    }
    .task {
      guard !didLoad else { return }
      let stored = (try? await credentialStore.read(account: companionPairingCodeAccount)) ?? ""
      pairingCode = stored
      savedPairingCode = stored
      didLoad = true
    }
    .onDisappear { savePairingCode() }
  }

  private func check() {
    savePairingCode()
    isChecking = true
    let url = preferences.companionURL
    let code = pairingCode
    Task {
      health = await CompanionKernelClient().health(url, pairingCode: code, force: true)
      isChecking = false
    }
  }

  private func savePairingCode() {
    let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard didLoad, code != savedPairingCode else { return }
    savedPairingCode = code
    Task { @MainActor in
      if code.isEmpty {
        try? await credentialStore.delete(account: companionPairingCodeAccount)
      } else {
        try? await credentialStore.save(code, account: companionPairingCodeAccount)
      }
      NotificationCenter.default.post(name: .companionPairingCodeDidChange, object: nil)
    }
  }
}

/// A zotero-pdf2zh compatible server that replaces the Precise kernel, as on the desktop.
struct RemoteKernelSettingsSection: View {
  @Binding var preferences: ReaderPreferences
  @State private var health: RemoteKernelHealth?
  @State private var isChecking = false

  var body: some View {
    Section {
      Toggle(L10n.string("ios.remoteKernelToggle"), isOn: $preferences.remoteKernelEnabled)
      if preferences.remoteKernelEnabled {
        TextField(L10n.string("ios.serverURL"), text: $preferences.remoteKernelURL, prompt: Text(verbatim: "http://127.0.0.1:8890"))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField(L10n.string("ios.remoteKernelService"), text: $preferences.remoteKernelService)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        KernelCheckRow(
          isChecking: isChecking,
          ok: health?.ok,
          message: health.map { $0.ok ? L10n.string("ios.connected") : $0.reason },
          action: check
        )
      }
    } header: {
      Text(L10n.string("ios.remoteKernel"))
    } footer: {
      Text(L10n.string("ios.remoteKernelDescription"))
    }
  }

  private func check() {
    isChecking = true
    let url = preferences.remoteKernelURL
    Task {
      health = await RemoteKernelClient().health(url, force: true)
      isChecking = false
    }
  }
}

private struct KernelCheckRow: View {
  let isChecking: Bool
  let ok: Bool?
  let message: String?
  let action: () -> Void

  var body: some View {
    HStack {
      Button(action: action) {
        if isChecking {
          ProgressView()
            .controlSize(.small)
        } else {
          Text(L10n.string("ios.checkConnection"))
        }
      }
      .disabled(isChecking)
      if let ok, let message, !isChecking {
        Spacer()
        Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
          .foregroundStyle(ok ? .green : .secondary)
          .font(.footnote)
          .lineLimit(2)
      }
    }
  }
}
