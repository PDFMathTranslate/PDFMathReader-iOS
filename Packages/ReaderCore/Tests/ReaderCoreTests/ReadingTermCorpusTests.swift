import Foundation
import Testing

@testable import ReaderCore

@Test
func termCorpusMatchesDesktopFixture() throws {
  let fixture = try ReadingFixtureSupport.fixture()["termCorpus"] as! [String: Any]
  var clock: Int64 = 0
  let corpus = TermCorpus(
    maxDocuments: 2,
    maxTerms: 3,
    random: { 0 },
    now: { clock += 1; return clock }
  )
  let idA = String(repeating: "a", count: 32)
  let idB = String(repeating: "b", count: 32)
  let idC = String(repeating: "c", count: 32)
  let addA = try corpus.add(idA, terms: ["rareword", "common", "common", "中文"])
  let addB = try corpus.add(idB, terms: ["common", "other", "词语"])
  let touchA = try corpus.touch(idA)
  let addC = try corpus.add(idC, terms: ["other", "new", "rareword"])
  let frequencies = try corpus.frequencies(excluding: idA, terms: ["common", "other", "rareword", "中文"])
  let touchEvicted = try corpus.touch(idB)
  let actual: [String: Any] = [
    "addA": ["documents": addA.documents, "terms": addA.terms],
    "addB": ["documents": addB.documents, "terms": addB.terms],
    "touchA": ["known": touchA],
    "addC": ["documents": addC.documents, "terms": addC.terms],
    "frequencies": ["documents": frequencies.documents, "frequencies": frequencies.frequencies],
    "touchEvicted": ["known": touchEvicted],
    "documents": corpus.documentCount(),
  ]
  #expect(try ReadingFixtureSupport.jsonEqual(actual, fixture))
}

@Test
func termCorpusRejectsInvalidDocumentIDs() {
  #expect(TermCorpus.isDocumentID(String(repeating: "a", count: 32)))
  #expect(!TermCorpus.isDocumentID("not-a-document-id"))
}
