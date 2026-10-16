import Testing

@testable import ReaderCore

struct ReaderKernelAvailabilityTests {
  @Test
  func unreachableKernelsOnlyOfferUltraFast() {
    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: nil,
        remote: nil,
        remoteEnabled: false
      ) == [.ultraFast]
    )
  }

  @Test
  func wrongPairingDoesNotExposeCompanionKernels() {
    let health = CompanionHealth(
      ok: false,
      reason: "Wrong pairing code",
      kernels: [
        CompanionKernelStatus(id: CompanionKernel.fast, available: true),
        CompanionKernelStatus(id: CompanionKernel.precise, available: true),
      ]
    )

    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: health,
        remote: nil,
        remoteEnabled: false
      ) == [.ultraFast]
    )
  }

  @Test
  func partialCompanionHealthExposesOnlyInstalledKernels() {
    let fastOnly = CompanionHealth(
      ok: true,
      kernels: [
        CompanionKernelStatus(id: CompanionKernel.fast, available: true),
        CompanionKernelStatus(id: CompanionKernel.precise, available: false),
      ]
    )
    let preciseOnly = CompanionHealth(
      ok: true,
      kernels: [
        CompanionKernelStatus(id: CompanionKernel.fast, available: false),
        CompanionKernelStatus(id: CompanionKernel.precise, available: true),
      ]
    )

    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: fastOnly,
        remote: nil,
        remoteEnabled: false
      ) == [.ultraFast, .fast]
    )
    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: preciseOnly,
        remote: nil,
        remoteEnabled: false
      ) == [.ultraFast, .precise]
    )
  }

  @Test
  func remotePreciseRequiresBothEnablementAndHealthyResponse() {
    let healthy = RemoteKernelHealth(ok: true, version: "1")
    let unreachable = RemoteKernelHealth(ok: false, reason: "Connection refused")

    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: nil,
        remote: healthy,
        remoteEnabled: true
      ) == [.ultraFast, .precise]
    )
    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: nil,
        remote: healthy,
        remoteEnabled: false
      ) == [.ultraFast]
    )
    #expect(
      ReaderKernelAvailability.availableEngines(
        companion: nil,
        remote: unreachable,
        remoteEnabled: true
      ) == [.ultraFast]
    )
  }
}
