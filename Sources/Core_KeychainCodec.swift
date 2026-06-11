import Foundation

// MARK: - `security -w` output decoding — pure core
//
// `security find-generic-password -w` returns the raw value, except it
// hex-encodes values containing newlines (which is how Claude Code's
// pretty-printed JSON comes back). Handle both forms.
//
// Pure string→string transform: no Process, no Keychain — the spawning lives
// in KeychainCLI (QuotaService.swift). Returns the decoded text (callers
// convert to UTF-8 Data for JSON parsing) or nil for an empty value.
enum KeychainCodec {
    static func decodeSecurityValue(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let d = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: d)) != nil {
            return trimmed
        }
        var hex = trimmed
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0,
              hex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil else {
            return trimmed
        }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return trimmed }
            bytes.append(b); i = j
        }
        // Hex-decoded bytes that aren't valid UTF-8 can't be JSON either, so
        // returning nil here is equivalent to the old Data path (which would
        // have failed JSON parsing at every call site anyway).
        return String(data: Data(bytes), encoding: .utf8)
    }
}
