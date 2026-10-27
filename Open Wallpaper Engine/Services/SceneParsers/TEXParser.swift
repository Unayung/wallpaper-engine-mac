//
//  TEXParser.swift
//  Open Wallpaper Engine
//
//  Parse Wallpaper Engine TEXV texture container files.
//
//  Layout:
//    "TEXV000x\0"
//    "TEXI0001\0"  format, flags, textureWidth, textureHeight, imageWidth, imageHeight, unk
//    "TEXB000x\0"  imageCount, [freeImageFormat], mipmapCount,
//                  per mipmap: width, height, [isLZ4, decompressedSize], dataSize, bytes…
//
//  `freeImageFormat >= 0` means the mipmap payload is a complete image *file* (JPEG/PNG).
//  `-1` means raw pixels in the TEXI format, and those are usually LZ4-block compressed — except
//  when the payload is a whole MP4, which the header does not distinguish from raw pixels at all.
//  See `isISOBMFF`.
//  The previous implementation only scanned for JPEG/PNG magic bytes, so every raw texture
//  looked like an unreadable blob and got written off as "probably DXT" — which is why most
//  scene wallpapers fell back to their preview image. Raw RGBA8888 and the three BC formats
//  are all decoded here now.
//

import AVFoundation
import Cocoa
import Compression
import Foundation

/// Pixel format of the raw payload, as stored in the TEXI header.
enum TEXFormat: UInt32 {
    case rgba8888 = 0
    case r8       = 1
    case rg88     = 2
    case dxt5     = 4
    case dxt3     = 6
    case dxt1     = 7

    var isBlockCompressed: Bool {
        switch self {
        case .dxt1, .dxt3, .dxt5: return true
        default: return false
        }
    }
}

struct TEXMetadata {
    let format: UInt32
    let flags: UInt32
    let textureWidth: UInt32   // power-of-2 padded storage size
    let textureHeight: UInt32
    let width: UInt32          // the meaningful image inside that storage
    let height: UInt32
}

/// One mipmap level as it sits in the file.
private struct TEXMipmap {
    let width: Int
    let height: Int
    let isLZ4: Bool
    let decompressedSize: Int
    let payload: Data
}

class TEXParser {
    private let data: Data

    /// Whether the texture is sampled by an effect shader, which reads channels raw, or drawn as
    /// a sprite through Wallpaper Engine's image and particle shaders. The one- and
    /// two-byte-per-pixel formats mean different things to the two readers, and nothing in the
    /// file says which one it was made for.
    ///
    /// A sprite reads R8 (TEXI 9) as white with coverage `r`, and RG88 (TEXI 8) as luminance `r`
    /// with alpha `g`. R8 used to expand to opaque grey, which drew every particle whose texture
    /// is a soft dot as a hard grey square: Final Demons' dust buried its frame under hundreds of
    /// them as soon as the render harness drew particles at all, and Road Infinite's birds flew
    /// in grey boxes.
    ///
    /// An effect shader reads both raw. Masks are `.r`, which the grey expansion serves; but
    /// `waterflow`'s flow map is RG88 read as `.rg - 0.498`, a direction per pixel, and through
    /// the sprite reading the neutral texel (127, 127) came back premultiplied as (0.25, 0.25) —
    /// a flow of (-0.5, -0.5) on every pixel at once. FGO's card was smeared across its whole
    /// face the moment that pass started compiling.
    let rawChannels: Bool

    init(data: Data, rawChannels: Bool = false) {
        self.data = data
        self.rawChannels = rawChannels
    }

    // MARK: - Public API

    /// Extract the image from this TEX container, or nil if nothing decodable is in it.
    ///
    /// For a sprite-sheet texture — one carrying a TEXS frame table, see `spriteFrames` — this is
    /// frame 0 alone, not the sheet. Every call site (image layers, particle emitters, effect
    /// textures) wants "what this texture looks like", and for an atlas that is one frame.
    ///
    /// Handing them the whole sheet instead is what this used to do, and it is not a subtle
    /// failure. 99 of the library's 1506 textures are atlases, and they are mostly the shared
    /// particle presets: `fog1` is 64 frames of 128×128 in a 1024×1024 sheet, `leaves3` 30
    /// frames, `debris1` 8 in a strip, `fire1` 64. 199 of the 493 particle systems in 45 scenes
    /// sample one, so `SKEmitterNode` stamped an 8×8 grid of miniature smoke puffs into every
    /// fog particle, every rock of a debris burst became a row of eight rocks, and a leaf —
    /// one frame of thirty, mostly transparent sheet around it — shrank to a speck you could
    /// not see. 70 image layers in 10 scenes sit on a sheet too — the Samurai walk cycle, a
    /// converted GIF, showed a strip of tiny figures instead of one, and a music player's pause
    /// button was both of its states squeezed into one square. A still frame 0 is the honest
    /// reduction for all of these; an image layer whose sheet is a real animation plays it
    /// through `extractFrames()` (see `SceneWallpaperViewModel.scriptedTextureAnimations` for
    /// which ones are).
    func extractImage() -> NSImage? {
        guard let atlas = extractAtlas() else { return nil }
        guard let frame = spriteFrames.first else { return atlas }
        guard let cg = atlas.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cut = cg.cropping(to: frame)
        else {
            TEXParser.log("sprite frame \(frame) does not fit the \(atlas.size) atlas; using the sheet")
            return atlas
        }
        return NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
    }

    /// The frames of a sprite-sheet texture, in pixels of the image `extractAtlas()` returns
    /// (TEXI image space, top-left origin, already inside the power-of-two crop). Empty for a
    /// texture that is not a sheet — which is 1407 of 1506 — or whose frame table does not
    /// parse cleanly, in which case the texture behaves exactly as it did before TEXS existed
    /// here.
    ///
    /// The table is the TEXS block, which follows the last mipmap of the last image:
    ///
    ///     "TEXS0002\0"  frameCount, per frame: imageId, frameTime, x, y, widthX, widthY, heightX, heightY
    ///     "TEXS0003\0"  frameCount, sheetFrameWidth, sheetFrameHeight, then the same frames
    ///
    /// `imageId` is a u32 and every other field a float32 — integers are the only thing a
    /// TEXS0002 sheet ever holds, but read as u32 they come out as 1124073472 (128.0f). The
    /// width and height are *vectors*, room for a rotated frame; none in the library is, and one
    /// that were would not be an axis-aligned crop, so it declines the table. Checked against
    /// the authored `.tex-json` `spritesheetsequences` beside the shared presets: debris1 8 ×
    /// 128×128 in 1024×128, fog1 64 × 128×128 in 1024×1024, leaves3 30 × 85.334×102.4 in
    /// 512×512. That last is why rects are rounded, and why this list can be shorter than the
    /// frame count the file declares — see `readSpriteFrames`.
    private(set) lazy var spriteFrames: [CGRect] = spriteTable.frames

    /// `spriteFrames`, with each frame's display time in seconds and whether the table came
    /// through whole. Read once; `spriteFrames` is the half every still reading needs.
    private lazy var spriteTable: (frames: [CGRect], durations: [Double], whole: Bool) = readSpriteFrames()

    /// The frames of a sprite sheet cut out as separate images, each with how long it shows, for
    /// a layer that plays the sheet. Empty unless there are at least two frames *and* the table
    /// came through whole: 13 of the library's 99 tables carry frames that fall outside their
    /// image (see `readSpriteFrames`), and from that point on their rects point at the wrong
    /// cells of the artwork, so playing them would cycle through misaligned crops. Those keep
    /// their still frame 0.
    ///
    /// Separate images rather than sub-rectangles of one atlas texture, because every shader on
    /// a layer — the tint, the translated effect passes — reads `v_tex_coord` as 0…1 over the
    /// layer, and an `SKTexture(rect:in:)` hands it the frame's coordinates inside the sheet.
    ///
    /// A frame time that is not positive falls back to 1/30 s — the rate upstream
    /// (Unayung/wallpaper-engine-mac 0.9.0, which first played these) settled on for the same case —
    /// and none is shorter than 1/240 s, because the scene steps through frames in a loop and a
    /// frame time near zero would spin it millions of times a tick.
    func extractFrames() -> [(image: NSImage, duration: Double)] {
        let table = spriteTable
        guard table.whole, table.frames.count > 1,
              let atlas = extractAtlas(),
              let cg = atlas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        var out: [(image: NSImage, duration: Double)] = []
        out.reserveCapacity(table.frames.count)
        for (rect, duration) in zip(table.frames, table.durations) {
            guard let cut = cg.cropping(to: rect) else { return [] }
            out.append((NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height)),
                        duration > 0 && duration.isFinite ? max(duration, 1.0 / 240.0) : 1.0 / 30.0))
        }
        return out
    }

    /// The whole decoded texture, frames and all — what `extractImage()` returned before sprite
    /// sheets were understood. Kept for an animated reading of `spriteFrames`.
    func extractAtlas() -> NSImage? {
        guard let (meta, mip) = readHeader() else {
            // Not a TEXV container we understand. Fall back to the old magic-byte scan, which
            // still rescues the occasional oddly-laid-out file.
            if let scanned = scanForEmbeddedImage(), let image = NSImage(data: scanned) {
                return image
            }
            TEXParser.log("header parse failed (\(data.count) bytes)")
            return nil
        }

        guard TEXParser.withinDecodeLimits(mip), let payload = decompressIfNeeded(mip) else {
            return nil
        }

        // Wallpaper Engine also stores *video* inside a .tex: mip 0 is a complete MP4 file. No
        // field in the header admits it — TEXI still reports format 0 (rgba8888) and TEXB still
        // reports freeImageFormat -1 ("raw pixels") — so the payload has to be sniffed.
        //
        // This must be tested before the raw path and must return unconditionally, even when no
        // frame can be decoded, because the raw path does not *fail* on a video. It divides the
        // payload by the pixel count and hands whatever whole number falls out to `expandRaw`.
        // Valley's fog layer is 2,525,158 bytes over 1920×1080 — exactly 1 byte per pixel — so
        // its H.264 bitstream was read as an 8-bit coverage mask and drawn as grey static across
        // the entire wallpaper, and Hacker Apartment's 4K skyline divided out to 3 and came back
        // as RGB static. Failing silently would be bad; producing *convincing* noise is worse,
        // because a wallpaper full of static reads as a mis-composed scene and sends you looking
        // for the bug in the compositor.
        //
        // Seven textures across four scenes in the installed library do this. Every one of them
        // also carries bit 0x20 in the TEXI flags and no other texture out of 1195 does, so that
        // flag would work too — but the payload signature is what is checked, because a payload
        // cannot be wrong about what it is.
        if TEXParser.isISOBMFF(payload) {
            guard let frame = TEXParser.firstVideoFrame(payload) else {
                TEXParser.log("video payload, no decodable frame (\(payload.count) bytes, \(mip.width)x\(mip.height))")
                return nil
            }
            // No crop: a video is not stored padded to a power of two, and all seven decode at
            // exactly their TEXI dimensions, so there is no margin to trim.
            return frame
        }

        // A payload that is itself an image file wins regardless of what the header claimed;
        // some wallpapers set freeImageFormat inconsistently.
        if let image = imageFromEncodedFile(payload) {
            return cropped(image, meta: meta)
        }

        var pixelWidth = mip.width
        var pixelHeight = mip.height
        let format = TEXFormat(rawValue: meta.format)
        var rgba: Data

        if let format, format.isBlockCompressed {
            // Block formats round the stored size up to a multiple of 4 in both axes.
            pixelWidth = (pixelWidth + 3) & ~3
            pixelHeight = (pixelHeight + 3) & ~3
            guard let decoded = TEXParser.decodeBlockCompressed(
                payload, width: pixelWidth, height: pixelHeight, format: format)
            else { return nil }
            rgba = Data(decoded)
        } else {
            // Raw interleaved pixels. The channel count is derived from the payload rather than
            // from a format table: Workshop content uses TEXI values well outside the documented
            // set (8 is two bytes per pixel, 9 is one — both are effect masks), and every one of
            // them is a plain buffer. Measuring is both simpler and future-proof.
            let pixelCount = pixelWidth * pixelHeight
            let payloadCount = payload.count
            guard pixelCount > 0, payloadCount / pixelCount > 0 else {
                TEXParser.log("raw payload too small: \(payloadCount) for \(pixelWidth)x\(pixelHeight) (TEXI \(meta.format))")
                return nil
            }
            // Consumed, so that at 4 B/px — where `expandRaw` hands back the payload itself —
            // the buffer `makeCGImage` premultiplies is uniquely owned and changed in place,
            // instead of being copied on the first write.
            guard let expanded = TEXParser.expandRaw(consume payload, pixelCount: pixelCount,
                                                     bytesPerPixel: payloadCount / pixelCount,
                                                     rawChannels: rawChannels)
            else {
                TEXParser.log("unsupported raw layout: \(payloadCount / pixelCount) B/px (TEXI \(meta.format))")
                return nil
            }
            rgba = expanded
        }

        let rgbaCount = rgba.count
        guard let cgImage = TEXParser.makeCGImage(rgba: &rgba, width: pixelWidth, height: pixelHeight)
        else {
            TEXParser.log("CGImage creation failed \(pixelWidth)x\(pixelHeight), \(rgbaCount) bytes")
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
        return cropped(image, meta: meta)
    }

    /// Extract raw JPEG/PNG data without creating NSImage.
    func extractImageData() -> Data? {
        if let (_, mip) = readHeader() {
            guard TEXParser.withinDecodeLimits(mip) else { return nil }
            if let payload = decompressIfNeeded(mip) {
                if isEncodedImageFile(payload) { return payload }
                // A video payload has no image file in it, and letting it reach the magic-byte
                // scan below would find `FF D8 FF` somewhere in the H.264 bitstream by chance
                // and return the tail of a video as a JPEG.
                if TEXParser.isISOBMFF(payload) { return nil }
            }
        }
        return scanForEmbeddedImage()
    }

    // MARK: - Header

    /// Sequential cursor over the container. Kept as an explicit value rather than closures over
    /// a captured index: the parse has to rewind and retry alternative layouts, and mixing a
    /// captured `var` with `inout` aliases the same storage and silently loses the reads.
    private struct ByteReader {
        let data: Data
        var cursor: Data.Index

        init(_ data: Data) {
            self.data = data
            self.cursor = data.startIndex
        }

        mutating func cString() -> String? {
            var end = cursor
            while end < data.endIndex && data[end] != 0 { end += 1 }
            guard end < data.endIndex else { return nil }
            let s = String(bytes: data[cursor..<end], encoding: .ascii)
            cursor = end + 1
            return s
        }

        mutating func u32() -> UInt32? {
            guard cursor + 4 <= data.endIndex else { return nil }
            let v = UInt32(data[cursor]) | (UInt32(data[cursor + 1]) << 8)
                | (UInt32(data[cursor + 2]) << 16) | (UInt32(data[cursor + 3]) << 24)
            cursor += 4
            return v
        }

        mutating func f32s(_ n: Int) -> [CGFloat]? {
            var out: [CGFloat] = []
            for _ in 0..<n {
                guard let bits = u32() else { return nil }
                out.append(CGFloat(Float(bitPattern: bits)))
            }
            return out
        }

        func slice(count: Int) -> Data? {
            guard count > 0, cursor + count <= data.endIndex else { return nil }
            return data[cursor..<(cursor + count)]
        }
    }

    /// Parse TEXV → TEXI → TEXB down to mipmap 0. Returns nil if this is not a TEX container.
    private func readHeader() -> (TEXMetadata, TEXMipmap)? {
        var reader = ByteReader(data)

        guard let container = reader.cString(), container.hasPrefix("TEXV"),
              let texiName = reader.cString(), texiName.hasPrefix("TEXI"),
              let format = reader.u32(), let flags = reader.u32(),
              let texW = reader.u32(), let texH = reader.u32(),
              let imgW = reader.u32(), let imgH = reader.u32(),
              reader.u32() != nil,                       // trailing unknown field
              let texbName = reader.cString(), texbName.hasPrefix("TEXB")
        else { return nil }

        let meta = TEXMetadata(format: format, flags: flags,
                               textureWidth: texW, textureHeight: texH,
                               width: imgW, height: imgH)
        let texbStart = reader.cursor

        // The TEXB header grew field by field across revisions: 0002 added the LZ4 pair, 0003 the
        // freeImageFormat, 0004 one more word before the mipmap count. Rather than trust the
        // revision string — Workshop content does not always match it — every known shape is
        // tried and the one whose numbers actually describe the payload wins.
        var preferred = TEXParser.layoutCandidates
        if let hint = TEXParser.layoutHint(for: texbName),
           let at = preferred.firstIndex(of: hint) {
            preferred.remove(at: at)
            preferred.insert(hint, at: 0)
        }

        var firstParsable: (TEXMipmap, TEXBLayout)?
        for layout in preferred {
            reader.cursor = texbStart
            guard let mip = readMipmapZero(&reader, layout: layout) else { continue }
            // A layout can parse by luck; one whose decompressed size matches the pixel count
            // for some channel width (or a block-compressed size) is the real one.
            if TEXParser.sizeIsConsistent(mip, format: TEXFormat(rawValue: format)) {
                chosenLayout = (texbStart, layout)
                return (meta, mip)
            }
            if firstParsable == nil { firstParsable = (mip, layout) }
        }

        if let (mip, layout) = firstParsable {
            chosenLayout = (texbStart, layout)
            return (meta, mip)
        }
        TEXParser.log("no TEXB layout fits: \(texbName) TEXI=\(format) \(texW)x\(texH) img=\(imgW)x\(imgH) bytes=\(data.count)")
        return nil
    }

    /// Where the TEXB header starts and which shape `readHeader` settled on — the only way to
    /// find the end of the image data, and so the TEXS block after it.
    private var chosenLayout: (start: Data.Index, layout: TEXBLayout)?

    // MARK: - Sprite-sheet frames (TEXS)

    /// Walk every mipmap of every image under the layout `readHeader` chose, then read the TEXS
    /// frame table that follows. Any doubt at all returns no frames, which leaves the texture
    /// exactly as it decoded before this existed: a frame table read wrong would crop a normal
    /// texture down to a random rectangle, which is far worse than an atlas.
    ///
    /// The walk is used rather than a search for the "TEXS" magic because the payload before it
    /// is arbitrary bytes — a megabyte-scale search on every texture to defend against a chance
    /// match is the wrong trade when the container says exactly where the table is. What the
    /// walk lands on is then held to two checks the library passes 99 of 99: the block must end
    /// exactly at end of file, and every frame must sit inside the image.
    private func readSpriteFrames() -> (frames: [CGRect], durations: [Double], whole: Bool) {
        let none: (frames: [CGRect], durations: [Double], whole: Bool) = ([], [], false)
        guard let (meta, _) = readHeader(), let (start, layout) = chosenLayout else { return none }
        var reader = ByteReader(data)
        reader.cursor = start

        guard let imageCount = reader.u32(), (1...4096).contains(imageCount) else { return none }
        if layout.hasFreeImageFormat { guard reader.u32() != nil else { return none } }
        for _ in 0..<layout.extraFields { guard reader.u32() != nil else { return none } }
        for _ in 0..<imageCount {
            guard let mipCount = reader.u32(), (1...24).contains(mipCount) else { return none }
            for _ in 0..<mipCount {
                guard reader.u32() != nil, reader.u32() != nil else { return none }   // width, height
                if layout.hasLZ4 {
                    guard reader.u32() != nil, reader.u32() != nil else { return none }
                }
                guard let size = reader.u32(), reader.cursor + Int(size) <= data.endIndex
                else { return none }
                reader.cursor += Int(size)
            }
        }

        // No table at all is the common case — 1407 of 1506 textures end right here.
        guard reader.cursor < data.endIndex,
              let version = reader.cString(), version.hasPrefix("TEXS"),
              let count = reader.u32(), (1...65536).contains(count)
        else { return none }

        switch version {
        case "TEXS0002":
            break
        case "TEXS0003":
            // The nominal frame size, a rounded copy of what every frame below says.
            guard reader.u32() != nil, reader.u32() != nil else { return none }
        default:
            // TEXS0001 is said to hold integer rects; none is installed to check that against,
            // so rather than guess at a layout it is declined.
            TEXParser.log("unrecognised sprite table \(version); using the whole sheet")
            return none
        }

        guard data.endIndex - reader.cursor == Int(count) * 32 else {
            TEXParser.log("\(version) with \(count) frames does not end the file; using the whole sheet")
            return none
        }

        let imageW = CGFloat(meta.width), imageH = CGFloat(meta.height)
        var frames: [CGRect] = []
        var durations: [Double] = []
        var whole = true
        frames.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let id = reader.u32(), let fields = reader.f32s(7) else { return none }
            let (x, y, wx, wy, hx, hy) = (fields[1], fields[2], fields[3], fields[4], fields[5], fields[6])
            guard id == 0, wy == 0, hx == 0, wx > 0, hy > 0, x >= 0, y >= 0 else {
                TEXParser.log("\(version) frame \(index) is not an unrotated rect in image 0; using the whole sheet")
                return none
            }
            // Round both edges rather than origin and size, so adjacent frames share their
            // boundary instead of drifting a pixel apart across a row of fractional cells
            // (85.334-wide leaves, 170.667-wide jellyfish), and clamp to the image.
            let x0 = x.rounded(), y0 = y.rounded()
            let x1 = min((x + wx).rounded(), imageW), y1 = min((y + hy).rounded(), imageH)
            guard x1 > x0, y1 > y0 else {
                // A frame wholly outside the image. Wallpaper Engine's own sheet generator writes
                // these, in 13 of the 99 sheets — every stock `leaves1`–`leaves10`, `bubble1`,
                // `jellyfish1` and `rosepetals` — and the cause is visible in the numbers. The
                // leaves' artwork is a 6×5 grid of 512/6 × 512/5 cells, but the cell width was
                // stored rounded *up*, as 85.334, and 512 / 85.334 floors to 5 columns. So the
                // table walks the same 30 cells five to a row, and its sixth row lands at
                // y = 512, past the bottom edge (frames 25–29). jellyfish1 is the same with
                // 170.6667 in 1024 (frames 30–35), rosepetals with 102.5 in 512 (frame 4).
                // There is nothing there to crop, so the frame is dropped. That is safe for the
                // still image, which only reads frame 0, and frame 0 is the one cell where the
                // table and the artwork agree. Declining the whole table instead would hand the
                // leaves straight back to the atlas, which is the bug this exists to fix. For
                // the same reason frame 0 itself is never allowed to go, or `first` would
                // silently become another frame.
                //
                // An animated reading must not trust these 13 tables past frame 0: from frame 5
                // on, the leaves' rects point at the wrong cells of the artwork.
                guard index > 0 else {
                    TEXParser.log("\(version) frame 0 lies outside the \(meta.width)x\(meta.height) image; using the whole sheet")
                    return none
                }
                whole = false
                continue
            }
            frames.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            durations.append(Double(fields[0]))
        }
        return (frames, durations, whole)
    }

    /// Shape of the TEXB header for one container revision.
    private struct TEXBLayout: Equatable {
        let hasFreeImageFormat: Bool
        /// Extra words between `freeImageFormat` and `mipmapCount` (TEXB0004 added one).
        let extraFields: Int
        let hasLZ4: Bool
    }

    private static let layoutCandidates: [TEXBLayout] = [
        TEXBLayout(hasFreeImageFormat: true,  extraFields: 1, hasLZ4: true),   // TEXB0004
        TEXBLayout(hasFreeImageFormat: true,  extraFields: 0, hasLZ4: true),   // TEXB0003
        TEXBLayout(hasFreeImageFormat: false, extraFields: 0, hasLZ4: true),   // TEXB0002
        TEXBLayout(hasFreeImageFormat: false, extraFields: 0, hasLZ4: false),  // TEXB0001
        TEXBLayout(hasFreeImageFormat: true,  extraFields: 0, hasLZ4: false),
    ]

    private static func layoutHint(for texbName: String) -> TEXBLayout? {
        switch texbName {
        case let n where n >= "TEXB0004": return layoutCandidates[0]
        case "TEXB0003":                  return layoutCandidates[1]
        case "TEXB0002":                  return layoutCandidates[2]
        case "TEXB0001":                  return layoutCandidates[3]
        default:                          return nil
        }
    }

    /// Does the declared decompressed size actually describe this mipmap?
    private static func sizeIsConsistent(_ mip: TEXMipmap, format: TEXFormat?) -> Bool {
        guard mip.isLZ4 else { return true }   // nothing to cross-check against
        let pixels = mip.width * mip.height
        guard pixels > 0 else { return false }

        if let format, format.isBlockCompressed {
            let blocks = ((mip.width + 3) / 4) * ((mip.height + 3) / 4)
            return mip.decompressedSize == blocks * (format == .dxt1 ? 8 : 16)
        }
        return (1...4).contains(mip.decompressedSize / pixels)
            && mip.decompressedSize % pixels == 0
    }

    /// Read as far as mipmap 0's payload under one candidate layout, rejecting implausible values.
    private func readMipmapZero(_ reader: inout ByteReader, layout: TEXBLayout) -> TEXMipmap? {
        guard reader.u32() != nil else { return nil }                 // imageCount
        if layout.hasFreeImageFormat { guard reader.u32() != nil else { return nil } }
        for _ in 0..<layout.extraFields { guard reader.u32() != nil else { return nil } }

        guard let mipCount = reader.u32(), (1...24).contains(mipCount),
              let w = reader.u32(), (1...32768).contains(w),
              let h = reader.u32(), (1...32768).contains(h)
        else { return nil }

        var isLZ4 = false
        var decompressedSize = 0
        if layout.hasLZ4 {
            guard let lz4Flag = reader.u32(), lz4Flag <= 1,
                  let dec = reader.u32(), dec <= 512 * 1024 * 1024
            else { return nil }
            isLZ4 = lz4Flag == 1
            decompressedSize = Int(dec)
            if isLZ4 && decompressedSize == 0 { return nil }
        }

        guard let size = reader.u32(), size > 0,
              let payload = reader.slice(count: Int(size))
        else { return nil }

        return TEXMipmap(width: Int(w), height: Int(h), isLZ4: isLZ4,
                         decompressedSize: decompressedSize, payload: payload)
    }

    // MARK: - Payload

    /// The most texels mipmap 0 may declare: 8192 × 8192.
    ///
    /// The header's own bounds — 32768 a side, 512 MiB decompressed — are what a parse will
    /// tolerate, not what anything should allocate, and the file is Workshop content: a 1 MB
    /// crafted LZ4 texture declaring 16384 × 16384 at one byte a texel drove this decoder to a
    /// 4.8 GB peak footprint in 1.8 s, since the decompressed buffer, its expansion to RGBA and
    /// the premultiplied copies all existed at once. It is now refused in a millisecond, at 3 MB. The largest textures in the installed library (1508 of them, shared
    /// assets included) are 8192 × 4096 — Girl, Space Invaders, Mario Bros, Three-Body's B8k —
    /// so this is twice the largest real one, and caps the RGBA buffer at 256 MiB.
    static let maxTexels = 8192 * 8192

    /// LZ4 cannot expand a block by more than this: a match's length is extended a byte at a
    /// time, 255 output bytes per input byte at best. The library's most compressible textures
    /// (flat masks) reach 254.8, against the bound, and nothing real can exceed it — so a header
    /// claiming more is lying about the payload, and believing it allocates the claim.
    private static let maxLZ4Ratio = 255

    /// Whether mipmap 0 is small enough to decode at all. Checked before anything is allocated.
    private static func withinDecodeLimits(_ mip: TEXMipmap) -> Bool {
        let texels = mip.width * mip.height
        guard texels <= maxTexels else {
            NSLog("[TEXParser] rejected: \(mip.width)x\(mip.height) is over the \(maxTexels)-texel cap")
            return false
        }
        // The slack covers a block too short for the ratio to apply — a single sequence still
        // writes a match of up to 19 bytes from 3.
        if mip.isLZ4, mip.decompressedSize > maxLZ4Ratio * mip.payload.count + 64 {
            NSLog("[TEXParser] rejected: LZ4 claims \(mip.decompressedSize) bytes from \(mip.payload.count), past the format's \(maxLZ4Ratio)x")
            return false
        }
        // Four bytes a texel is the widest layout anything here decodes.
        if mip.isLZ4, mip.decompressedSize > maxTexels * 4 {
            NSLog("[TEXParser] rejected: LZ4 claims \(mip.decompressedSize) bytes, over the \(maxTexels * 4)-byte cap")
            return false
        }
        return true
    }

    private func decompressIfNeeded(_ mip: TEXMipmap) -> Data? {
        guard mip.isLZ4 else { return mip.payload }
        guard let out = TEXParser.lz4Decode(mip.payload, expectedSize: mip.decompressedSize) else {
            TEXParser.log("LZ4 decode failed (\(mip.payload.count) -> \(mip.decompressedSize))")
            return nil
        }
        return out
    }

    /// Decode a raw LZ4 *block* (no frame header). Tries the system implementation first and
    /// falls back to a literal reading of the block format, which some Workshop files need
    /// because their final sequence is not the well-formed one `libcompression` insists on.
    static func lz4Decode(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, !input.isEmpty else { return nil }

        // Decoded straight into the `Data` that is returned, and read straight out of the
        // caller's, which is usually a slice of the mapped .pkg. Both used to be copied through
        // a `[UInt8]` on the way, so an 8192 × 4096 texture held its 128 MiB of pixels twice
        // before anything had been done with them.
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          s.bindMemory(to: UInt8.self).baseAddress!, s.count,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        if written == expectedSize { return dst }

        return manualLZ4Decode([UInt8](input), expectedSize: expectedSize)
    }

    private static func manualLZ4Decode(_ src: [UInt8], expectedSize: Int) -> Data? {
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        var i = 0

        while i < src.count {
            let token = Int(src[i]); i += 1

            var literalCount = token >> 4
            if literalCount == 15 {
                while i < src.count {
                    let b = Int(src[i]); i += 1
                    literalCount += b
                    if b != 255 { break }
                }
            }
            guard i + literalCount <= src.count else { break }
            if literalCount > 0 {
                out.append(contentsOf: src[i..<(i + literalCount)])
                i += literalCount
            }

            // The last sequence of a block is literals only.
            guard i + 2 <= src.count else { break }
            let offset = Int(src[i]) | (Int(src[i + 1]) << 8); i += 2
            guard offset > 0, offset <= out.count else { return nil }

            var matchLength = token & 0x0F
            if matchLength == 15 {
                while i < src.count {
                    let b = Int(src[i]); i += 1
                    matchLength += b
                    if b != 255 { break }
                }
            }
            matchLength += 4

            // Matches may overlap themselves, so this has to copy byte by byte.
            var start = out.count - offset
            for _ in 0..<matchLength {
                out.append(out[start])
                start += 1
            }
            if out.count >= expectedSize { break }
        }

        guard out.count >= expectedSize else { return nil }
        return Data(out.prefix(expectedSize))
    }

    // MARK: - Image construction

    private func imageFromEncodedFile(_ payload: Data) -> NSImage? {
        guard isEncodedImageFile(payload) else { return nil }
        return NSImage(data: payload)
    }

    /// Is this payload an ISO base media file (MP4/MOV)?
    ///
    /// The signature is the `ftyp` box *type*, at bytes 4–7; bytes 0–3 are that box's length, so
    /// unlike JPEG or PNG there is nothing constant at offset zero to key on. Every video in the
    /// library opens with `ftyp` as its first box, which is what the specification requires.
    static func isISOBMFF(_ d: Data) -> Bool {
        guard d.count >= 12 else { return false }
        let b = [UInt8](d.prefix(8))
        return b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70   // "ftyp"
    }

    /// Decode the first frame of an MP4 payload into a still image.
    ///
    /// AVFoundation will not read a video out of memory: `AVURLAsset` wants a URL, and the only
    /// in-memory alternative — an `AVAssetResourceLoader` delegate serving the bytes — is a lot
    /// of machinery for something that runs once per texture at load time. So the payload goes to
    /// a temporary file, and that file *must* carry a `.mp4` extension: AVFoundation types a file
    /// URL by its path extension, and an extensionless one comes back with an empty track list
    /// and no error to explain it.
    ///
    /// Cost, measured over the library's seven video textures: 13–50 ms each including the write,
    /// with no relation to payload size — the 27 MB 4K skyline takes 50 ms and the 2.5 MB 1080p
    /// fog takes 44 ms, because what is being paid for is opening a decoder, not moving bytes.
    /// The first call in a process pays roughly another 150 ms of one-off codec warm-up. All of
    /// it is load-time cost; nothing here runs per frame.
    static func firstVideoFrame(_ mp4: Data) -> NSImage? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wetexvideo-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try mp4.write(to: tmp, options: .atomic)
        } catch {
            log("could not stage video payload: \(error.localizedDescription)")
            return nil
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
        // Several of these videos were exported from phone footage and carry a rotation matrix;
        // without this the frame comes back on its side.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // `copyCGImage` is the obvious synchronous call, and it is deprecated from macOS 15. The
        // callback form is not, and it does complete while the calling thread sits on a
        // semaphore — checked on the main thread, which is the case that would deadlock if image
        // generation needed it. The wait is bounded so that a truncated or malformed Workshop
        // video cannot hang a wallpaper load outright.
        let done = DispatchSemaphore(value: 0)
        var frame: CGImage?
        var failure: String?
        generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
            frame = image
            failure = error?.localizedDescription
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            log("video frame timed out (\(mp4.count) bytes)")
            return nil
        }
        guard let frame else {
            log("video frame failed: \(failure ?? "no image, no error")")
            return nil
        }

        return NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    private func isEncodedImageFile(_ d: Data) -> Bool {
        guard d.count >= 4 else { return false }
        let b = [UInt8](d.prefix(4))
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return true }           // JPEG
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return true }  // PNG
        return false
    }

    /// Widen an interleaved raw buffer to RGBA8888.
    ///
    /// One byte per pixel is a coverage mask, two is luminance + alpha; both are used heavily by
    /// scene effects. Anything wider than four channels is not something this parser models.
    ///
    /// At four bytes a pixel the payload already *is* the image, and it is handed back as it is
    /// — a slice sharing its storage, not a copy. Narrower layouts are read in place.
    static func expandRaw(_ payload: Data, pixelCount: Int, bytesPerPixel: Int,
                          rawChannels: Bool = false) -> Data? {
        guard (1...4).contains(bytesPerPixel), payload.count >= pixelCount * bytesPerPixel
        else { return nil }
        if bytesPerPixel == 4 {
            return payload.prefix(pixelCount * 4)
        }

        var out = Data(repeating: 255, count: pixelCount * 4)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (rawOut: UnsafeMutableRawBufferPointer) in
                let src = raw.bindMemory(to: UInt8.self)
                let out = rawOut.bindMemory(to: UInt8.self)
                for i in 0..<pixelCount {
                    let s = i * bytesPerPixel, d = i * 4
                    switch bytesPerPixel {
                    case 1 where rawChannels:
                        out[d] = src[s]; out[d + 1] = src[s]; out[d + 2] = src[s]
                    case 1:
                        // White, coverage in alpha (straight; `makeCGImage` premultiplies it).
                        out[d + 3] = src[s]
                    case 2 where rawChannels:
                        out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = 0
                    case 2:
                        out[d] = src[s]; out[d + 1] = src[s]; out[d + 2] = src[s]
                        out[d + 3] = src[s + 1]
                    default:
                        out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]
                    }
                }
            }
        }
        return out
    }

    /// Wrap straight-alpha RGBA bytes in a CGImage.
    ///
    /// CoreGraphics will not render non-premultiplied alpha, so the pixels are premultiplied
    /// here — but only when they actually look straight. A channel value above its own alpha is
    /// impossible in premultiplied data, so it is a reliable tell, and it stops already
    /// premultiplied textures from being darkened a second time.
    ///
    /// `rgba` is premultiplied in place and then becomes the image's own backing store, so a
    /// caller that owns it uniquely pays for no copy at all. It used to be copied twice here —
    /// once on the first write, once more into the `Data` behind the provider. Together with the
    /// copies `lz4Decode` and `expandRaw` no longer make, decoding Girl's 8192 × 4096 texture
    /// (4 B/px, LZ4) went from a 566 MB peak footprint to 197 MB, and Three-Body's B8k (1 B/px)
    /// from 673 to 476, with every one of the library's 1508 textures decoding to the same pixels.
    static func makeCGImage(rgba: inout Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }

        // Only whole pixels, as the old index loop read them.
        let count = rgba.count & ~3
        let looksStraight = rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let pixels = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < count {
                let a = pixels[i + 3]
                if a < 255 && (pixels[i] > a || pixels[i + 1] > a || pixels[i + 2] > a) {
                    return true
                }
                i += 4
            }
            return false
        }

        if looksStraight {
            rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                let pixels = raw.bindMemory(to: UInt8.self)
                var i = 0
                while i < count {
                    let a = UInt16(pixels[i + 3])
                    if a != 255 {
                        pixels[i]     = UInt8(UInt16(pixels[i]) * a / 255)
                        pixels[i + 1] = UInt8(UInt16(pixels[i + 1]) * a / 255)
                        pixels[i + 2] = UInt8(UInt16(pixels[i + 2]) * a / 255)
                    }
                    i += 4
                }
            }
        }

        guard let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue:
                        CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Textures are stored padded to a power of two; the meaningful image sits in the top-left.
    /// Handing the padded bitmap to SpriteKit would both stretch the sprite and surface the
    /// empty margin, so trim it back to the TEXI dimensions.
    private func cropped(_ image: NSImage, meta: TEXMetadata) -> NSImage {
        let w = Int(meta.width), h = Int(meta.height)
        guard w > 0, h > 0 else { return image }

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > w || cg.height > h,
              w <= cg.width, h <= cg.height,
              let cut = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))
        else { return image }

        return NSImage(cgImage: cut, size: NSSize(width: w, height: h))
    }

    // MARK: - Block compression (BC1/BC2/BC3)

    /// Decode DXT1/DXT3/DXT5 to straight-alpha RGBA8888.
    static func decodeBlockCompressed(_ data: Data, width: Int, height: Int,
                                      format: TEXFormat) -> [UInt8]? {
        let blockBytes = format == .dxt1 ? 8 : 16
        let blocksWide = (width + 3) / 4
        let blocksHigh = (height + 3) / 4
        guard data.count >= blocksWide * blocksHigh * blockBytes else {
            log("BC payload too small: \(data.count) < \(blocksWide * blocksHigh * blockBytes)")
            return nil
        }

        let src = [UInt8](data)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        for by in 0..<blocksHigh {
            for bx in 0..<blocksWide {
                let base = (by * blocksWide + bx) * blockBytes
                var alpha = [UInt8](repeating: 255, count: 16)
                var colorOffset = base

                switch format {
                case .dxt3:
                    for i in 0..<8 {
                        let byte = src[base + i]
                        // 4 bits per pixel, expanded to 8.
                        alpha[i * 2]     = (byte & 0x0F) * 17
                        alpha[i * 2 + 1] = (byte >> 4) * 17
                    }
                    colorOffset = base + 8

                case .dxt5:
                    let a0 = src[base], a1 = src[base + 1]
                    var table = [UInt8](repeating: 0, count: 8)
                    table[0] = a0
                    table[1] = a1
                    if a0 > a1 {
                        for i in 1...5 {
                            table[i + 1] = UInt8((Int(a0) * (6 - i) + Int(a1) * i) / 7)
                        }
                    } else {
                        for i in 1...3 {
                            table[i + 1] = UInt8((Int(a0) * (4 - i) + Int(a1) * i) / 5)
                        }
                        table[6] = 0
                        table[7] = 255
                    }
                    var bits: UInt64 = 0
                    for i in 0..<6 { bits |= UInt64(src[base + 2 + i]) << (8 * UInt64(i)) }
                    for i in 0..<16 { alpha[i] = table[Int((bits >> (3 * UInt64(i))) & 0x7)] }
                    colorOffset = base + 8

                case .dxt1:
                    colorOffset = base

                default:
                    return nil
                }

                let c0 = UInt16(src[colorOffset]) | (UInt16(src[colorOffset + 1]) << 8)
                let c1 = UInt16(src[colorOffset + 2]) | (UInt16(src[colorOffset + 3]) << 8)
                var r = [Int](repeating: 0, count: 4)
                var g = [Int](repeating: 0, count: 4)
                var b = [Int](repeating: 0, count: 4)
                var a = [Int](repeating: 255, count: 4)

                func unpack565(_ c: UInt16) -> (Int, Int, Int) {
                    let r5 = Int((c >> 11) & 0x1F), g6 = Int((c >> 5) & 0x3F), b5 = Int(c & 0x1F)
                    return ((r5 * 255 + 15) / 31, (g6 * 255 + 31) / 63, (b5 * 255 + 15) / 31)
                }

                (r[0], g[0], b[0]) = unpack565(c0)
                (r[1], g[1], b[1]) = unpack565(c1)

                // DXT1 with c0 <= c1 switches to a 3-colour block with one transparent index.
                if format == .dxt1 && c0 <= c1 {
                    r[2] = (r[0] + r[1]) / 2; g[2] = (g[0] + g[1]) / 2; b[2] = (b[0] + b[1]) / 2
                    r[3] = 0; g[3] = 0; b[3] = 0; a[3] = 0
                } else {
                    r[2] = (2 * r[0] + r[1]) / 3; g[2] = (2 * g[0] + g[1]) / 3; b[2] = (2 * b[0] + b[1]) / 3
                    r[3] = (r[0] + 2 * r[1]) / 3; g[3] = (g[0] + 2 * g[1]) / 3; b[3] = (b[0] + 2 * b[1]) / 3
                }

                var indices: UInt32 = 0
                for i in 0..<4 { indices |= UInt32(src[colorOffset + 4 + i]) << (8 * UInt32(i)) }

                for py in 0..<4 {
                    let y = by * 4 + py
                    if y >= height { break }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        if x >= width { continue }
                        let sel = Int((indices >> (2 * UInt32(py * 4 + px))) & 0x3)
                        let o = (y * width + x) * 4
                        out[o]     = UInt8(r[sel])
                        out[o + 1] = UInt8(g[sel])
                        out[o + 2] = UInt8(b[sel])
                        let blockAlpha = format == .dxt1 ? UInt8(a[sel]) : alpha[py * 4 + px]
                        out[o + 3] = blockAlpha
                    }
                }
            }
        }
        return out
    }

    // MARK: - Legacy fallback

    /// Last resort for files that do not match the documented container layout: scan the whole
    /// blob for an embedded JPEG or PNG, the way this parser used to work.
    private func scanForEmbeddedImage() -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD8 && bytes[i + 2] == 0xFF {
                var end = i + 2
                while end + 1 < bytes.count {
                    if bytes[end] == 0xFF && bytes[end + 1] == 0xD9 {
                        return Data(bytes[i...(end + 1)])
                    }
                    end += 1
                }
                return Data(bytes[i...])
            }
            if bytes[i] == 0x89 && bytes[i + 1] == 0x50
                && bytes[i + 2] == 0x4E && bytes[i + 3] == 0x47 {
                return Data(bytes[i...])
            }
            i += 1
        }
        return nil
    }

    static func log(_ message: String) {
        NSLog("[TEXParser] %@", message)
    }
}
