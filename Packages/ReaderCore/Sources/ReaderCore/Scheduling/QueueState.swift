import Foundation

/// Mutable scheduling flags that the reader can persist or expose to its UI.
/// Work items and cancellation handles stay inside TranslationQueue's actor.
public struct TranslationQueueState: Sendable, Equatable {
  public var translationDeferred: Bool
  public var readingDirection: Int
  public var translationMoving: Bool
  public var lastTranslationScroll: Int?
  public var forceRetranslation: Bool
  public var translateAllPages: Bool

  public init(
    translationDeferred: Bool = false,
    readingDirection: Int = 1,
    translationMoving: Bool = false,
    lastTranslationScroll: Int? = nil,
    forceRetranslation: Bool = false,
    translateAllPages: Bool = false
  ) {
    self.translationDeferred = translationDeferred
    self.readingDirection = readingDirection == -1 ? -1 : 1
    self.translationMoving = translationMoving
    self.lastTranslationScroll = lastTranslationScroll
    self.forceRetranslation = forceRetranslation
    self.translateAllPages = translateAllPages
  }
}
