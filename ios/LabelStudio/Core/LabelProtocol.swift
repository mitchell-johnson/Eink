import Foundation
import CommonCrypto

/// Wire facts independently recovered from WoPda and verified on the 400 × 300 label.
enum LabelProtocol {
    static let width = 400
    static let height = 300
    static let frameByteCount = width * height / 4
    static let serviceUUID = "30323032-4C53-4545-4C42-4B4E494C4F57"
    static let dataUUID = "31323032-4C53-4545-4C42-4B4E494C4F57"
    static let infoUUID = "32323032-4C53-4545-4C42-4B4E494C4F57"
    static let authUUID = "33323032-4C53-4545-4C42-4B4E494C4F57"
    static let statusUUID = "34323032-4C53-4545-4C42-4B4E494C4F57"
    static let batteryUUID = "35323032-4C53-4545-4C42-4B4E494C4F57"

    static func validateFrame(_ frame: Data) throws {
        guard frame.count == frameByteCount else {
            throw LabelProtocolError.invalidFrame
        }
    }

    static func authenticationResponse(nonce: Data, key: Data) throws -> Data {
        guard nonce.count == kCCBlockSizeAES128, key.count == kCCKeySizeAES128 else {
            throw LabelProtocolError.invalidAuthentication
        }
        var output = Data(count: kCCBlockSizeAES128)
        var count = 0
        let result = output.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { keyBytes in
                nonce.withUnsafeBytes { nonceBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count,
                            nil, nonceBytes.baseAddress, nonce.count, out.baseAddress,
                            kCCBlockSizeAES128, &count)
                }
            }
        }
        guard result == kCCSuccess, count == kCCBlockSizeAES128 else {
            throw LabelProtocolError.encryptionFailed
        }
        return output
    }

    static func shortWriteLimit(withResponse: Int, withoutResponse: Int) throws -> Int {
        // A write-with-response maximum may include ATT Prepare/Execute long
        // writes. Bound it by the ordinary command payload size as well, while
        // still transmitting every packet with a response.
        let limit = min(withResponse, withoutResponse)
        guard limit > 0 else { throw LabelProtocolError.writeTooSmall }
        return limit
    }

    static func payloadSize(maximumWriteLength: Int) throws -> Int {
        guard maximumWriteLength > 6 else { throw LabelProtocolError.writeTooSmall }
        return min(180, maximumWriteLength - 6)
    }

    static func dataPacket(offset: Int, payload: Data) throws -> Data {
        guard !payload.isEmpty, offset >= 0, offset <= Int(UInt32.max),
              payload.count <= Int(UInt32.max) - offset else {
            throw LabelProtocolError.invalidPacket
        }
        var packet = Data([0x00, 0xa5])
        appendLittleEndian(UInt32(offset), to: &packet)
        packet.append(payload)
        return packet
    }

    static func refreshPacket(size: Int) throws -> Data {
        guard size > 0, size <= Int(UInt32.max) else { throw LabelProtocolError.invalidPacket }
        var packet = Data([0x01, 0xa5]) // Entire uncompressed 2bpp frame.
        appendLittleEndian(UInt32(size), to: &packet)
        return packet
    }

    static func parseStatus(_ data: Data) throws -> LabelStatus {
        guard data.count >= 2 else { throw LabelProtocolError.malformedStatus }
        let bytes = [UInt8](data.prefix(2))
        return LabelStatus(flags: bytes[0], error: bytes[1])
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}

struct LabelStatus: Equatable {
    let flags: UInt8
    let error: UInt8
    var busy: Bool { flags != 0xff && flags & 1 != 0 }
    var completed: Bool { flags == 0xff && error == 0 }
    var locked: Bool { flags != 0xff && flags & 0x06 != 0 }
}

enum LabelStatusSource { case read, notification }
enum LabelRefreshConfirmation: String { case notification = "completion notification", busyToIdle = "busy-to-idle status transition" }

/// Created immediately before the refresh command; earlier status cannot confirm it.
struct LabelRefreshTracker {
    private(set) var sawBusy = false

    mutating func observe(_ data: Data, source: LabelStatusSource) throws -> LabelRefreshConfirmation? {
        guard let status = try? LabelProtocol.parseStatus(data) else { return nil }
        if status.error != 0 { throw LabelProtocolError.deviceError(status.error) }
        if status.locked { throw LabelProtocolError.authenticationRejected }
        if status.completed { return source == .notification ? .notification : nil }
        if status.busy { sawBusy = true }
        else if sawBusy { return .busyToIdle }
        return nil
    }
}

enum LabelProtocolError: LocalizedError {
    case invalidFrame, invalidAuthentication, encryptionFailed, invalidPacket, writeTooSmall
    case malformedStatus, authenticationRejected, deviceError(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The label needs a complete 400 × 300 image (30,000 packed bytes)."
        case .invalidAuthentication: return "The label returned an invalid authentication challenge."
        case .encryptionFailed: return "Could not create the label authentication response."
        case .invalidPacket: return "The image contains an invalid transfer fragment."
        case .writeTooSmall: return "The Bluetooth connection cannot carry an image command."
        case .malformedStatus: return "The label returned incomplete status information."
        case .authenticationRejected: return "The label rejected Bluetooth authentication."
        case .deviceError(let code):
            let labels: [UInt8: String] = [1: "display initialization", 2: "display write", 3: "decompression", 4: "firmware", 5: "authentication"]
            return "The label reported a \(labels[code] ?? "device") error (\(code))."
        }
    }
}
