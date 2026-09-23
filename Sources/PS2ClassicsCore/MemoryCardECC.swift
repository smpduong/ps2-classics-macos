// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// PS2 memory-card page ECC: a 20-bit Hamming code per 128-byte chunk,
/// stored as 3 bytes per chunk (12 bytes per 512-byte page) in the page
/// spare area; the remaining 4 spare bytes are left untouched by this code.
///
/// Algorithm: Ross Ridge's public-domain description of the card format
/// (column parity in the first byte — even groups low nibble, odd groups
/// high nibble — line parity in the other two). This is a clean-room
/// implementation of that documented arithmetic; bit-exactness against an
/// independent implementation's vectors is proven in `MemoryCardECCTests`.
///
/// What this does and does not establish: generated ECC makes written pages
/// structurally complete, and verification catches torn or corrupted pages
/// locally. Whether a console accepts an imported card is still open
/// hardware acceptance, like every other feature here.
public enum MemoryCardECC {
    private static let columnMasks: [UInt8] = [0x55, 0x33, 0x0F, 0x00, 0xAA, 0xCC, 0xF0]

    private static func parity(_ value: UInt8) -> UInt8 {
        var v = value ^ (value >> 1)
        v ^= v >> 2
        v ^= v >> 4
        return v & 1
    }

    private static let parityTable: [UInt8] = (0..<256).map { parity(UInt8($0)) }

    private static let columnMaskTable: [UInt8] = (0..<256).map { b in
        var mask: UInt8 = 0
        for k in 0..<columnMasks.count {
            mask |= parity(UInt8(b) & columnMasks[k]) << k
        }
        return mask
    }

    /// Three ECC bytes for exactly 128 data bytes.
    public static func calculate(for chunk: [UInt8]) -> [UInt8] {
        precondition(chunk.count == 128)
        var column: UInt8 = 0x77
        var line0: UInt8 = 0x7F
        var line1: UInt8 = 0x7F
        for (i, byte) in chunk.enumerated() {
            column ^= columnMaskTable[Int(byte)]
            if parityTable[Int(byte)] != 0 {
                // Reference arithmetic XORs the unbounded complement ~i and
                // keeps the low 7 bits; (127 - i) is exactly those bits.
                line0 ^= UInt8(127 - i)
                line1 ^= UInt8(i)
            }
        }
        return [column, line0 & 0x7F, line1]
    }

    /// Twelve ECC bytes for a 512-byte page (four chunks in order).
    /// Copies to zero-based indexing first: integer subscripts address the
    /// page, so a passed slice must not shift them.
    public static func calculatePage(_ data: Data) -> Data {
        let data = Data(data)
        precondition(data.count == 512)
        var out = [UInt8]()
        out.reserveCapacity(12)
        for c in 0..<4 {
            out.append(contentsOf: calculate(for: Array(data[c * 128..<(c + 1) * 128])))
        }
        return Data(out)
    }

    /// True when the first 12 spare bytes match freshly calculated ECC.
    /// Detects corruption; it does not correct anything.
    public static func verify(data: Data, spare: Data) -> Bool {
        guard data.count == 512, spare.count >= 12 else { return false }
        return calculatePage(data) == spare.prefix(12)
    }
}
