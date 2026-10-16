import ReaderCore
import SwiftUI

/// Settings for the disposable translation and remote math page caches.
struct TranslationCacheSettingsSection: View {
  private static let limitKey = "translationCacheLimitBytes"
  private static let defaultLimit = TranslationCacheManagement.defaultLimitBytes
  private static let limits: [Int64] = [
    512 * 1_024 * 1_024,
    1_024 * 1_024 * 1_024,
    2 * 1_024 * 1_024 * 1_024,
    5 * 1_024 * 1_024 * 1_024,
    10 * 1_024 * 1_024 * 1_024,
  ]

  private let cacheManager: TranslationCacheManagement
  private let defaults: UserDefaults
  @State private var usageBytes: Int64 = 0
  @State private var selectedLimit: Int64
  @State private var errorMessage: String?
  @State private var isClearing = false

  init(
    cacheManager: TranslationCacheManagement = TranslationCacheManagement(),
    defaults: UserDefaults = .standard
  ) {
    self.cacheManager = cacheManager
    self.defaults = defaults
    _selectedLimit = State(initialValue: Self.loadLimit(from: defaults))
  }

  var body: some View {
    Section {
      Text(L10n.string("ios.cacheUsed", formattedBytes(usageBytes)))
        .foregroundStyle(.secondary)

      Picker(L10n.string("ios.cacheSizeLimit"), selection: $selectedLimit) {
        ForEach(Self.limits, id: \.self) { limit in
          Text(formattedBytes(limit)).tag(limit)
        }
        Text(L10n.string("ios.cacheUnlimited")).tag(Int64(0))
      }
      .onChange(of: selectedLimit) { _, value in
        saveLimit(value)
      }

      Button(role: .destructive) {
        clearCache()
      } label: {
        if isClearing {
          ProgressView()
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Label(
            L10n.string("ios.clearTranslationCache"),
            systemImage: "trash"
          )
        }
      }
      .disabled(isClearing)
      .accessibilityIdentifier("settings.clearTranslationCache")

      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text(L10n.string("ios.translationCache"))
    }
    .onAppear(perform: reload)
    .onReceive(NotificationCenter.default.publisher(for: .translationCacheDidClear)) { _ in
      reload()
    }
  }

  private func reload() {
    let manager = cacheManager
    Task { @MainActor in
      let usage = await Task.detached(priority: .utility) {
        manager.usageBytes()
      }.value
      usageBytes = usage
      errorMessage = nil
    }
  }

  private func saveLimit(_ value: Int64) {
    defaults.set(Int(value), forKey: Self.limitKey)
    guard value > 0 else { return }
    let manager = cacheManager
    Task { @MainActor in
      do {
        let usage = try await Task.detached(priority: .utility) {
          _ = try manager.trim(toBytes: value)
          return manager.usageBytes()
        }.value
        guard selectedLimit == value else { return }
        usageBytes = usage
      } catch {
        guard selectedLimit == value else { return }
        errorMessage = L10n.string("ios.cacheClearFailed", error.localizedDescription)
      }
    }
  }

  private func clearCache() {
    guard !isClearing else { return }
    isClearing = true
    let manager = cacheManager
    Task { @MainActor in
      defer { isClearing = false }
      do {
        let usage = try await Task.detached(priority: .utility) {
          try manager.clear()
          return manager.usageBytes()
        }.value
        usageBytes = usage
        errorMessage = nil
        NotificationCenter.default.post(name: .translationCacheDidClear, object: nil)
      } catch {
        errorMessage = L10n.string("ios.cacheClearFailed", error.localizedDescription)
      }
    }
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
  }

  private static func loadLimit(from defaults: UserDefaults) -> Int64 {
    guard defaults.object(forKey: limitKey) != nil else { return defaultLimit }
    let value = defaults.integer(forKey: limitKey)
    return value > 0 ? Int64(value) : 0
  }
}
