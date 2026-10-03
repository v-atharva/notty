import CryptoKit
import Foundation

enum NotebookDigest {
    private static let digits = Array("0123456789abcdef".utf8)

    static func sha256(_ data: Data) -> String {
        lowercaseHex(SHA256.hash(data: data))
    }

    static func lowercaseHex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var output: [UInt8] = []
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
