import CoreFoundation
import Foundation
import ReaderCore

/// Small property-list payload shared with the macOS NSUserActivity receiver.
/// PDFs and credentials travel through the already paired companion service.
struct ReaderHandoffActivity: Equatable, Sendable {
  static let activityType = "org.pdfmathreader.reading"
  let documentID: String
  let page: Int
  let serverURL: String?

  init(documentID: String, page: Int, serverURL: String? = nil) {
    self.documentID = documentID
    self.page = page
    self.serverURL = serverURL
  }

  init?(userInfo: [AnyHashable: Any]?) {
    guard let userInfo,
          let version = userInfo["version"] as? NSNumber,
          CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
          let documentID = userInfo["documentID"] as? String,
          !documentID.isEmpty, documentID.utf8.count <= 128,
          documentID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }),
          let number = userInfo["page"] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
          (1...1_000_000).contains(number.doubleValue)
    else { return nil }
    self.documentID = documentID
    page = number.intValue
    serverURL = userInfo["serverURL"] as? String
  }

  var userInfo: [AnyHashable: Any] {
    var result: [AnyHashable: Any] = ["version": 1, "documentID": documentID, "page": page]
    if let serverURL { result["serverURL"] = serverURL }
    return result
  }
}
