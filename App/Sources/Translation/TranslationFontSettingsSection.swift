import ReaderCore
import SwiftUI
import UIKit

/// Settings for the font used by translated text overlays.
public struct TranslationFontSettingsSection: View {
  @Binding public var preferences: ReaderPreferences

  public init(preferences: Binding<ReaderPreferences>) {
    _preferences = preferences
  }

  public var body: some View {
    Section {
      Toggle(
        L10n.string("ios.translationFontSerif"),
        isOn: $preferences.translationSerif
      )
      .accessibilityIdentifier("settings.translationSerif")

      NavigationLink {
        TranslationFontPicker(
          selection: $preferences.translationFont,
          language: preferences.targetLanguage
        )
      } label: {
        HStack {
          Text(L10n.string("ios.translationFontFamily"))
          Spacer()
          Text(selectedFontLabel)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .accessibilityIdentifier("settings.translationFont")

      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.string("ios.translationFontPreview"))
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(L10n.string("ios.translationFontPreviewText"))
          .font(Font(
            ReaderTranslationFont.resolve(
              name: preferences.translationFont,
              serif: preferences.translationSerif,
              size: 20,
              language: preferences.targetLanguage
            )
          ))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
          .accessibilityLabel(L10n.string("ios.translationFontPreview"))
      }
    } header: {
      Text(L10n.string("ios.translationFont"))
    } footer: {
      Text(L10n.string("ios.translationFontFooter"))
    }
  }

  private var selectedFontLabel: String {
    let family = preferences.translationFont.trimmingCharacters(in: .whitespacesAndNewlines)
    return family.isEmpty ? L10n.string("ios.translationFontDefault") : family
  }
}

private struct TranslationFontPicker: View {
  @Binding var selection: String
  let language: String
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private let fontFamilies: [String] = UIFont.familyNames.sorted {
    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
  }

  private var filteredFontFamilies: [String] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return fontFamilies }
    return fontFamilies.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    List {
      fontRow(name: "", label: L10n.string("ios.translationFontDefault"))

      ForEach(filteredFontFamilies, id: \.self) { family in
        fontRow(name: family, label: family)
      }
    }
    .navigationTitle(L10n.string("ios.translationFontFamily"))
    .searchable(
      text: $searchText,
      placement: .navigationBarDrawer(displayMode: .always),
      prompt: L10n.string("ios.translationFontSearch")
    )
  }

  private func fontRow(name: String, label: String) -> some View {
    Button {
      selection = name
      dismiss()
    } label: {
      HStack(spacing: 12) {
        Text(label)
          .font(Font(ReaderTranslationFont.resolve(
            name: name, serif: false, size: 17, language: language
          )))
          .foregroundStyle(.primary)
        Spacer(minLength: 8)
        if selection == name {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
