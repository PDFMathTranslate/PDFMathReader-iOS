import CryptoKit
import Foundation

public enum DocumentIdentity {
  /// Content hashing keeps a document's reading state stable across renames and moves.
  public static func contentHash(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func contentHash(for url: URL) throws -> String {
    contentHash(for: try Data(contentsOf: url, options: [.mappedIfSafe]))
  }
}
