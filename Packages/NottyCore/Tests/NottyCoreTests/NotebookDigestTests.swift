import Foundation
import XCTest
@testable import NottyCore

final class NotebookDigestTests: XCTestCase {
    func testKnownSHA256VectorsRemainCompatible() {
        let vectors: [(Data, String)] = [
            (Data(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8),
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
            (
                Data((0...255).map { UInt8($0) }),
                "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"
            )
        ]
        for (data, expected) in vectors {
            XCTAssertEqual(NotebookDigest.sha256(data), expected)
            XCTAssertEqual(NotebookRevisionFormat.digest(data), expected)
            XCTAssertEqual(expected.utf8.count, 64)
        }
    }

    func testHexEncoderCoversEveryByteAndLeadingZero() {
        let input = (0...255).map { UInt8($0) }
        let expected = input.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(NotebookDigest.lowercaseHex(input), expected)
        XCTAssertEqual(NotebookDigest.lowercaseHex([UInt8(0), 1, 15, 16, 127, 128, 255]), "00010f107f80ff")
        XCTAssertEqual(NotebookDigest.lowercaseHex([UInt8]()), "")
        XCTAssertEqual(NotebookDigest.lowercaseHex(input).utf8.count, 512)
    }
}
