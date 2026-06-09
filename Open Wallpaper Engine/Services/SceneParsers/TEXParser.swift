// TEXParser.swift — Wallpaper Engine TEXV texture container parser.
//
// Binary layout (sequential, all little-endian):
//   "TEXV000X\0"  version-tagged magic
//   "TEXI000X\0"  metadata section tag
//   format(4) flags(4) texW(4) texH(4) imgW(4) imgH(4) reserved(4)
//   "TEXB000X\0"  pixel-data section tag (version determines structure)
//   [version-specific header] [per-mipmap entries]
//
// TEXI format codes (confirmed from linux-wallpaperengine / repkg):
//   0=RGBA8888  1=RGB888  2=RGB565
//   4=DXT5(BC3) 6=DXT3(BC2) 7=DXT1(BC1)  8=RG88  9=R8  12=BC7
//
// TEXB versions:
//   0001 – unknown(4) mipmapCount(4); per mip: w h size data
//   0002 – unknown(4) mipmapCount(4); per mip: w h compFlag decompSz compSz data
//   0003 – unknown(4) freeImgFmt(4) mipmapCount(4); per mip: same as 0002
//   0004 – unknown(4) freeImgFmt(4) isVideoMp4(4) imageCount(4);
//           per image: mipmapCount(4); per mip: V4header w h compFlag decompSz compSz data
//
// LZ4 raw-block compression (compFlag==1) decompressed with Apple Compression.framework.

import Cocoa
import Foundation
import Compression

class TEXParser {

    // MARK: - Public types

    enum TextureFormat: UInt32 {
        case rgba8888 = 0, rgb888 = 1, rgb565 = 2
        case dxt5 = 4, dxt3 = 6, dxt1 = 7
        case rg88 = 8, r8 = 9, bc7 = 12
    }

    // MARK: - Init

    private let raw: [UInt8]
    private var pos = 0

    init(data: Data) { raw = [UInt8](data) }

    // MARK: - Public API

    /// Returns an NSImage for static textures, nil for video textures or unsupported formats.
    func extractImage() -> NSImage? {
        pos = 0
        if let (img, _) = parseTEXV() { return img }
        return scanForEmbeddedImage()
    }

    /// Returns raw MP4 bytes when the texture contains an embedded video (TEXB0004 isVideoMp4=1).
    func extractVideoData() -> Data? {
        pos = 0
        return parseTEXV()?.1
    }

    // MARK: - Main parse

    // Returns (image, videoData) — at most one is non-nil.
    private func parseTEXV() -> (NSImage?, Data?)? {
        pos = 0
        guard readTag("TEXV") != nil, readTag("TEXI") != nil else { return nil }

        guard let fmtRaw = readU32(), let _    = readU32(),  // flags
              let texW   = readU32(), let texH = readU32(),
              let imgW   = readU32(), let imgH = readU32(),
              let _      = readU32()                          // reserved
        else { return nil }

        let format  = TextureFormat(rawValue: fmtRaw) ?? .rgba8888
        let mipW0   = Int(imgW > 0 ? imgW : texW)
        let mipH0   = Int(imgH > 0 ? imgH : texH)

        guard let texbVerStr = readTag("TEXB") else { return nil }
        let ver = texbVersionNum(texbVerStr)

        guard let _ = readU32() else { return nil }  // common unknown

        var freeImgFmt: Int32 = -1
        var isVideoMp4 = false

        if ver >= 3 { guard let f = readI32() else { return nil }; freeImgFmt = f }
        if ver >= 4 {
            guard let vid = readU32(), let _ = readU32() else { return nil }
            isVideoMp4 = vid != 0
        }

        guard let _ = readU32() else { return nil }  // mipmapCount (we only need the first)

        if ver >= 4 { guard skipV4MipHeader() else { return nil } }

        // Use mip-level dimensions if available; fall back to header dimensions.
        let mipWidth, mipHeight: Int
        if let mw = readU32(), let mh = readU32() {
            mipWidth = Int(mw); mipHeight = Int(mh)
        } else {
            mipWidth = mipW0; mipHeight = mipH0
        }

        let payload: [UInt8]
        if ver >= 2 {
            guard let compFlag = readU32(), let decompSz = readU32(),
                  let compSz  = readU32() else { return nil }
            guard let src = readBytes(Int(compSz)) else { return nil }
            if compFlag == 1 {
                guard let dec = lz4Decompress(src, expected: Int(decompSz)) else { return nil }
                payload = dec
            } else {
                payload = src
            }
        } else {
            guard let sz = readU32(), let src = readBytes(Int(sz)) else { return nil }
            payload = src
        }

        if isVideoMp4 { return (nil, Data(payload)) }

        // FreeImage-backed (JPEG / PNG stored as-is in the mip slot)
        if ver >= 3 && freeImgFmt >= 0 {
            return (NSImage(data: Data(payload)), nil)
        }

        return (decodePixels(payload, format: format, w: mipWidth, h: mipHeight), nil)
    }

    // MARK: - Pixel decode

    private func decodePixels(_ src: [UInt8], format: TextureFormat, w: Int, h: Int) -> NSImage? {
        switch format {
        case .dxt1:    return dxt1Image(src, w: w, h: h)
        case .dxt3:    return dxt3Image(src, w: w, h: h)
        case .dxt5:    return dxt5Image(src, w: w, h: h)
        case .rgba8888: return makeNSImage(rgba: src, w: w, h: h)
        case .rgb888:
            guard src.count >= w * h * 3 else { return nil }
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                rgba[i*4] = src[i*3]; rgba[i*4+1] = src[i*3+1]; rgba[i*4+2] = src[i*3+2]
            }
            return makeNSImage(rgba: rgba, w: w, h: h)
        default:
            return NSImage(data: Data(src))
        }
    }

    // MARK: - DXT1 (BC1) — 8 bytes/block, 1-bit alpha

    private func dxt1Image(_ src: [UInt8], w: Int, h: Int) -> NSImage? {
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let bw = (w+3)/4, bh = (h+3)/4
        var off = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                guard off + 8 <= src.count else { break }
                writeColorBlock(src, off: off, rgba: &rgba, bx: bx, by: by, w: w, h: h, forceOpaque: false)
                off += 8
            }
        }
        return makeNSImage(rgba: rgba, w: w, h: h)
    }

    // MARK: - DXT3 (BC2) — 16 bytes/block, explicit 4-bit alpha

    private func dxt3Image(_ src: [UInt8], w: Int, h: Int) -> NSImage? {
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let bw = (w+3)/4, bh = (h+3)/4
        var off = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                guard off + 16 <= src.count else { break }
                writeColorBlock(src, off: off+8, rgba: &rgba, bx: bx, by: by, w: w, h: h, forceOpaque: true)
                for row in 0..<4 {
                    for col in 0..<4 {
                        let px = bx*4+col, py = by*4+row
                        guard px < w, py < h else { continue }
                        let pi = row*4+col
                        let nib = pi%2==0 ? src[off+pi/2]&0xF : src[off+pi/2]>>4
                        rgba[(py*w+px)*4+3] = UInt8(Int(nib)*255/15)
                    }
                }
                off += 16
            }
        }
        return makeNSImage(rgba: rgba, w: w, h: h)
    }

    // MARK: - DXT5 (BC3) — 16 bytes/block, interpolated alpha

    private func dxt5Image(_ src: [UInt8], w: Int, h: Int) -> NSImage? {
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let bw = (w+3)/4, bh = (h+3)/4
        var off = 0
        for by in 0..<bh {
            for bx in 0..<bw {
                guard off + 16 <= src.count else { break }
                let a0 = src[off], a1 = src[off+1]
                var aPal = [UInt8](repeating: 0, count: 8)
                aPal[0] = a0; aPal[1] = a1
                if a0 > a1 {
                    for i in 2..<8 { aPal[i] = UInt8((Int(a0)*(8-i)+Int(a1)*(i-1)+3)/7) }
                } else {
                    for i in 2..<6 { aPal[i] = UInt8((Int(a0)*(6-i)+Int(a1)*(i-1)+2)/5) }
                    aPal[6] = 0; aPal[7] = 255
                }
                // 16 alpha indices packed as 3 bits each in 6 bytes (little-endian bit stream)
                var aBits: UInt64 = 0
                for i in 0..<6 { aBits |= UInt64(src[off+2+i]) << (i*8) }

                writeColorBlock(src, off: off+8, rgba: &rgba, bx: bx, by: by, w: w, h: h, forceOpaque: true)

                for row in 0..<4 {
                    for col in 0..<4 {
                        let px = bx*4+col, py = by*4+row
                        guard px < w, py < h else { continue }
                        let aIdx = Int((aBits >> ((row*4+col)*3)) & 0x7)
                        rgba[(py*w+px)*4+3] = aPal[aIdx]
                    }
                }
                off += 16
            }
        }
        return makeNSImage(rgba: rgba, w: w, h: h)
    }

    // MARK: - Shared DXT color block writer

    private func writeColorBlock(_ src: [UInt8], off: Int, rgba: inout [UInt8],
                                 bx: Int, by: Int, w: Int, h: Int, forceOpaque: Bool) {
        let c0 = UInt16(src[off]) | UInt16(src[off+1])<<8
        let c1 = UInt16(src[off+2]) | UInt16(src[off+3])<<8
        var pal = [[UInt8]](repeating: [0,0,0,255], count: 4)
        pal[0] = rgb565(c0); pal[1] = rgb565(c1)
        if forceOpaque || c0 > c1 {
            pal[2] = blend(pal[0], pal[1], 1, 3)
            pal[3] = blend(pal[0], pal[1], 2, 3)
        } else {
            pal[2] = blend(pal[0], pal[1], 1, 2)
            pal[3] = [0, 0, 0, 0]
        }
        for row in 0..<4 {
            let ib = src[off+4+row]
            for col in 0..<4 {
                let px = bx*4+col, py = by*4+row
                guard px < w, py < h else { continue }
                let ci = Int((ib >> (col*2)) & 0x3)
                let o = (py*w+px)*4
                rgba[o] = pal[ci][0]; rgba[o+1] = pal[ci][1]
                rgba[o+2] = pal[ci][2]; rgba[o+3] = pal[ci][3]
            }
        }
    }

    private func rgb565(_ c: UInt16) -> [UInt8] {
        let r = UInt8(((c >> 11) & 0x1F) * 255 / 31)
        let g = UInt8(((c >>  5) & 0x3F) * 255 / 63)
        let b = UInt8( (c        & 0x1F) * 255 / 31)
        return [r, g, b, 255]
    }

    // Lerp: result = a*(d-n)/d + b*n/d, integer rounding
    private func blend(_ a: [UInt8], _ b: [UInt8], _ n: Int, _ d: Int) -> [UInt8] {
        let r = UInt8((Int(a[0])*(d-n) + Int(b[0])*n + d/2) / d)
        let g = UInt8((Int(a[1])*(d-n) + Int(b[1])*n + d/2) / d)
        let b_ = UInt8((Int(a[2])*(d-n) + Int(b[2])*n + d/2) / d)
        return [r, g, b_, 255]
    }

    // MARK: - LZ4 raw-block decompression

    private func lz4Decompress(_ src: [UInt8], expected: Int) -> [UInt8]? {
        guard expected > 0 else { return [] }
        var dst = [UInt8](repeating: 0, count: expected)
        let n: Int = src.withUnsafeBytes { s in
            dst.withUnsafeMutableBytes { d in
                compression_decode_buffer(
                    d.baseAddress!.assumingMemoryBound(to: UInt8.self), expected,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), src.count,
                    nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard n > 0 else { return nil }
        return n < expected ? Array(dst.prefix(n)) : dst
    }

    // MARK: - CGImage / NSImage creation

    private func makeNSImage(rgba: [UInt8], w: Int, h: Int) -> NSImage? {
        guard !rgba.isEmpty, w > 0, h > 0 else { return nil }
        guard let prov = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    // MARK: - Binary reader helpers

    private func readU32() -> UInt32? {
        guard pos+4 <= raw.count else { return nil }
        let v = UInt32(raw[pos]) | UInt32(raw[pos+1])<<8 | UInt32(raw[pos+2])<<16 | UInt32(raw[pos+3])<<24
        pos += 4; return v
    }

    private func readI32() -> Int32? { readU32().map { Int32(bitPattern: $0) } }

    private func readBytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, pos+n <= raw.count else { return nil }
        let s = Array(raw[pos..<pos+n]); pos += n; return s
    }

    /// Scan forward up to 32 bytes for "PREFIXxxxx\0"; advance past null; return version string.
    private func readTag(_ prefix: String) -> String? {
        let pb = [UInt8](prefix.utf8)
        guard pb.count > 0 else { return nil }
        let limit = min(pos + 32, raw.count - pb.count)
        while pos <= limit {
            if raw[pos..<pos+pb.count].elementsEqual(pb) {
                pos += pb.count
                var ver = ""
                while pos < raw.count { let b = raw[pos]; pos += 1; if b == 0 { break }; ver.append(Character(UnicodeScalar(b))) }
                return ver
            }
            pos += 1
        }
        return nil
    }

    private func texbVersionNum(_ s: String) -> Int { Int(s) ?? 1 }

    /// TEXB0004 per-mipmap preamble: unknown(4) unknown(4) null-term-JSON unknown(4)
    private func skipV4MipHeader() -> Bool {
        guard readU32() != nil, readU32() != nil else { return false }
        while pos < raw.count { if raw[pos] == 0 { pos += 1; break }; pos += 1 }
        return readU32() != nil
    }

    // MARK: - Fallback: scan raw bytes for embedded JPEG / PNG

    private func scanForEmbeddedImage() -> NSImage? {
        var i = 0
        while i < raw.count - 3 {
            if raw[i] == 0xFF && raw[i+1] == 0xD8 {
                if let img = NSImage(data: Data(raw[i...])) { return img }
            }
            if raw[i] == 0x89 && raw[i+1] == 0x50 && raw[i+2] == 0x4E && raw[i+3] == 0x47 {
                if let img = NSImage(data: Data(raw[i...])) { return img }
            }
            i += 1
        }
        return nil
    }
}