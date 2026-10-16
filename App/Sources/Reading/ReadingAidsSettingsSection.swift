import ReaderCore
import SwiftUI

public struct ReadingAidsSettingsSection: View {
  @Binding public var preferences: ReaderPreferences

  public init(preferences: Binding<ReaderPreferences>) {
    _preferences = preferences
  }

  public var body: some View {
    Section(L10n.string("ios.readingAids")) {
      Picker(L10n.string("settings.bionicReading"), selection: $preferences.bionicReading) {
        Text(L10n.string("settings.bionicReadingOff")).tag(BionicReadingMode.off)
        Text(L10n.string("settings.bionicReadingFixed")).tag(BionicReadingMode.fixed)
        Text(L10n.string("settings.bionicReadingRoot")).tag(BionicReadingMode.root)
      }

      if preferences.bionicReading != .off {
        Stepper(
          L10n.string("ios.fixedPrefixCount", String(preferences.bionicFixedLength)),
          value: $preferences.bionicFixedLength,
          in: BionicReading.fixedLengthMinimum...BionicReading.fixedLengthMaximum
        )
        Toggle(L10n.string("settings.bionicOriginalOnly"), isOn: $preferences.bionicOriginalOnly)
      }

      Toggle(L10n.string("settings.emphasizeInformation"), isOn: $preferences.emphasizeInformation)
      Toggle(L10n.string("settings.emphasizeResearchFindings"), isOn: $preferences.emphasizeResearchFindings)
        .disabled(!preferences.emphasizeInformation)
      Toggle(L10n.string("settings.emphasizeOrdinals"), isOn: $preferences.emphasizeOrdinals)
        .disabled(!preferences.emphasizeInformation)
      Toggle(L10n.string("settings.emphasizeKeyVerbs"), isOn: $preferences.emphasizeKeyVerbs)
        .disabled(!preferences.emphasizeInformation)
      Toggle(L10n.string("settings.emphasizeLogicalConnectives"), isOn: $preferences.emphasizeLogicalConnectives)
        .disabled(!preferences.emphasizeInformation)
      Toggle(L10n.string("ios.tfidfEmphasis"), isOn: $preferences.tfidfWeightingEnabled)
      Toggle(L10n.string("settings.emphasizeTopicSentences"), isOn: $preferences.emphasizeTopicSentences)
      Toggle(L10n.string("settings.optimizeParagraphGaps"), isOn: $preferences.paragraphGapOptimization)
      Toggle(L10n.string("ios.detectedLinks"), isOn: $preferences.readingLinksEnabled)
      Toggle(L10n.string("ios.generatedOutlineFallback"), isOn: $preferences.tocGenerationEnabled)
    }
  }
}
