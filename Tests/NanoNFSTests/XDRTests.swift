import Foundation
import NIOCore
import Testing
@testable import NanoNFS

@Suite("XDR primitives (RFC 4506)")
struct XDRTests {

    // MARK: integers

    @Test("UInt32 round-trip")
    func uint32RoundTrip() throws {
        var enc = XDREncoder()
        enc.writeUInt32(0)
        enc.writeUInt32(1)
        enc.writeUInt32(0x1234_5678)
        enc.writeUInt32(.max)

        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readUInt32() == 0)
        #expect(try dec.readUInt32() == 1)
        #expect(try dec.readUInt32() == 0x1234_5678)
        #expect(try dec.readUInt32() == .max)
        #expect(dec.bytesRemaining == 0)
    }

    @Test("Big-endian on the wire")
    func bigEndian() {
        var enc = XDREncoder()
        enc.writeUInt32(0x0A0B_0C0D)
        let bytes = Array(enc.buffer.readableBytesView)
        #expect(bytes == [0x0A, 0x0B, 0x0C, 0x0D])
    }

    @Test("UInt64 (hyper) round-trip")
    func uint64RoundTrip() throws {
        var enc = XDREncoder()
        enc.writeUInt64(0xDEAD_BEEF_CAFE_BABE)
        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readUInt64() == 0xDEAD_BEEF_CAFE_BABE)
    }

    @Test("Int32 negative values round-trip in two's complement")
    func int32Negative() throws {
        var enc = XDREncoder()
        enc.writeInt32(-1)
        enc.writeInt32(.min)
        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readInt32() == -1)
        #expect(try dec.readInt32() == .min)
    }

    @Test("Bool round-trip")
    func boolRoundTrip() throws {
        var enc = XDREncoder()
        enc.writeBool(false)
        enc.writeBool(true)
        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readBool() == false)
        #expect(try dec.readBool() == true)
    }

    @Test("Bool rejects non-{0,1}")
    func boolRejectsInvalid() {
        var enc = XDREncoder()
        enc.writeUInt32(2)
        var dec = XDRDecoder(enc.buffer)
        #expect(throws: XDRError.invalidBoolean(2)) {
            _ = try dec.readBool()
        }
    }

    // MARK: opaque

    @Test("Fixed opaque is zero-padded to 4-byte boundary")
    func fixedOpaquePadding() throws {
        var enc = XDREncoder()
        enc.writeFixedOpaque(Data([0xAA, 0xBB, 0xCC])) // 3 bytes -> 1 byte pad
        let bytes = Array(enc.buffer.readableBytesView)
        #expect(bytes == [0xAA, 0xBB, 0xCC, 0x00])

        var dec = XDRDecoder(enc.buffer)
        let read = try dec.readFixedOpaqueData(count: 3)
        #expect(Array(read) == [0xAA, 0xBB, 0xCC])
        #expect(dec.bytesRemaining == 0)
    }

    @Test("Fixed opaque on 4-byte boundary has no padding")
    func fixedOpaqueAligned() {
        var enc = XDREncoder()
        enc.writeFixedOpaque(Data([1, 2, 3, 4]))
        #expect(enc.buffer.readableBytes == 4)
    }

    @Test("Variable opaque round-trip with padding")
    func variableOpaqueRoundTrip() throws {
        var enc = XDREncoder()
        enc.writeVariableOpaque(Data([0x01, 0x02, 0x03, 0x04, 0x05])) // length=5

        // Layout: 4 (length) + 5 (data) + 3 (pad) = 12
        #expect(enc.buffer.readableBytes == 12)

        var dec = XDRDecoder(enc.buffer)
        let out = try dec.readVariableOpaqueData()
        #expect(Array(out) == [1, 2, 3, 4, 5])
        #expect(dec.bytesRemaining == 0)
    }

    @Test("Empty variable opaque is just a 0 length word")
    func variableOpaqueEmpty() throws {
        var enc = XDREncoder()
        enc.writeVariableOpaque(Data())
        #expect(enc.buffer.readableBytes == 4)

        var dec = XDRDecoder(enc.buffer)
        let out = try dec.readVariableOpaqueData()
        #expect(out.isEmpty)
    }

    @Test("Variable opaque enforces declared length limit")
    func variableOpaqueLimit() throws {
        var enc = XDREncoder()
        enc.writeUInt32(1024)
        enc.writeFixedOpaque(Data(repeating: 0, count: 1024))

        var dec = XDRDecoder(enc.buffer)
        #expect(throws: XDRError.self) {
            _ = try dec.readVariableOpaqueData(maxLength: 100)
        }
    }

    // MARK: string

    @Test("String UTF-8 round-trip")
    func stringRoundTrip() throws {
        var enc = XDREncoder()
        enc.writeString("hello")
        enc.writeString("형아")  // multibyte UTF-8

        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readString() == "hello")
        #expect(try dec.readString() == "형아")
    }

    @Test("String rejects invalid UTF-8")
    func stringRejectsInvalidUTF8() {
        var enc = XDREncoder()
        enc.writeUInt32(2)
        enc.writeFixedOpaque(Data([0xFF, 0xFE]))

        var dec = XDRDecoder(enc.buffer)
        #expect(throws: XDRError.invalidUTF8) {
            _ = try dec.readString()
        }
    }

    // MARK: truncation

    @Test("Truncated buffer throws .truncated on integer read")
    func truncatedInteger() {
        var buf = ByteBuffer()
        buf.writeBytes([0x00, 0x01]) // only 2 bytes
        var dec = XDRDecoder(buf)
        #expect(throws: XDRError.truncated) {
            _ = try dec.readUInt32()
        }
    }

    @Test("Truncated padding on fixed opaque throws .truncated")
    func truncatedPadding() {
        var buf = ByteBuffer()
        buf.writeBytes([0xAA]) // 1 byte data, no padding follows
        var dec = XDRDecoder(buf)
        #expect(throws: XDRError.truncated) {
            _ = try dec.readFixedOpaque(count: 1)
        }
    }

    // MARK: placeholder

    @Test("Placeholder UInt32 backfill")
    func placeholder() throws {
        var enc = XDREncoder()
        let slot = enc.placeholderUInt32()
        enc.writeUInt32(0xAAAA_BBBB)
        enc.setUInt32(at: slot, 42)

        var dec = XDRDecoder(enc.buffer)
        #expect(try dec.readUInt32() == 42)
        #expect(try dec.readUInt32() == 0xAAAA_BBBB)
    }
}
