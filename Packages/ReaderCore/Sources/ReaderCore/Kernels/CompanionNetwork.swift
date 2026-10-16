import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let tailscaleIPv4Start: UInt32 = 0x6440_0000 // 100.64.0.0
private let tailscaleIPv4End: UInt32 = 0x647F_FFFF // 100.127.255.255
private let quad100IPv4: UInt32 = 0x6464_6464 // 100.100.100.100
private let tailscaleIPv6Prefix: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]

/// Returns whether `host` is a literal address in Tailscale's CGNAT or ULA
/// ranges. DNS names are intentionally excluded; callers that accept a
/// remembered MagicDNS URL should use ``tailscaleCompanionURL(_:)``.
public func isTailscaleHost(_ host: String) -> Bool {
  let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { return false }

  let literal: String
  if value.first == "[" {
    guard value.last == "]", value.count > 2 else { return false }
    literal = String(value.dropFirst().dropLast())
  } else {
    literal = value
  }

  var ipv4 = in_addr()
  if literal.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
    let address = UInt32(bigEndian: ipv4.s_addr)
    return tailscaleIPv4Start...tailscaleIPv4End ~= address && address != quad100IPv4
  }

  var ipv6 = in6_addr()
  guard literal.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else {
    return false
  }
  let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
  return bytes.count >= tailscaleIPv6Prefix.count
    && Array(bytes.prefix(tailscaleIPv6Prefix.count)) == tailscaleIPv6Prefix
}

/// Validates and normalizes a remembered Tailscale companion URL or host.
///
/// The URL must use HTTP or HTTPS, identify a Tailscale IP literal or a
/// `*.ts.net` MagicDNS name, and contain no credentials, path, query, or
/// fragment. An omitted port uses the companion API's default port.
public func tailscaleCompanionURL(_ raw: String) -> String? {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
  guard var components = URLComponents(string: candidate),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    let host = components.host,
    !host.isEmpty,
    components.user == nil,
    components.password == nil,
    components.query == nil,
    components.fragment == nil,
    components.path.isEmpty || components.path == "/",
    !hasMalformedPort(in: candidate)
  else {
    return nil
  }

  let isMagicDNS = host.lowercased().hasSuffix(".ts.net")
  guard isTailscaleHost(host) || isMagicDNS else { return nil }

  let port = components.port ?? CompanionKernelClient.defaultPort
  guard (1...65_535).contains(port) else { return nil }

  components.scheme = scheme
  components.path = ""
  components.port = port
  guard let candidate = components.string else { return nil }
  let normalized = normalizeRemoteKernelUrl(candidate)
  return normalized.isEmpty ? nil : normalized
}

private func hasMalformedPort(in value: String) -> Bool {
  guard let scheme = value.range(of: "://", options: .caseInsensitive) else {
    return true
  }
  let remainder = value[scheme.upperBound...]
  let authorityEnd = remainder.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? remainder.endIndex
  let authority = remainder[..<authorityEnd]

  let hasPortDelimiter: Bool
  if authority.first == "[" {
    guard let closingBracket = authority.firstIndex(of: "]") else { return true }
    hasPortDelimiter = authority[authority.index(after: closingBracket)...].contains(":")
  } else {
    hasPortDelimiter = authority.contains(":")
  }

  // URLComponents reports nil for both an omitted port and a trailing colon.
  // Once a delimiter is present, nil means the explicit value was malformed.
  return hasPortDelimiter && URLComponents(string: value)?.port == nil
}
