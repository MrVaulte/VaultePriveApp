import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

/// Pixel-art visual code embedded in a hood symbol.
/// - Logical canvas: 32x32 pixels
/// - Data area: 24 bits arranged as 4x6 pixels inside the hood center
enum PixelArtVisualCode {
    static let logicalSize = 32
    static let signature: UInt8 = 0b1010_0110

    /// Deterministic coordinate map for 24 bits (row-major, 4 columns x 6 rows).
    /// Top-left of data block starts at (14, 10) in a 32x32 logical canvas.
    static let dataPixelCoordinates: [(x: Int, y: Int)] = {
        var out: [(Int, Int)] = []
        for row in 0..<6 {
            for col in 0..<4 {
                out.append((14 + col, 10 + row))
            }
        }
        return out
    }()

    struct Decoded: Equatable {
        let version: UInt8
        let payload: UInt8
        let checksum: UInt8
    }

    enum Error: Swift.Error {
        case invalidVersion
        case invalidPayload
        case checksumMismatch
        case invalidSignature
        case imageBuildFailed
        case imageDecodeFailed
    }

    /// Encode version+payload into a pixel-art image built from a base symbol image.
    /// - Parameters:
    ///   - version: 4-bit value (0...15)
    ///   - payload: 8-bit value
    ///   - baseImage: reference pixel-art hood image
    ///   - scale: output scale factor (nearest-neighbor). 12 => 384x384 output.
    static func encode(
        version: UInt8,
        payload: UInt8,
        baseImage: PlatformImage,
        scale: Int = 12
    ) throws -> PlatformImage {
        guard version < 16 else { throw Error.invalidVersion }

        let checksum = checksumNibble(version: version, payload: payload)
        let bits = assembleBits(version: version, payload: payload, checksum: checksum)

        guard var pixels = normalizeToLogicalPixels(baseImage) else {
            throw Error.imageBuildFailed
        }
        drawDataBits(bits, on: &pixels)

        guard let cg = makeScaledCGImage(from: pixels, scale: max(1, scale)) else {
            throw Error.imageBuildFailed
        }

        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        throw Error.imageBuildFailed
        #endif
    }

    /// Decode a generated pixel-art visual code image.
    static func decode(from image: PlatformImage) throws -> Decoded {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { throw Error.imageDecodeFailed }
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw Error.imageDecodeFailed
        }
        #endif

        guard let sampled = sampleToLogicalCanvas(cgImage: cgImage) else {
            throw Error.imageDecodeFailed
        }

        let bits = readDataBits(from: sampled)
        let sig = bitsToUInt8(bits[0..<8])
        guard sig == signature else { throw Error.invalidSignature }

        let version = bitsToUInt8(bits[8..<12])
        let payload = bitsToUInt8(bits[12..<20])
        let checksum = bitsToUInt8(bits[20..<24])
        let expected = checksumNibble(version: version, payload: payload)
        guard checksum == expected else { throw Error.checksumMismatch }

        return Decoded(version: version, payload: payload, checksum: checksum)
    }
}

// MARK: - Build bits

private extension PixelArtVisualCode {
    static func assembleBits(version: UInt8, payload: UInt8, checksum: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        out += byteToBits(signature, count: 8)
        out += byteToBits(version, count: 4)
        out += byteToBits(payload, count: 8)
        out += byteToBits(checksum, count: 4)
        return out
    }

    static func checksumNibble(version: UInt8, payload: UInt8) -> UInt8 {
        let sHi = (signature >> 4) & 0x0F
        let sLo = signature & 0x0F
        let pHi = (payload >> 4) & 0x0F
        let pLo = payload & 0x0F
        return (sHi ^ sLo ^ (version & 0x0F) ^ pHi ^ pLo) & 0x0F
    }

    static func byteToBits(_ value: UInt8, count: Int) -> [UInt8] {
        let shiftStart = count - 1
        return (0..<count).map { idx in
            let shift = shiftStart - idx
            return (value >> UInt8(shift)) & 1
        }
    }

    static func bitsToUInt8<S: Collection>(_ bits: S) -> UInt8 where S.Element == UInt8 {
        bits.reduce(UInt8(0)) { ($0 << 1) | ($1 & 1) }
    }
}

// MARK: - Render symbol + data

private extension PixelArtVisualCode {
    static func drawDataBits(_ bits: [UInt8], on pixels: inout [RGBA]) {
        for (i, coord) in dataPixelCoordinates.enumerated() {
            let bit = bits[i]
            let color: RGBA = bit == 1
                ? RGBA(14, 14, 16, 255)     // dark => 1
                : RGBA(212, 212, 216, 255)  // light => 0
            setPixel(&pixels, x: coord.x, y: coord.y, color: color)
        }
    }
}

// MARK: - Decode helpers

private extension PixelArtVisualCode {
    static func normalizeToLogicalPixels(_ image: PlatformImage) -> [RGBA]? {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return nil }
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        #endif
        return sampleToLogicalCanvas(cgImage: cgImage)
    }

    static func sampleToLogicalCanvas(cgImage: CGImage) -> [RGBA]? {
        let width = logicalSize
        let height = logicalSize
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var out: [RGBA] = []
        out.reserveCapacity(width * height)
        for i in stride(from: 0, to: data.count, by: 4) {
            out.append(RGBA(data[i], data[i + 1], data[i + 2], data[i + 3]))
        }
        return out
    }

    static func readDataBits(from pixels: [RGBA]) -> [UInt8] {
        dataPixelCoordinates.map { coord in
            let p = pixelAt(pixels, x: coord.x, y: coord.y)
            let luminance = (0.2126 * Double(p.r) + 0.7152 * Double(p.g) + 0.0722 * Double(p.b)) / 255.0
            return luminance < 0.45 ? 1 : 0
        }
    }
}

// MARK: - Pixel ops

private struct RGBA {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

private extension PixelArtVisualCode {
    static func index(x: Int, y: Int) -> Int { y * logicalSize + x }

    static func setPixel(_ pixels: inout [RGBA], x: Int, y: Int, color: RGBA) {
        guard x >= 0, y >= 0, x < logicalSize, y < logicalSize else { return }
        pixels[index(x: x, y: y)] = color
    }

    static func pixelAt(_ pixels: [RGBA], x: Int, y: Int) -> RGBA {
        let xx = min(max(x, 0), logicalSize - 1)
        let yy = min(max(y, 0), logicalSize - 1)
        return pixels[index(x: xx, y: yy)]
    }

    static func makeScaledCGImage(from logical: [RGBA], scale: Int) -> CGImage? {
        let width = logicalSize * scale
        let height = logicalSize * scale
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<logicalSize {
            for x in 0..<logicalSize {
                let src = logical[index(x: x, y: y)]
                for oy in 0..<scale {
                    for ox in 0..<scale {
                        let dx = x * scale + ox
                        let dy = y * scale + oy
                        let di = dy * bytesPerRow + dx * 4
                        data[di] = src.r
                        data[di + 1] = src.g
                        data[di + 2] = src.b
                        data[di + 3] = src.a
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/*
 Example flow:

 // Base symbol should be your hood PNG from assets/bundle:
 // let base = UIImage(named: "hood_symbol")!
 //
 // Encode
 let image = try PixelArtVisualCode.encode(
     version: 1,
     payload: 0x2A,
     baseImage: base,
     scale: 14
 )

 // Decode
 let decoded = try PixelArtVisualCode.decode(from: image)
 // decoded.version == 1
 // decoded.payload == 0x2A
 */
