import Foundation
import XCTest
#if canImport(LabelStudio)
@testable import LabelStudio
#endif

final class LabelProtocolTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        let compact = hex.replacingOccurrences(of: " ", with: "")
        return Data(stride(from: 0, to: compact.count, by: 2).map { index in
            let start = compact.index(compact.startIndex, offsetBy: index)
            return UInt8(compact[start..<compact.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    func testAuthenticationMatchesFIPS197() throws {
        XCTAssertEqual(try LabelProtocol.authenticationResponse(
            nonce: bytes("00112233445566778899aabbccddeeff"),
            key: bytes("000102030405060708090a0b0c0d0e0f")),
            bytes("69c4e0d86a7b0430d8cdb78070b4c55a"))
        for count in [0, 15, 17, 32] {
            XCTAssertThrowsError(try LabelProtocol.authenticationResponse(nonce: Data(repeating: 0, count: count), key: bytes("000102030405060708090a0b0c0d0e0f")))
        }
        XCTAssertThrowsError(try LabelProtocol.authenticationResponse(nonce: Data(repeating: 0, count: 16), key: Data()))
    }

    func testPacketsMatchIndependentWireFixtures() throws {
        XCTAssertEqual(try LabelProtocol.dataPacket(offset: 0x12345678, payload: bytes("ab cd")), bytes("00 a5 78 56 34 12 ab cd"))
        XCTAssertEqual(try LabelProtocol.refreshPacket(size: 30_000), bytes("01 a5 30 75 00 00"))
        XCTAssertThrowsError(try LabelProtocol.dataPacket(offset: -1, payload: bytes("01")))
        XCTAssertThrowsError(try LabelProtocol.dataPacket(offset: 0, payload: Data()))
        XCTAssertThrowsError(try LabelProtocol.dataPacket(offset: Int(UInt32.max), payload: bytes("01")))
        XCTAssertThrowsError(try LabelProtocol.refreshPacket(size: 0))
        XCTAssertThrowsError(try LabelProtocol.refreshPacket(size: Int(UInt32.max) + 1))
        XCTAssertEqual(try LabelProtocol.payloadSize(maximumWriteLength: 244), 180)
        XCTAssertEqual(try LabelProtocol.payloadSize(maximumWriteLength: 20), 14)
        XCTAssertThrowsError(try LabelProtocol.payloadSize(maximumWriteLength: 6))
    }

    func testShortWriteLimitAvoidsATTLongWrites() throws {
        // Acknowledged writes can advertise 512 while ordinary ATT packets
        // carry only 182 or 20 bytes; the six-byte label header counts too.
        for (acknowledged, short, expectedPayload) in [(512, 182, 176), (512, 20, 14), (244, 244, 180), (100, 244, 94)] {
            let limit = try LabelProtocol.shortWriteLimit(withResponse: acknowledged, withoutResponse: short)
            let capacity = try LabelProtocol.payloadSize(maximumWriteLength: limit)
            XCTAssertEqual(capacity, expectedPayload)
            let packet = try LabelProtocol.dataPacket(offset: 0, payload: Data(repeating: 0x55, count: capacity))
            XCTAssertLessThanOrEqual(packet.count, min(acknowledged, short))
        }
        XCTAssertThrowsError(try LabelProtocol.shortWriteLimit(withResponse: 512, withoutResponse: 0))
        XCTAssertThrowsError(try LabelProtocol.shortWriteLimit(withResponse: 0, withoutResponse: 244))
    }

    func testStatusRequiresCurrentRefreshEvidence() throws {
        var tracker = LabelRefreshTracker()
        XCTAssertNil(try tracker.observe(bytes("00 00"), source: .notification))
        XCTAssertNil(try tracker.observe(bytes("ff 00"), source: .read))
        XCTAssertFalse(tracker.sawBusy)
        XCTAssertEqual(try tracker.observe(bytes("ff 00 00 00"), source: .notification), .notification)
    }

    func testBusyThenIdleConfirmsRefresh() throws {
        var tracker = LabelRefreshTracker()
        XCTAssertNil(try tracker.observe(bytes("01 00"), source: .notification))
        XCTAssertTrue(tracker.sawBusy)
        XCTAssertEqual(try tracker.observe(bytes("00 00"), source: .notification), .busyToIdle)
        var polling = LabelRefreshTracker()
        XCTAssertNil(try polling.observe(bytes("01 00"), source: .read))
        XCTAssertEqual(try polling.observe(bytes("00 00"), source: .read), .busyToIdle)
    }

    func testErrorsNeverConfirmCompletionAndMalformedEventsAreIgnored() throws {
        for wire in ["00 03", "ff 03", "06 00", "07 00"] {
            var tracker = LabelRefreshTracker()
            XCTAssertThrowsError(try tracker.observe(bytes(wire), source: .notification))
        }
        var tracker = LabelRefreshTracker()
        for data in [Data(), bytes("ff"), bytes("01")] {
            XCTAssertNil(try tracker.observe(data, source: .notification))
            XCTAssertFalse(tracker.sawBusy)
        }
        XCTAssertThrowsError(try LabelProtocol.parseStatus(Data()))
    }

    func testFrameSizeIsExactlyVerifiedPanel() throws {
        XCTAssertEqual(LabelProtocol.width, 400)
        XCTAssertEqual(LabelProtocol.height, 300)
        XCTAssertEqual(LabelProtocol.frameByteCount, 30_000)
        XCTAssertNoThrow(try LabelProtocol.validateFrame(Data(repeating: 0x55, count: 30_000)))
        XCTAssertThrowsError(try LabelProtocol.validateFrame(Data(repeating: 0x55, count: 29_999)))
        XCTAssertThrowsError(try LabelProtocol.validateFrame(Data(repeating: 0x55, count: 30_001)))
    }
}

#if LABEL_PROTOCOL_STANDALONE
@main
struct ProtocolTestRunner {
    static func main() {
        let suite = XCTestSuite(forTestCaseClass: LabelProtocolTests.self)
        suite.run()
        guard let result = suite.testRun, result.executionCount == 7, result.totalFailureCount == 0 else {
            exit(1)
        }
    }
}
#endif
