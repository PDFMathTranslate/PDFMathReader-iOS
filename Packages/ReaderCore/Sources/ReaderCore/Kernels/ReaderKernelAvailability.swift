/// Computes the translation engines that can currently be offered by the
/// reader from already-collected kernel health state.
///
/// The policy is deliberately synchronous and side-effect free. Callers are
/// responsible for refreshing the health values before asking for the menu.
public enum ReaderKernelAvailability {
  /// Returns the engines that have a usable implementation at this moment.
  ///
  /// Ultra fast is always available on the device. Fast requires an
  /// authenticated, healthy companion with the Fast kernel installed. Precise
  /// can use either an authenticated, healthy companion or an enabled remote
  /// server whose health check passed.
  public static func availableEngines(
    companion: CompanionHealth?,
    remote: RemoteKernelHealth?,
    remoteEnabled: Bool
  ) -> [ReaderEngine] {
    var engines: [ReaderEngine] = [.ultraFast]

    if companion?.isAvailable(CompanionKernel.fast) == true {
      engines.append(.fast)
    }

    let companionProvidesPrecise = companion?.isAvailable(CompanionKernel.precise) == true
    let remoteProvidesPrecise = remoteEnabled && remote?.ok == true
    if companionProvidesPrecise || remoteProvidesPrecise {
      engines.append(.precise)
    }

    return engines
  }
}
