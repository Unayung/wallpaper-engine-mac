//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parses Wallpaper Engine TEXV0005 texture containers, including LZ4-backed
//  RGBA atlases and TEXS sprite animation metadata.
//

import Cocoa
import Compression
import Foundation

struct TEXMetadata: Equatable {
    let format: UInt32
    let flags: UInt32
    let width: UInt32
    let height: UInt32
    let textureWidth: UInt32
    let textureHeight: UInt32

    var normalizedContentRect: CGRect {
        // Static Wallpaper Engine TEX files can use their logical dimensions
        // as the rendered object size while the complete storage atlas still
        // contains authored scene pixels. Cropping to width/height removes
        // real map content and breaks alignment with separately placed nodes.
        CGRect(x: 0, y: 0, width: 1, height: 1)
    }
}

struct WETextureFrame: Equatable {
    let imageIndex: UInt32
    let duration: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func normalizedRect(textureWidth: Double, textureHeight: Double) -> CGRect {
        guard textureWidth > 0, textureHeight > 0 else { return .zero }
        return CGRect(
            x: x / textureWidth,
            y: 1 - ((y + height) / textureHeight),
            width: width / textureWidth,
            height: height / textureHeight
        )
    }
}

struct WEDecodedTexture {
    let metadata: TEXMetadata
    let image: NSImage
    let rgbaData: Data?
    let frames: [WETextureFrame]
}

enum TEXError: Error, LocalizedError, Equatable {
    case unexpectedEndOfFile
    case invalidMagic(expected: String, actual: String)
    case unsupportedContainer(String)
    case unsupportedFormat(UInt32)
    case invalidDimensions(width: UInt32, height: UInt32)
    case invalidPayload
    case decompressionFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedEndOfFile:
            return "Unexpected end of TEX file"
        case .invalidMagic(let expected, let actual):
            return "Invalid TEX magic: expected \(expected), got \(actual)"
        case .unsupportedContainer(let container):
            return "Unsupported TEX container \(container)"
        case .unsupportedFormat(let format):
            return "Unsupported TEX pixel format \(format)"
        case .invalidDimensions(let width, let height):
            return "Invalid TEX dimensions \(width)x\(height)"
        case .invalidPayload:
            return "Invalid TEX image payload"
        case .decompressionFailed:
            return "Could not decompress TEX LZ4 payload"
        case .imageCreationFailed:
            return "Could not create an image from TEX pixels"
        }
    }
}

final class TEXParser {
    private static let animatedFlag: UInt32 = 4
    private static let rawRGBAFormat: UInt32 = 0
    private static let unknownFreeImageFormat = UInt32.max

    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func decodeTexture() throws -> WEDecodedTexture {
        var reader = TEXBinaryReader(data: data)

        try reader.requireMagic("TEXV0005")
        try reader.requireMagic("TEXI0001")

        let format = try reader.readUInt32()
        let flags = try reader.readUInt32()
        let textureWidth = try reader.readUInt32()
        let textureHeight = try reader.readUInt32()
        let width = try reader.readUInt32()
        let height = try reader.readUInt32()
        _ = try reader.readUInt32()

        guard textureWidth > 0, textureHeight > 0 else {
            throw TEXError.invalidDimensions(width: textureWidth, height: textureHeight)
        }

        let metadata = TEXMetadata(
            format: format,
            flags: flags,
            width: width,
            height: height,
            textureWidth: textureWidth,
            textureHeight: textureHeight
        )

        let container = try reader.readMagic()
        let containerVersion: Int
        let imageCount: UInt32
        let freeImageFormat: UInt32

        switch container {
        case "TEXB0001":
            containerVersion = 1
            imageCount = try reader.readUInt32()
            freeImageFormat = Self.unknownFreeImageFormat
        case "TEXB0002":
            containerVersion = 2
            imageCount = try reader.readUInt32()
            freeImageFormat = Self.unknownFreeImageFormat
        case "TEXB0003":
            containerVersion = 3
            imageCount = try reader.readUInt32()
            freeImageFormat = try reader.readUInt32()
        case "TEXB0004":
            containerVersion = 4
            imageCount = try reader.readUInt32()
            freeImageFormat = try reader.readUInt32()
            _ = try reader.readUInt32() // MP4 marker
        default:
            throw TEXError.unsupportedContainer(container)
        }

        guard imageCount > 0, imageCount < 10_000 else {
            throw TEXError.invalidPayload
        }

        var primaryMipmap: TEXMipmap?

        for imageIndex in 0..<imageCount {
            let mipmapCount = try reader.readUInt32()
            guard mipmapCount > 0, mipmapCount < 64 else {
                throw TEXError.invalidPayload
            }

            for mipmapIndex in 0..<mipmapCount {
                if containerVersion == 4 {
                    _ = try reader.readUInt32()
                    _ = try reader.readUInt32()
                    _ = try reader.readNullTerminatedString()
                    _ = try reader.readUInt32()
                }

                let mipWidth = try reader.readUInt32()
                let mipHeight = try reader.readUInt32()
                let compression: UInt32
                let uncompressedSize: Int

                if containerVersion >= 2 {
                    compression = try reader.readUInt32()
                    uncompressedSize = Int(try reader.readInt32())
                } else {
                    compression = 0
                    uncompressedSize = 0
                }

                let compressedSize = Int(try reader.readInt32())
                guard compressedSize >= 0, uncompressedSize >= 0 else {
                    throw TEXError.invalidPayload
                }
                let payload = try reader.readData(count: compressedSize)

                if imageIndex == 0, mipmapIndex == 0 {
                    primaryMipmap = TEXMipmap(
                        width: mipWidth,
                        height: mipHeight,
                        compression: compression,
                        uncompressedSize: compression == 0 ? compressedSize : uncompressedSize,
                        payload: payload
                    )
                }
            }
        }

        guard let primaryMipmap else {
            throw TEXError.invalidPayload
        }

        let decodedPayload = try decode(primaryMipmap)
        let frames = try decodeFramesIfPresent(flags: flags, reader: &reader)

        let image: NSImage
        let rgbaData: Data?

        if freeImageFormat != Self.unknownFreeImageFormat {
            guard let encodedImage = NSImage(data: decodedPayload) else {
                throw TEXError.imageCreationFailed
            }
            image = encodedImage
            rgbaData = nil
        } else {
            guard format == Self.rawRGBAFormat else {
                throw TEXError.unsupportedFormat(format)
            }
            image = try makeRGBAImage(
                pixels: decodedPayload,
                width: primaryMipmap.width,
                height: primaryMipmap.height
            )
            rgbaData = decodedPayload
        }

        return WEDecodedTexture(
            metadata: metadata,
            image: image,
            rgbaData: rgbaData,
            frames: frames
        )
    }

    func extractImage() -> NSImage? {
        do {
            return try decodeTexture().image
        } catch {
            NSLog("[TEXParser] %@", String(describing: error))
            return nil
        }
    }

    func extractImageData() -> Data? {
        try? decodeTexture().rgbaData
    }

    private func decode(_ mipmap: TEXMipmap) throws -> Data {
        switch mipmap.compression {
        case 0:
            return mipmap.payload
        case 1:
            guard mipmap.uncompressedSize > 0 else {
                throw TEXError.invalidPayload
            }

            var output = [UInt8](repeating: 0, count: mipmap.uncompressedSize)
            let decodedSize = mipmap.payload.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    guard
                        let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress,
                        let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress
                    else {
                        return 0
                    }
                    return compression_decode_buffer(
                        destinationAddress,
                        destination.count,
                        sourceAddress,
                        source.count,
                        nil,
                        COMPRESSION_LZ4_RAW
                    )
                }
            }

            guard decodedSize == mipmap.uncompressedSize else {
                throw TEXError.decompressionFailed
            }
            return Data(output)
        default:
            throw TEXError.invalidPayload
        }
    }

    private func decodeFramesIfPresent(
        flags: UInt32,
        reader: inout TEXBinaryReader
    ) throws -> [WETextureFrame] {
        guard flags & Self.animatedFlag != 0 else { return [] }

        let animationVersion = try reader.readMagic()
        guard ["TEXS0001", "TEXS0002", "TEXS0003"].contains(animationVersion) else {
            throw TEXError.unsupportedContainer(animationVersion)
        }

        let frameCount = try reader.readUInt32()
        guard frameCount > 0, frameCount < 100_000 else {
            throw TEXError.invalidPayload
        }

        if animationVersion == "TEXS0003" {
            _ = try reader.readUInt32() // logical frame width
            _ = try reader.readUInt32() // logical frame height
        }

        var frames: [WETextureFrame] = []
        frames.reserveCapacity(Int(frameCount))

        for _ in 0..<frameCount {
            let imageIndex = try reader.readUInt32()
            let duration = Double(try reader.readFloat())

            if animationVersion == "TEXS0001" {
                let x = Double(try reader.readUInt32())
                let y = Double(try reader.readUInt32())
                let width = Double(try reader.readUInt32())
                _ = try reader.readUInt32()
                _ = try reader.readUInt32()
                let height = Double(try reader.readUInt32())
                frames.append(
                    WETextureFrame(
                        imageIndex: imageIndex,
                        duration: duration,
                        x: x,
                        y: y,
                        width: width,
                        height: height
                    )
                )
            } else {
                let x = Double(try reader.readFloat())
                let y = Double(try reader.readFloat())
                let width = Double(try reader.readFloat())
                _ = try reader.readFloat()
                _ = try reader.readFloat()
                let height = Double(try reader.readFloat())
                frames.append(
                    WETextureFrame(
                        imageIndex: imageIndex,
                        duration: duration,
                        x: x,
                        y: y,
                        width: width,
                        height: height
                    )
                )
            }
        }

        return frames
    }

    private func makeRGBAImage(pixels: Data, width: UInt32, height: UInt32) throws -> NSImage {
        guard width > 0, height > 0 else {
            throw TEXError.invalidDimensions(width: width, height: height)
        }

        let expectedBytes = Int(width) * Int(height) * 4
        guard pixels.count >= expectedBytes else {
            throw TEXError.invalidPayload
        }

        guard
            let provider = CGDataProvider(data: pixels.prefix(expectedBytes) as CFData),
            let cgImage = CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(width) * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw TEXError.imageCreationFailed
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: Int(width), height: Int(height))
        )
    }
}

private struct TEXMipmap {
    let width: UInt32
    let height: UInt32
    let compression: UInt32
    let uncompressedSize: Int
    let payload: Data
}

private struct TEXBinaryReader {
    private let data: Data
    private(set) var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func requireMagic(_ expected: String) throws {
        let actual = try readMagic()
        guard actual == expected else {
            throw TEXError.invalidMagic(expected: expected, actual: actual)
        }
    }

    mutating func readMagic() throws -> String {
        let bytes = try readData(count: 9)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw TEXError.unexpectedEndOfFile
        }
        let value = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw TEXError.unexpectedEndOfFile
        }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    mutating func readNullTerminatedString() throws -> String {
        let start = offset
        while offset < data.count, data[offset] != 0 {
            offset += 1
        }
        guard offset < data.count else {
            throw TEXError.unexpectedEndOfFile
        }
        let value = String(decoding: data[start..<offset], as: UTF8.self)
        offset += 1
        return value
    }
}
