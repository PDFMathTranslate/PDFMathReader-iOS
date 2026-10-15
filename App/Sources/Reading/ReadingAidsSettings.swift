import Foundation
import ReaderCore

/// The presentation settings shared by original-page and translation overlays.
public struct ReadingAidsConfiguration: Equatable, Sendable {
  public var bionicOptions: BionicReadingOptions
  public var bionicOriginalOnly: Bool
  public var emphasizeInformation: Bool
  public var informationCategories: [String: Bool]
  public var emphasizeTopicSentences: Bool
  public var tfidfWeightingEnabled: Bool
  public var readingLinksEnabled: Bool

  public init(
    bionicOptions: BionicReadingOptions = BionicReadingOptions(),
    bionicOriginalOnly: Bool = true,
    emphasizeInformation: Bool = false,
    informationCategories: [String: Bool] = [
      "research": true,
      "ordinals": true,
      "verbs": true,
      "logic": true,
    ],
    emphasizeTopicSentences: Bool = false,
    tfidfWeightingEnabled: Bool = false,
    readingLinksEnabled: Bool = true
  ) {
    self.bionicOptions = BionicReading.normalize(bionicOptions)
    self.bionicOriginalOnly = bionicOriginalOnly
    self.emphasizeInformation = emphasizeInformation
    self.informationCategories = informationCategories
    self.emphasizeTopicSentences = emphasizeTopicSentences
    self.tfidfWeightingEnabled = tfidfWeightingEnabled
    self.readingLinksEnabled = readingLinksEnabled
  }

  public init(preferences: ReaderPreferences) {
    self.init(
      bionicOptions: BionicReadingOptions(
        mode: preferences.bionicReading,
        fixedLength: preferences.bionicFixedLength
      ),
      bionicOriginalOnly: preferences.bionicOriginalOnly,
      emphasizeInformation: preferences.emphasizeInformation,
      informationCategories: [
        "research": preferences.emphasizeResearchFindings,
        "ordinals": preferences.emphasizeOrdinals,
        "verbs": preferences.emphasizeKeyVerbs,
        "logic": preferences.emphasizeLogicalConnectives,
      ],
      emphasizeTopicSentences: preferences.emphasizeTopicSentences,
      tfidfWeightingEnabled: preferences.tfidfWeightingEnabled,
      readingLinksEnabled: preferences.readingLinksEnabled
    )
  }

  public var hasOriginalOverlay: Bool {
    BionicReading.active(bionicOptions) ||
      emphasizeInformation ||
      emphasizeTopicSentences ||
      tfidfWeightingEnabled ||
      readingLinksEnabled
  }

  public var hasTranslationStyling: Bool {
    (!bionicOriginalOnly && BionicReading.active(bionicOptions)) ||
      emphasizeInformation ||
      emphasizeTopicSentences
  }
}
