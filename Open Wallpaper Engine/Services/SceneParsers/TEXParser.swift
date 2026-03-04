//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//  Structure: TEXV0005 > TEXI (metadata) > TEXB (image data).
//  Currently supports JPEG (format 0) extraction only.
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
    /// Returns nil if the format is unsupported (e.g. DXT).
    func extractImage() -> NSImage? {
        // Check TEXI format — format 4+ is DXT compressed (4=DXT1, 8=DXT5)
        let texiMeta = readTEXIMetadata()
        if let meta = texiMeta, meta.format >= 4 {
            NSLog("[TEXParser] TEXI format %d (DXT %dx%d), skipping image scan (%d bytes)", meta.format, meta.width, meta.height, data.count)
            return nil
        }

        // Check TEXB format — format 2+ is DXT compressed, no extractable image
        let texbFmt = readTEXBFormat()
        if texbFmt >= 2 {
            NSLog("[TEXParser] TEXB format %d (DXT), skipping image scan (%d bytes)", texbFmt, data.count)
            return nil
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
}
