import SwiftUI
import UIKit

private enum AppIconStyle: String, CaseIterable, Identifiable {
  case base, warm, spring, hist, tech, moon, modern

  var id: String { rawValue }
  var previewName: String { "AppIconPreview-\(rawValue)" }

  var alternateIconName: String? {
    switch self {
    case .base: nil
    case .warm: "AppIconWarm"
    case .spring: "AppIconSpring"
    case .hist: "AppIconClassic"
    case .tech: "AppIconBlueprint"
    case .moon: "AppIconMoon"
    case .modern: "AppIconModern"
    }
  }

  var displayName: String {
    let key = switch self {
    case .base: "appearance.iconDefault"
    case .warm: "appearance.iconWarm"
    case .spring: "appearance.iconSpring"
    case .hist: "appearance.iconClassic"
    case .tech: "appearance.iconBlueprint"
    case .moon: "appearance.iconMoon"
    case .modern: "appearance.iconModern"
    }
    return L10n.string(key)
  }

  @MainActor static var current: AppIconStyle {
    allCases.first { $0.alternateIconName == UIApplication.shared.alternateIconName } ?? .base
  }
}

struct AppIconSettingsRow: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var selection = AppIconStyle.current

  var body: some View {
    if UIApplication.shared.supportsAlternateIcons {
      NavigationLink {
        AppIconPicker(selection: $selection)
      } label: {
        HStack {
          Text(L10n.string("appearance.appIcon"))
          Spacer()
          Image(selection.previewName)
            .resizable()
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
          Text(selection.displayName)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityIdentifier("settings.appIcon")
      .onAppear { selection = .current }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { selection = .current }
      }
    }
  }
}

private struct AppIconPicker: View {
  @Binding var selection: AppIconStyle
  @Environment(\.scenePhase) private var scenePhase
  @State private var pendingStyle: AppIconStyle?
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 24) {
        ForEach(AppIconStyle.allCases) { style in
          Button {
            changeIcon(to: style)
          } label: {
            VStack(spacing: 10) {
              Image(style.previewName)
                .resizable()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .padding(6)
                .overlay {
                  RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .stroke(selection == style ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay {
                  if pendingStyle == style {
                    ProgressView()
                      .padding(8)
                      .background(.regularMaterial, in: Circle())
                  }
                }
              Text(style.displayName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(pendingStyle != nil)
          .accessibilityLabel(style.displayName)
          .accessibilityAddTraits(selection == style ? .isSelected : [])
          .accessibilityIdentifier("settings.appIcon.\(style.rawValue)")
        }
      }
      .padding(24)
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle(L10n.string("appearance.appIcon"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { selection = .current }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { selection = .current }
    }
    .alert(L10n.string("appearance.appIcon"), isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button(L10n.string("ios.ok"), role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func changeIcon(to style: AppIconStyle) {
    guard pendingStyle == nil, style != .current else { return }
    pendingStyle = style
    Task { @MainActor in
      defer {
        selection = .current
        pendingStyle = nil
      }
      do {
        try await UIApplication.shared.setAlternateIconName(style.alternateIconName)
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}
