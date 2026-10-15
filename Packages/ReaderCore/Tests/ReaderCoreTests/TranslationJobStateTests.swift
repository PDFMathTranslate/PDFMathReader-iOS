import Testing

@testable import ReaderCore

@Test
func translationJobStateCalculatesResumablePagesAndProgress() {
  var state = TranslationJobState(
    documentID: "document",
    configurationID: "english-to-french",
    totalPages: 5,
    completedPageIndices: [4, 1, 1, -1, 9]
  )

  #expect(state.completedPageIndices == [1, 4])
  #expect(state.resumablePageIndices == [0, 2, 3])
  #expect(state.progress == TranslationJobProgress(totalPages: 5, completedPages: 2))

  state.markFailed(pageIndex: 2, error: "network")
  #expect(state.resumablePageIndices == [0, 2, 3])
  #expect(state.progress == TranslationJobProgress(totalPages: 5, completedPages: 2, failedPages: 1))

  state.markCompleted(pageIndex: 2)
  #expect(state.completedPageIndices == [1, 2, 4])
  #expect(state.failedPages.isEmpty)
  #expect(state.progress == TranslationJobProgress(totalPages: 5, completedPages: 3))
}

@Test
func translationJobStateTreatsCachedPagesAsCompletedAndRetriesFailures() {
  var state = TranslationJobState(
    documentID: "document",
    configurationID: "configuration",
    totalPages: 3,
    status: .cancelled,
    completedPageIndices: [0]
  )

  state.mergeCachedPages([0, 2, 8])
  state.beginRun()

  #expect(state.status == .running)
  #expect(state.completedPageIndices == [0, 2])
  #expect(state.resumablePageIndices == [1])
  #expect(state.progress.fraction == 2.0 / 3.0)
}

@Test
func translationJobStateMarksPartialFailuresAsFailed() {
  var state = TranslationJobState(
    documentID: "document",
    configurationID: "configuration",
    totalPages: 2
  )
  state.beginRun()
  state.markCompleted(pageIndex: 0)
  state.markFailed(pageIndex: 1, error: "provider")
  state.markFinished()

  #expect(state.status == .failed)
  #expect(state.progress.processedPages == 2)
  #expect(state.resumablePageIndices == [1])

  state.beginRun()
  #expect(state.failedPages.isEmpty)
  #expect(state.progress.processedPages == 1)
}
