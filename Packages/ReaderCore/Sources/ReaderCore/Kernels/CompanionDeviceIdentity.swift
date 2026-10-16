import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum CompanionDeviceIdentity {
  @MainActor
  static var name: String {
    #if canImport(UIKit)
    UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    #else
    "Mac"
    #endif
  }

  static func identify(_ request: URLRequest) async -> URLRequest {
    var request = request
    request.setValue(await name, forHTTPHeaderField: "X-PDFMathReader-Device-Name")
    return request
  }
}
