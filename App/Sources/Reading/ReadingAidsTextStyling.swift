import ReaderCore
import UIKit

extension ReadingAidsConfiguration {
  var emphasisColor: UIColor {
    accentColor == "system" ? .systemBlue : UIColor(hex: accentColor)
  }
}

@MainActor
func readingAidsAttributedString(
  text: String,
  font: UIFont,
  configuration: ReadingAidsConfiguration,
  isOriginal: Bool
) -> NSAttributedString {
  let result = NSMutableAttributedString(string: text, attributes: [.font: font])
  let length = text.utf16.count
  guard length > 0 else { return result }

  if configuration.emphasizeTopicSentences {
    let end = min(length, max(0, topicSentenceLength(text)))
    addAttribute(
      .backgroundColor,
      value: configuration.emphasisColor.withAlphaComponent(0.14),
      range: NSRange(location: 0, length: end),
      to: result,
      length: length
    )
  }

  if configuration.emphasizeInformation {
    for match in importantInformationRanges(
      text,
      categories: configuration.informationCategories
    ) {
      addAttribute(
        .underlineStyle,
        value: NSUnderlineStyle.single.rawValue,
        range: NSRange(location: match.start, length: match.end - match.start),
        to: result,
        length: length
      )
      addAttribute(
        .underlineColor,
        value: configuration.emphasisColor.withAlphaComponent(0.9),
        range: NSRange(location: match.start, length: match.end - match.start),
        to: result,
        length: length
      )
    }
  }

  let shouldApplyBionic = isOriginal || !configuration.bionicOriginalOnly
  if shouldApplyBionic {
    let descriptor = font.fontDescriptor.withSymbolicTraits(
      font.fontDescriptor.symbolicTraits.union(.traitBold)
    )
    let boldFont = descriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
    for match in BionicReading.ranges(in: text, options: configuration.bionicOptions) {
      addAttribute(
        .font,
        value: boldFont,
        range: NSRange(location: match.start, length: match.end - match.start),
        to: result,
        length: length
      )
    }
  }

  return result
}

private func addAttribute(
  _ key: NSAttributedString.Key,
  value: Any,
  range: NSRange,
  to string: NSMutableAttributedString,
  length: Int
) {
  let lower = max(0, range.location)
  let upper = min(length, range.location + range.length)
  guard upper > lower else { return }
  string.addAttribute(key, value: value, range: NSRange(location: lower, length: upper - lower))
}
