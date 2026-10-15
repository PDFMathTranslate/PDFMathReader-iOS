import Testing

@testable import ReaderCore

private actor SchedulingEventLog {
  private(set) var events: [String] = []

  func append(_ event: String) {
    events.append(event)
  }
}

@Test
func schedulesWorkAfterTheCommitBoundary() async {
  let log = SchedulingEventLog()
  let value = await scheduleAfterPaint(
    afterCommit: { await log.append("commit") },
    task: {
      await log.append("task")
      return 7
    }
  )

  let events = await log.events
  #expect(value == 7)
  #expect(events == ["commit", "task"])
}

@Test
func schedulesCleanupAfterACooperativeYield() async {
  let log = SchedulingEventLog()
  await scheduleTaskCleanup {
    await log.append("cleanup")
  }
  let events = await log.events
  #expect(events == ["cleanup"])
}
