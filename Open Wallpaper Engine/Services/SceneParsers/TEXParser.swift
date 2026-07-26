//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (metadata) > TEXB (image data).
//  Supports embedded JPEG/PNG images and DXT1/DXT5 compressed TEX payloads.
//

import Cocoa
import Foundation

struct TEXMetadata {
    let format: UInt32
    let width: UInt32
    let height: UInt32
    let textureWidth: UInt32  // power-of-2 padded
    let textureHeight: UInt32
}

class TEXParser {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    /// Extract the image from this TEX container.
    func extractImage() -> NSImage? {
        let texiMeta = readTEXIMetadata()
        let texbFmt = readTEXBFormat()

        if let meta = texiMeta, let image = extractDXTImage(metadata: meta, texbFormat: texbFmt, allowInference: false) {
            return image
        }

        // Find TEXB section which contains the actual image data
        guard let texbRange = findSection("TEXB") else {
            NSLog("[TEXParser] TEXB section not found in %d bytes", data.count)
            return nil
        }

        let texbData = data[texbRange]
        NSLog("[TEXParser] TEXB found: range=%d..%d (%d bytes) fmt=%d", texbRange.lowerBound, texbRange.upperBound, texbData.count, texbFmt)

        // Look for JPEG magic bytes (FFD8) within TEXB
        if let jpegOffset = findJPEGMagic(in: texbData) {
            // Try to find the JPEG end marker (FFD9) to avoid trailing garbage
            let jpegData: Data
            if let endOffset = findJPEGEnd(in: texbData, from: jpegOffset) {
                jpegData = Data(texbData[jpegOffset...endOffset])
            } else {
                jpegData = Data(texbData[jpegOffset...])
            }
            NSLog("[TEXParser] JPEG found at offset %d, size=%d", jpegOffset - texbData.startIndex, jpegData.count)
            if let image = NSImage(data: jpegData) { return image }
            // If trimmed JPEG failed, try with all remaining data
            if let image = NSImage(data: Data(texbData[jpegOffset...])) { return image }
        }

        // Look for PNG magic bytes (89504E47) within TEXB
        if let pngOffset = findPNGMagic(in: texbData) {
            let pngData = Data(texbData[pngOffset...])
            if let image = NSImage(data: pngData) { return image }
        }

        // Fallback: scan entire data for JPEG/PNG (some TEX files have non-standard layout)
        if let jpegOffset = findJPEGMagic(in: data) {
            let jpegData: Data
            if let endOffset = findJPEGEnd(in: data, from: jpegOffset) {
                jpegData = Data(data[jpegOffset...endOffset])
            } else {
                jpegData = Data(data[jpegOffset...])
            }
            if let image = NSImage(data: jpegData) { return image }
        }

        if let meta = texiMeta, let image = extractDXTImage(metadata: meta, texbFormat: texbFmt, allowInference: true) {
            return image
        }

        NSLog("[TEXParser] No supported image format found in TEXB (%d bytes, may be DXT)", texbData.count)
        return nil
    }

    /// Extract raw JPEG/PNG data without creating NSImage
    func extractImageData() -> Data? {
        guard let texbRange = findSection("TEXB") else { return nil }
        let texbData = data[texbRange]

        if let jpegOffset = findJPEGMagic(in: texbData) {
            return Data(texbData[jpegOffset...])
        }
        if let pngOffset = findPNGMagic(in: texbData) {
            return Data(texbData[pngOffset...])
        }
        return nil
    }

    // MARK: - Private

    /// Read TEXI metadata section: format, flags, width, height, textureWidth, textureHeight
    private func readTEXIMetadata() -> TEXMetadata? {
        guard let texiMagic = "TEXI".data(using: .ascii) else { return nil }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texiMagic {
                // Skip past "TEXIxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 24 <= data.endIndex else { return nil }
                func u32(_ off: Int) -> UInt32 {
                    UInt32(data[j+off]) | (UInt32(data[j+off+1]) << 8)
                    | (UInt32(data[j+off+2]) << 16) | (UInt32(data[j+off+3]) << 24)
                }
                return TEXMetadata(format: u32(0), width: u32(8), height: u32(12),
                                   textureWidth: u32(16), textureHeight: u32(20))
            }
            i += 1
        }
        return nil
    }

    /// Read the TEXB format field (first uint32 after the null-terminated section name).
    /// Format 1 = image-extractable, Format 2 = DXT5, etc.
    private func readTEXBFormat() -> Int {
        guard let texbMagic = "TEXB".data(using: .ascii) else { return -1 }
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            if data[i..<i+4] == texbMagic {
                // Skip past "TEXBxxxx\0" (null-terminated name with version)
                var j = i + 4
                while j < data.endIndex && data[j] != 0 { j += 1 }
                j += 1 // skip null byte
                guard j + 4 <= data.endIndex else { return -1 }
                return Int(UInt32(data[j])
                    | (UInt32(data[j+1]) << 8)
                    | (UInt32(data[j+2]) << 16)
                    | (UInt32(data[j+3]) << 24))
            }
            i += 1
        }
        return -1
    }

    /// Find a named section (e.g. "TEXI", "TEXB") in the TEX data
    private func findSection(_ name: String) -> Range<Data.Index>? {
        guard let nameData = name.data(using: .ascii) else { return nil }
        let nameLen = nameData.count

        var i = data.startIndex
        while i + nameLen + 4 <= data.endIndex {
            if data[i..<i+nameLen] == nameData {
                // Section found — next 4 bytes after name are section length
                let lenStart = i + nameLen
                guard lenStart + 4 <= data.endIndex else { return nil }
                let sectionLen = UInt32(data[lenStart])
                    | (UInt32(data[lenStart+1]) << 8)
                    | (UInt32(data[lenStart+2]) << 16)
                    | (UInt32(data[lenStart+3]) << 24)
                let contentStart = lenStart + 4
                let contentEnd = contentStart + Int(sectionLen)
                guard contentEnd <= data.endIndex else {
                    return contentStart..<data.endIndex
                }
                return contentStart..<contentEnd
            }
            i += 1
        }
        return nil
    }

    /// Find JPEG end marker (FFD9) scanning from a given start position
    private func findJPEGEnd(in slice: Data, from start: Data.Index) -> Data.Index? {
        var i = start
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD9 {
                return i + 1  // Include the D9 byte
            }
            i += 1
        }
        return nil
    }

    private func findJPEGMagic(in slice: Data) -> Data.Index? {
        var i = slice.startIndex
        while i + 1 < slice.endIndex {
            if slice[i] == 0xFF && slice[i+1] == 0xD8 {
                return i
            }
            i += 1
        }
        return nil
    }

    private func findPNGMagic(in slice: Data) -> Data.Index? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        var i = slice.startIndex
        while i + 3 < slice.endIndex {
            if slice[i] == pngMagic[0] && slice[i+1] == pngMagic[1]
                && slice[i+2] == pngMagic[2] && slice[i+3] == pngMagic[3] {
                return i
            }
            i += 1
        }
        return nil
    }

    // MARK: - DXT Decoding

    private enum DXTFormat {
        case dxt1
        case dxt5

        var blockByteCount: Int {
            switch self {
            case .dxt1: return 8
            case .dxt5: return 16
            }
        }
    }

    private func extractDXTImage(metadata: TEXMetadata, texbFormat: Int, allowInference: Bool) -> NSImage? {
        guard let explicitFormat = dxtFormat(metadataFormat: metadata.format, texbFormat: texbFormat) else {
            guard allowInference, let inferred = inferDXTFormat(metadata: metadata) else {
                return nil
            }
            NSLog("[TEXParser] Inferred %@ texture from payload size for TEXI format %d / TEXB format %d",
                  inferred == .dxt1 ? "DXT1" : "DXT5", metadata.format, texbFormat)
            return decodeDXTImage(metadata: metadata, texbFormat: texbFormat, dxtFormat: inferred)
        }
        return decodeDXTImage(metadata: metadata, texbFormat: texbFormat, dxtFormat: explicitFormat)
    }

    private func decodeDXTImage(metadata: TEXMetadata, texbFormat: Int, dxtFormat: DXTFormat) -> NSImage? {
        guard metadata.width > 0, metadata.height > 0 else { return nil }
        guard let texbRange = findSection("TEXB") else { return nil }

        let texbData = data[texbRange]
        let storageWidth = max(Int(metadata.width), Int(metadata.textureWidth))
        let storageHeight = max(Int(metadata.height), Int(metadata.textureHeight))
        let blocksWide = (storageWidth + 3) / 4
        let blocksHigh = (storageHeight + 3) / 4
        let expectedByteCount = blocksWide * blocksHigh * dxtFormat.blockByteCount

        guard let payload = dxtPayload(in: texbData, expectedByteCount: expectedByteCount) else {
            NSLog("[TEXParser] DXT payload not found for TEXI format %d / TEXB format %d (%dx%d)", metadata.format, texbFormat, metadata.width, metadata.height)
            return nil
        }

        let paddedWidth = blocksWide * 4
        let paddedHeight = blocksHigh * 4
        let decoded: [UInt8]
        switch dxtFormat {
        case .dxt1:
            decoded = decodeDXT1(payload, width: paddedWidth, height: paddedHeight)
        case .dxt5:
            decoded = decodeDXT5(payload, width: paddedWidth, height: paddedHeight)
        }

        guard !decoded.isEmpty else { return nil }
        NSLog("[TEXParser] Decoded %@ texture %dx%d (visible %dx%d)",
              dxtFormat == .dxt1 ? "DXT1" : "DXT5",
              paddedWidth, paddedHeight, metadata.width, metadata.height)
        return makeImage(rgba: decoded, paddedWidth: paddedWidth, paddedHeight: paddedHeight, visibleWidth: Int(metadata.width), visibleHeight: Int(metadata.height))
    }

    private func inferDXTFormat(metadata: TEXMetadata) -> DXTFormat? {
        guard metadata.width > 0, metadata.height > 0 else { return nil }
        guard let texbRange = findSection("TEXB") else { return nil }

        let texbData = data[texbRange]
        let storageWidth = max(Int(metadata.width), Int(metadata.textureWidth))
        let storageHeight = max(Int(metadata.height), Int(metadata.textureHeight))
        let blocksWide = (storageWidth + 3) / 4
        let blocksHigh = (storageHeight + 3) / 4
        let dxt1Bytes = blocksWide * blocksHigh * DXTFormat.dxt1.blockByteCount
        let dxt5Bytes = blocksWide * blocksHigh * DXTFormat.dxt5.blockByteCount

        if dxtPayload(in: texbData, expectedByteCount: dxt5Bytes) != nil {
            return .dxt5
        }
        if dxtPayload(in: texbData, expectedByteCount: dxt1Bytes) != nil {
            return .dxt1
        }
        return nil
    }

    private func dxtFormat(metadataFormat: UInt32, texbFormat: Int) -> DXTFormat? {
        switch metadataFormat {
        case 4:
            return .dxt1
        case 7, 8:
            return .dxt5
        default:
            break
        }

        switch texbFormat {
        case 2:
            return .dxt5
        default:
            return nil
        }
    }

    private func dxtPayload(in texbData: Data.SubSequence, expectedByteCount: Int) -> [UInt8]? {
        guard expectedByteCount > 0, texbData.count >= expectedByteCount else { return nil }

        var candidateStarts = [Data.Index]()
        var nameEnd = texbData.startIndex
        while nameEnd < texbData.endIndex && texbData[nameEnd] != 0 {
            nameEnd += 1
        }
        if nameEnd < texbData.endIndex {
            let afterName = nameEnd + 1
            for headerBytes in stride(from: 4, through: 64, by: 4) {
                let start = afterName + headerBytes
                if start <= texbData.endIndex && texbData.endIndex - start >= expectedByteCount {
                    candidateStarts.append(start)
                }
            }
        }
        candidateStarts.append(texbData.endIndex - expectedByteCount)

        for start in candidateStarts {
            guard start >= texbData.startIndex, texbData.endIndex - start >= expectedByteCount else { continue }
            return Array(texbData[start..<start + expectedByteCount])
        }
        return nil
    }

    private func decodeDXT1(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rgba = Array(repeating: UInt8(0), count: width * height * 4)
        let blocksWide = width / 4
        let blocksHigh = height / 4

        for blockY in 0..<blocksHigh {
            for blockX in 0..<blocksWide {
                let offset = (blockY * blocksWide + blockX) * 8
                guard offset + 8 <= bytes.count else { return rgba }
                decodeColorBlock(bytes: bytes, offset: offset, rgba: &rgba, width: width, blockX: blockX, blockY: blockY, allowTransparent: true)
            }
        }
        return rgba
    }

    private func decodeDXT5(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rgba = Array(repeating: UInt8(0), count: width * height * 4)
        let blocksWide = width / 4
        let blocksHigh = height / 4

        for blockY in 0..<blocksHigh {
            for blockX in 0..<blocksWide {
                let offset = (blockY * blocksWide + blockX) * 16
                guard offset + 16 <= bytes.count else { return rgba }
                decodeColorBlock(bytes: bytes, offset: offset + 8, rgba: &rgba, width: width, blockX: blockX, blockY: blockY, allowTransparent: false)
                decodeAlphaBlock(bytes: bytes, offset: offset, rgba: &rgba, width: width, blockX: blockX, blockY: blockY)
            }
        }
        return rgba
    }

    private func decodeColorBlock(bytes: [UInt8], offset: Int, rgba: inout [UInt8], width: Int, blockX: Int, blockY: Int, allowTransparent: Bool) {
        let c0 = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        let c1 = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
        var colors = Array(repeating: [UInt8](repeating: 0, count: 4), count: 4)
        colors[0] = rgb565(c0, alpha: 255)
        colors[1] = rgb565(c1, alpha: 255)

        if c0 > c1 || !allowTransparent {
            colors[2] = interpolate(colors[0], colors[1], weightA: 2, weightB: 1, divisor: 3)
            colors[3] = interpolate(colors[0], colors[1], weightA: 1, weightB: 2, divisor: 3)
        } else {
            colors[2] = interpolate(colors[0], colors[1], weightA: 1, weightB: 1, divisor: 2)
            colors[3] = [0, 0, 0, 0]
        }

        let indices = UInt32(bytes[offset + 4])
            | (UInt32(bytes[offset + 5]) << 8)
            | (UInt32(bytes[offset + 6]) << 16)
            | (UInt32(bytes[offset + 7]) << 24)

        for y in 0..<4 {
            for x in 0..<4 {
                let colorIndex = Int((indices >> UInt32(2 * (y * 4 + x))) & 0x03)
                let pixel = ((blockY * 4 + y) * width + (blockX * 4 + x)) * 4
                rgba[pixel] = colors[colorIndex][0]
                rgba[pixel + 1] = colors[colorIndex][1]
                rgba[pixel + 2] = colors[colorIndex][2]
                rgba[pixel + 3] = colors[colorIndex][3]
            }
        }
    }

    private func decodeAlphaBlock(bytes: [UInt8], offset: Int, rgba: inout [UInt8], width: Int, blockX: Int, blockY: Int) {
        let a0 = bytes[offset]
        let a1 = bytes[offset + 1]
        var alphas = Array(repeating: UInt8(0), count: 8)
        alphas[0] = a0
        alphas[1] = a1

        if a0 > a1 {
            for i in 1...6 {
                alphas[i + 1] = UInt8((Int(7 - i) * Int(a0) + Int(i) * Int(a1)) / 7)
            }
        } else {
            for i in 1...4 {
                alphas[i + 1] = UInt8((Int(5 - i) * Int(a0) + Int(i) * Int(a1)) / 5)
            }
            alphas[6] = 0
            alphas[7] = 255
        }

        var alphaBits: UInt64 = 0
        for i in 0..<6 {
            alphaBits |= UInt64(bytes[offset + 2 + i]) << UInt64(8 * i)
        }

        for y in 0..<4 {
            for x in 0..<4 {
                let alphaIndex = Int((alphaBits >> UInt64(3 * (y * 4 + x))) & 0x07)
                let pixel = ((blockY * 4 + y) * width + (blockX * 4 + x)) * 4
                rgba[pixel + 3] = alphas[alphaIndex]
            }
        }
    }

    private func rgb565(_ color: UInt16, alpha: UInt8) -> [UInt8] {
        let r = UInt8(((Int(color >> 11) & 0x1F) * 255 + 15) / 31)
        let g = UInt8(((Int(color >> 5) & 0x3F) * 255 + 31) / 63)
        let b = UInt8((Int(color & 0x1F) * 255 + 15) / 31)
        return [r, g, b, alpha]
    }

    private func interpolate(_ a: [UInt8], _ b: [UInt8], weightA: Int, weightB: Int, divisor: Int) -> [UInt8] {
        [
            UInt8((weightA * Int(a[0]) + weightB * Int(b[0])) / divisor),
            UInt8((weightA * Int(a[1]) + weightB * Int(b[1])) / divisor),
            UInt8((weightA * Int(a[2]) + weightB * Int(b[2])) / divisor),
            UInt8((weightA * Int(a[3]) + weightB * Int(b[3])) / divisor)
        ]
    }

    private func makeImage(rgba: [UInt8], paddedWidth: Int, paddedHeight: Int, visibleWidth: Int, visibleHeight: Int) -> NSImage? {
        guard paddedWidth > 0, paddedHeight > 0, visibleWidth > 0, visibleHeight > 0 else { return nil }
        guard rgba.count >= paddedWidth * paddedHeight * 4 else {
            NSLog("[TEXParser] Decoded RGBA buffer too small: %d bytes for %dx%d", rgba.count, paddedWidth, paddedHeight)
            return nil
        }

        let outputWidth = min(visibleWidth, paddedWidth)
        let outputHeight = min(visibleHeight, paddedHeight)
        guard outputWidth > 0, outputHeight > 0 else { return nil }

        var cropped = Array(repeating: UInt8(0), count: visibleWidth * visibleHeight * 4)
        for y in 0..<outputHeight {
            let srcStart = y * paddedWidth * 4
            let dstStart = y * visibleWidth * 4
            cropped[dstStart..<dstStart + outputWidth * 4] = rgba[srcStart..<srcStart + outputWidth * 4]
        }

        let data = Data(cropped) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        guard let cgImage = CGImage(
            width: visibleWidth,
            height: visibleHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: visibleWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: CGSize(width: visibleWidth, height: visibleHeight))
    }
}
