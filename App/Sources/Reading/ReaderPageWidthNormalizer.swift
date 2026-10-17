import Foundation
import JavaScriptCore

/// Scales the pages of a PDF so that their displayed crop widths line up.
///
/// The geometry and box handling intentionally mirror the desktop page edit
/// implementation. PDFKit is not used for the rewrite because it can flatten
/// or discard PDF objects that pdf-lib can preserve.
public enum ReaderPageWidthNormalizer {
  public struct Result: Sendable {
    public let data: Data
    public let scales: [Double]

    public init(data: Data, scales: [Double]) {
      self.data = data
      self.scales = scales
    }
  }

  private enum Failure: Error, LocalizedError {
    case resourceMissing
    case javascript(String)
    case invalidResult

    var errorDescription: String? {
      switch self {
      case .resourceMissing:
        return "The PDF width normalizer JavaScript resource is unavailable."
      case let .javascript(message):
        return "PDF width normalization failed: \(message)"
      case .invalidResult:
        return "PDF width normalization returned an invalid result."
      }
    }
  }

  private final class ResourceBundleToken: NSObject {}

  private static let queue = DispatchQueue(
    label: "com.pdfmathtranslate.PDFMathReader.reader-page-width-normalizer"
  )

  /// Normalizes displayed page widths, preserving the PDF's native objects.
  ///
  /// A document whose displayed page widths all have the same desktop bucket
  /// is already normalized and returns `nil` without rewriting its bytes.
  public static func normalize(data: Data) async throws -> Result? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result?, Error>) in
      queue.async {
        do {
          continuation.resume(returning: try normalizeSynchronously(data: data))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

private extension ReaderPageWidthNormalizer {
  static func normalizeSynchronously(data: Data) throws -> Result? {
    guard let libraryURL = resourceBundle.url(
      forResource: "pdf-lib.min",
      withExtension: "js",
      subdirectory: "PDFWidthAlignment"
    ) ?? resourceBundle.url(forResource: "pdf-lib.min", withExtension: "js") else {
      throw Failure.resourceMissing
    }

    let library = try String(contentsOf: libraryURL, encoding: .utf8)
    let context = JSContext()!
    var exceptionMessage: String?
    context.exceptionHandler = { _, exception in
      exceptionMessage = exception?.toString()
    }

    // pdf-lib's UMD wrapper uses `self` as a fallback global. Defining it
    // explicitly keeps the same bundle usable in JavaScriptCore. Its small
    // `waitForTick` helper also expects browser timers, which JavaScriptCore
    // does not provide by default.
    context.evaluateScript("""
      var self = this;
      if (typeof setTimeout !== "function") {
        this.setTimeout = function (callback) {
          var args = Array.prototype.slice.call(arguments, 1);
          callback.apply(this, args);
          return 0;
        };
        this.clearTimeout = function () {};
      }
      """)
    guard exceptionMessage == nil else {
      throw Failure.javascript(exceptionMessage ?? "Unable to initialize JavaScriptCore.")
    }
    context.evaluateScript(library)
    guard exceptionMessage == nil else {
      throw Failure.javascript(exceptionMessage ?? "Unable to load pdf-lib.")
    }
    context.evaluateScript(helperScript)
    guard exceptionMessage == nil,
      let normalize = context.objectForKeyedSubscript("__readerPageWidthNormalize")
    else {
      throw Failure.javascript(exceptionMessage ?? "Unable to initialize the width normalizer.")
    }

    let input = JSValue(object: data.base64EncodedString(), in: context)!
    var callbackCalled = false
    var callbackError: String?
    var callbackResult: JSValue?
    let callback: @convention(block) (JSValue?, JSValue?) -> Void = { error, result in
      callbackCalled = true
      if let error, !error.isNull, !error.isUndefined {
        callbackError = error.toString() ?? "Unknown JavaScript error."
      } else {
        callbackResult = result
      }
    }

    context.exception = nil
    normalize.call(withArguments: [
      input,
      JSValue(object: callback, in: context)!,
    ])
    if let exception = context.exception ?? (exceptionMessage.map { JSValue(object: $0, in: context)! }) {
      throw Failure.javascript(exception.toString() ?? "Unknown JavaScript exception.")
    }
    guard callbackCalled else {
      throw Failure.javascript("The JavaScript promise did not settle synchronously.")
    }
    if let callbackError {
      throw Failure.javascript(callbackError)
    }
    guard let callbackResult,
      !callbackResult.isNull,
      !callbackResult.isUndefined
    else {
      return nil
    }

    guard let outputString = callbackResult.forProperty("data")?.toString(),
      let output = Data(base64Encoded: outputString),
      !output.isEmpty
    else {
      throw Failure.invalidResult
    }

    guard let scaleValues = callbackResult.forProperty("scales")?.toArray() else {
      throw Failure.invalidResult
    }
    let scales = scaleValues.compactMap { value -> Double? in
      guard let number = value as? NSNumber else { return nil }
      let scale = number.doubleValue
      return scale.isFinite ? scale : nil
    }
    guard scales.count == scaleValues.count else {
      throw Failure.invalidResult
    }
    return Result(data: output, scales: scales)
  }

  static var resourceBundle: Bundle {
    Bundle(for: ResourceBundleToken.self)
  }

  static let helperScript = #"""
    (function (global) {
      "use strict";

      var PDFLib = global.PDFLib;
      if (!PDFLib || !PDFLib.PDFDocument) {
        throw new Error("pdf-lib is unavailable.");
      }

      var BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

      function decodeBase64(value) {
        var padding = value.slice(-2) === "==" ? 2 : value.slice(-1) === "=" ? 1 : 0;
        var output = new Uint8Array((value.length * 3 >> 2) - padding);
        var buffer = 0;
        var bits = 0;
        var index = 0;
        for (var offset = 0; offset < value.length; offset += 1) {
          var character = value.charAt(offset);
          if (character === "=") break;
          var digit = BASE64.indexOf(character);
          if (digit < 0) throw new Error("Invalid base64 input.");
          buffer = (buffer << 6) | digit;
          bits += 6;
          if (bits >= 8) {
            bits -= 8;
            output[index] = (buffer >> bits) & 255;
            index += 1;
          }
        }
        return output;
      }

      function encodeBase64(bytes) {
        var output = "";
        for (var offset = 0; offset < bytes.length; offset += 3) {
          var first = bytes[offset];
          var second = offset + 1 < bytes.length ? bytes[offset + 1] : 0;
          var third = offset + 2 < bytes.length ? bytes[offset + 2] : 0;
          output += BASE64.charAt(first >> 2);
          output += BASE64.charAt(((first & 3) << 4) | (second >> 4));
          output += offset + 1 < bytes.length ? BASE64.charAt(((second & 15) << 2) | (third >> 6)) : "=";
          output += offset + 2 < bytes.length ? BASE64.charAt(third & 63) : "=";
        }
        return output;
      }

      var BOXES = [
        ["MediaBox", "getMediaBox", "setMediaBox"],
        ["CropBox", "getCropBox", "setCropBox"],
        ["BleedBox", "getBleedBox", "setBleedBox"],
        ["TrimBox", "getTrimBox", "setTrimBox"],
        ["ArtBox", "getArtBox", "setArtBox"]
      ];

      function normalizedRotation(page) {
        var angle = Number(page.getRotation() && page.getRotation().angle) || 0;
        return ((angle % 360) + 360) % 360;
      }

      function displayedGeometry(page) {
        var crop = page.getCropBox();
        var rotation = normalizedRotation(page);
        var sideways = rotation === 90 || rotation === 270;
        return {
          width: sideways ? crop.height : crop.width,
          height: sideways ? crop.width : crop.height,
          rotation: rotation
        };
      }

      function bucket(value) {
        return Number((Math.round((value + Number.EPSILON) * 10) / 10).toFixed(1));
      }

      function hasExplicitBox(page, name) {
        return page.node[name] && page.node[name]() !== undefined;
      }

      function scalePage(page, scale) {
        if (Math.abs(scale - 1) <= 1e-12) return;
        var boxes = BOXES.map(function (box) {
          var name = box[0];
          var getter = box[1];
          return {
            name: name,
            setter: box[2],
            value: page[getter](),
            explicit: name === "MediaBox" || hasExplicitBox(page, name)
          };
        });
        page.scale(scale, scale);
        boxes.forEach(function (box) {
          if (!box.explicit) return;
          var value = box.value;
          page[box.setter](
            value.x * scale,
            value.y * scale,
            value.width * scale,
            value.height * scale
          );
        });
      }

      function selectModal(records, key) {
        var counts = new Map();
        records.forEach(function (record) {
          var value = bucket(record[key]);
          record.bucket = value;
          counts.set(value, (counts.get(value) || 0) + 1);
        });
        var selected = records.length ? records[0].bucket : undefined;
        var bestCount = selected === undefined ? 0 : counts.get(selected);
        records.forEach(function (record) {
          var count = counts.get(record.bucket);
          if (count > bestCount) {
            selected = record.bucket;
            bestCount = count;
          }
        });
        for (var index = 0; index < records.length; index += 1) {
          if (records[index].bucket === selected) return records[index][key];
        }
        return undefined;
      }

      global.__readerPageWidthNormalize = function (input, callback) {
        Promise.resolve().then(async function () {
          var pdf = await PDFLib.PDFDocument.load(decodeBase64(input), {
            updateMetadata: false
          });
          var pages = pdf.getPages();
          var before = pages.map(displayedGeometry);
          var buckets = new Set(before.map(function (geometry) {
            return bucket(geometry.width);
          }));
          if (!before.length || buckets.size <= 1) {
            callback(null, null);
            return;
          }

          var target = selectModal(before.map(function (geometry) {
            return {
              width: geometry.width,
              height: geometry.height
            };
          }), "width");
          var scales = before.map(function (geometry, index) {
            var scale = target / geometry.width;
            scalePage(pages[index], scale);
            return scale;
          });
          var output = new Uint8Array(await pdf.save());
          callback(null, {
            data: encodeBase64(output),
            scales: scales
          });
        }).catch(function (error) {
          callback(error, null);
        });
      };
    })(this);
    """#
}
