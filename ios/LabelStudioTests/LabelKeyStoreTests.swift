import Foundation
import XCTest
@testable import LabelStudio

final class LabelKeyStoreTests: XCTestCase {
    // Public FIPS-197 test material, never a real device credential.
    private let syntheticKey = "000102030405060708090a0b0c0d0e0f"

    func testHexParsingPreservesAllSixteenBytes() throws {
        let expected = Data(0...15)
        XCTAssertEqual(try LabelKeyStore.decode(hex: syntheticKey), expected)
        XCTAssertEqual(try LabelKeyStore.decode(hex: " \(syntheticKey.uppercased())\n"), expected)
    }

    func testMalformedKeysAreRejectedWithoutPartialParsing() {
        for value in ["", "00", String(repeating: "a", count: 31), String(repeating: "a", count: 33),
                      String(repeating: "g", count: 32), "0x" + syntheticKey,
                      "00010203040506 8090a0b0c0d0e0f", String(repeating: "０", count: 32)] {
            XCTAssertThrowsError(try LabelKeyStore.decode(hex: value)) { error in
                guard case LabelKeyError.invalid = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testIsolatedKeychainLifecycleAndInvalidReplacement() throws {
        // A fresh, test-only namespace prevents reading or changing the owner's key.
        let store = LabelKeyStore(service: "com.example.LabelStudioTests.label-key.\(UUID().uuidString)")
        defer { try? store.remove() }
        assertMissing(store)
        try store.save(hex: syntheticKey)
        XCTAssertEqual(try store.load(), Data(0...15))
        XCTAssertThrowsError(try store.save(hex: "invalid"))
        XCTAssertEqual(try store.load(), Data(0...15), "Invalid input must preserve the existing key")
        let replacement = "ffeeddccbbaa99887766554433221100"
        try store.save(hex: replacement)
        XCTAssertEqual(try store.load(), try LabelKeyStore.decode(hex: replacement))
        try store.remove()
        assertMissing(store)
        XCTAssertNoThrow(try store.remove())
    }

    private func assertMissing(_ store: LabelKeyStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try store.load(), file: file, line: line) { error in
            guard case LabelKeyError.missing = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
            XCTAssertEqual(error.localizedDescription, "Add your label authentication key in Settings before writing to a label.", file: file, line: line)
        }
    }
}
