import ReaderCore
import SwiftUI

public struct ReadingAidsSettingsSection: View {
  @Binding public var preferences: ReaderPreferences

  public init(preferences: Binding<ReaderPreferences>) {
    _preferences = preferences
  }

  public var body: some View {
    Section("Reading aids") {
      Picker("Bionic reading", selection: $preferences.bionicReading) {
        Text("Off").tag(BionicReadingMode.off)
        Text("Fixed prefix").tag(BionicReadingMode.fixed)
        Text("Word root").tag(BionicReadingMode.root)
      }

      if preferences.bionicReading != .off {
        Stepper(
          "Fixed prefix: \(preferences.bionicFixedLength)",
          value: $preferences.bionicFixedLength,
          in: BionicReading.fixedLengthMinimum...BionicReading.fixedLengthMaximum
        )
        Toggle("Original text only", isOn: $preferences.bionicOriginalOnly)
      }

      Toggle("Information emphasis", isOn: $preferences.emphasizeInformation)
      Toggle("Research findings", isOn: $preferences.emphasizeResearchFindings)
        .disabled(!preferences.emphasizeInformation)
      Toggle("Ordinals", isOn: $preferences.emphasizeOrdinals)
        .disabled(!preferences.emphasizeInformation)
      Toggle("Key verbs", isOn: $preferences.emphasizeKeyVerbs)
        .disabled(!preferences.emphasizeInformation)
      Toggle("Logical connectives", isOn: $preferences.emphasizeLogicalConnectives)
        .disabled(!preferences.emphasizeInformation)
      Toggle("TF-IDF emphasis", isOn: $preferences.tfidfWeightingEnabled)
      Toggle("Topic-sentence highlighting", isOn: $preferences.emphasizeTopicSentences)
      Toggle("Detected links", isOn: $preferences.readingLinksEnabled)
      Toggle("Generated outline fallback", isOn: $preferences.tocGenerationEnabled)
    }
  }
}
