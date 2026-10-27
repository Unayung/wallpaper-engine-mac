//
//  SceneTextLayer.swift
//  Open Wallpaper Engine
//
//  Rasterises a scene's text objects — clocks, labels, music-player readouts, window titles.
//
//  These are a third of the library: 386 text objects across 33 of the 94 installed scenes.
//  Skipping them did not leave a scene merely plainer, it left it half-built, because authors
//  assemble a panel out of solid rectangles and then put the only content in a text layer on
//  top. A music player rendered as three empty white boxes; a terminal-themed wallpaper as
//  blank windows with neon borders and nothing inside.
//

import Cocoa

enum SceneTextLayer {

    /// Everything needed to draw one text object, resolved once when the scene loads.
    struct Style {
        /// Already shrunk to fit the authored box, if the face measures wider than the author's.
        var font: NSFont
        var color: NSColor
        /// The box Wallpaper Engine laid the text out into, in scene units.
        var box: CGSize
        var horizontal: NSTextAlignment
        var verticalAlign: Vertical
        /// Filled behind the text only when the author asked for it, which four objects do.
        var background: NSColor?
        /// Where lines are broken, or nil when the author left `limitwidth` off and the string
        /// only ever breaks where it says `\n`.
        var wrapWidth: CGFloat?
        /// `limitrows` with `maxrows` 1: one line per authored line, cut rather than wrapped.
        var singleLine: Bool = false
        var ellipsis: Bool = false

        enum Vertical { case top, center, bottom }

        /// Which point of the drawn text sits on the object's origin.
        ///
        /// The alignment is the anchor, not just the justification inside a fixed box. Porsche
        /// 911 GT3's clock is left-aligned at x 1182 of a 3840-wide scene, and the preview puts
        /// the left edge of its digits there; drawn as a box centred on the origin it sat half a
        /// box — 860 units — to the left, beside the car instead of behind it. Pixels shows the
        /// same thing as a layout: its world clocks put a city, a time and a date in a column at
        /// x -158, -160 and -156 with boxes 150, 592 and 164 wide, which is a column only if the
        /// left edges are what those numbers place. Vertically, Winter Conch Street's greeting is
        /// top-aligned 50 units below the top of the frame in a 346-unit box; centred, its first
        /// line was cut off by the frame edge.
        ///
        /// It is also what keeps a changing string in place: a left-aligned clock grows to the
        /// right as its digits widen, rather than out of both sides.
        var anchorPoint: CGPoint {
            let x: CGFloat
            switch horizontal {
            case .left: x = 0
            case .right: x = 1
            default: x = 0.5
            }
            let y: CGFloat
            switch verticalAlign {
            case .top: y = 1
            case .center: y = 0.5
            case .bottom: y = 0
            }
            return CGPoint(x: x, y: y)
        }
    }

    // MARK: - Style

    /// Wallpaper Engine's `pointsize` is not the pixel size of the rendered glyphs: it is four
    /// times smaller.
    ///
    /// Measured against the library rather than assumed. For every text object whose string is a
    /// single literal line and whose font file ships in the wallpaper, the authored box was
    /// compared with what that same font actually measures at `pointsize`. The box came out
    /// 3.6–4.3× wider, and its height a flat 4.67× `pointsize` for FreePixel and 2.56× for
    /// Pixeltype. Those two numbers are the same finding: a glyph size of `pointsize * 4` with
    /// each font's own line height on top — 1.17 em for FreePixel, 0.64 em for Pixeltype, which
    /// is ordinary for a pixel font that leaves most of its em box empty. Two unrelated fonts
    /// agreeing on the factor is what makes it a constant rather than a fit.
    static let pixelsPerPoint: CGFloat = 4

    static func style(for obj: WESceneObject, read: (String) -> Data?) -> Style? {
        guard let pointsize = obj.pointsize, pointsize > 0 else { return nil }
        let (w, h) = (obj.size ?? "").parseVector2()
        guard w > 0, h > 0 else { return nil }

        let size = CGFloat(pointsize) * pixelsPerPoint
        let font = font(named: obj.font, size: size, read: read)

        let c = obj.color?.parseColor() ?? (r: 1.0, g: 1.0, b: 1.0)
        var background: NSColor?
        if obj.opaquebackground == true {
            let b = obj.backgroundcolor?.parseColor() ?? (r: 0.0, g: 0.0, b: 0.0)
            background = NSColor(red: b.r, green: b.g, blue: b.b, alpha: 1.0)
        }

        var style = Style(font: font,
                          color: NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0),
                          box: CGSize(width: CGFloat(w), height: CGFloat(h)),
                          horizontal: alignment(obj.horizontalalign),
                          verticalAlign: vertical(obj.verticalalign),
                          background: background)

        // `size` is the extent of the baked string as Wallpaper Engine laid it out, whether or
        // not `limitwidth` is on — 1166 units beside a `maxwidth` of 1200 on Honkai's artist
        // line — so the wrapping bound, when there is one, is `maxwidth`.
        if obj.limitwidth == true {
            style.wrapWidth = obj.maxwidth.map { CGFloat($0) }.flatMap { $0 > 0 ? $0 : nil }
                ?? style.box.width
            style.singleLine = obj.limitrows == true && (obj.maxrows ?? 0).rounded() == 1
            style.ellipsis = obj.limituseellipsis == true
        }

        style.font = fitted(style.font, baked: obj.text ?? "", style: style)
        return style
    }

    /// The font shrunk until the baked string fits the box it was measured from.
    ///
    /// The authored box is the authority on how large the text may be, because the face is so
    /// often not the author's. 129 of this library's text objects name a font by family —
    /// `systemfont_consolas`, `systemfont_arial` — and Consolas ships with Windows, so on a Mac
    /// the layout falls to SF Mono, which is wider. Lonely Cat's clock is the case that showed
    /// it: a 375-unit box holding "12:34", which SF Mono at the authored size measures at 396,
    /// so the string wrapped and the wallpaper displayed "12:3" with a stray "4" beneath it.
    /// Shrinking loses a little of the intended size; wrapping loses the reading.
    ///
    /// Measured once, against the string Wallpaper Engine itself measured, and kept for every
    /// string a script produces later. What is being corrected is the face, and that error
    /// belongs to the font, not to the string. Fitting each new string to the box instead
    /// would squeeze Honkai's and Angel's "SATURDAY" into a box measured from the placeholder
    /// "DAY" — the string is meant to outgrow that box, the font is not.
    private static func fitted(_ font: NSFont, baked: String, style: Style) -> NSFont {
        guard !baked.isEmpty, style.box.width > 0, style.box.height > 0 else { return font }
        let measured = measure(baked, font: font, style: style, width: nil)
        // Only ever shrink. A box with room to spare is the author padding their layout, not an
        // invitation to fill it — several objects sit in a box many times their own text.
        let overflow = max(measured.width / style.box.width, measured.height / style.box.height)
        guard overflow > 1, font.pointSize / overflow >= 1 else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: font.pointSize / overflow) ?? font
    }

    private static func alignment(_ raw: String?) -> NSTextAlignment {
        switch raw {
        case "left": return .left
        case "right": return .right
        default: return .center
        }
    }

    private static func vertical(_ raw: String?) -> Style.Vertical {
        switch raw {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }

    // MARK: - Fonts

    /// Resolved fonts, keyed by path and size. A scene puts every digit of a clock in its own
    /// object, so the same face is asked for dozens of times per load.
    ///
    /// Locked because scenes are built off the main thread and a Mac with two displays builds
    /// two of them at once, which is an unsynchronised write to a shared Dictionary — a crash,
    /// not a wrong pixel.
    private static var cache: [String: NSFont] = [:]
    private static let cacheLock = NSLock()

    private static func font(named path: String?, size: CGFloat, read: (String) -> Data?) -> NSFont {
        let key = "\(path ?? "")@\(size)"
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }

        // Deliberately built outside the lock: reading a font file out of a `.pkg` is slow, and
        // holding the lock across it would serialise every layer of every screen behind it. Two
        // threads racing here both build the same font and the second overwrites the first,
        // which costs one redundant parse and nothing else.
        let resolved = load(path, size: size, read: read)
            ?? NSFont.systemFont(ofSize: size)
        cacheLock.lock()
        cache[key] = resolved
        cacheLock.unlock()
        return resolved
    }

    private static func load(_ path: String?, size: CGFloat, read: (String) -> Data?) -> NSFont? {
        guard let path, !path.isEmpty else { return nil }

        // `systemfont_arial` names a face by family and asks the host for it. Consolas ships
        // with Windows and with Microsoft Office, so it is present on some Macs and absent on
        // others; the fallbacks are chosen to keep the *shape* the author was relying on, since
        // a monospaced readout laid out in a proportional face no longer lines up.
        if path.hasPrefix("systemfont_") {
            let family = String(path.dropFirst("systemfont_".count))
            if let exact = NSFont(name: family, size: size) { return exact }
            switch family.lowercased() {
            case "consolas", "couriernew", "lucidaconsole":
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            case "arial", "helvetica", "segoeui", "tahoma", "verdana":
                return NSFont(name: "Helvetica", size: size)
            case "timesnewroman", "georgia":
                return NSFont(name: "Times New Roman", size: size)
            default:
                return nil
            }
        }

        // A font file, resolved through the same three roots as every other asset: the
        // wallpaper's own package, loose files beside it, then the shared Wallpaper Engine
        // library. Built into a CTFont directly instead of being registered with the font
        // manager, so a Workshop font never joins the list of faces installed on the machine.
        guard let data = read(path),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else { return nil }
        return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil) as NSFont
    }

    // MARK: - Rasterising

    private static func attributes(_ font: NSFont, style: Style) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.horizontal
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: style.color, .paragraphStyle: paragraph]
    }

    /// The laid-out extent of `text`, broken only at `width` when there is one.
    private static func measure(_ text: String, font: NSFont, style: Style,
                                width: CGFloat?) -> CGRect {
        (text as NSString).boundingRect(
            with: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(font, style: style))
    }

    /// Each authored line cut to `width`, ending in "…" when the author asked for one.
    private static func truncated(_ text: String, font: NSFont, style: Style, width: CGFloat,
                                  ellipsis: Bool) -> String {
        text.components(separatedBy: "\n").map { line in
            guard measure(line, font: font, style: style, width: nil).width > width else {
                return line
            }
            let characters = Array(line)
            let tail = ellipsis ? "\u{2026}" : ""
            // Longest prefix that still fits, found by bisection: a song title can run to a
            // hundred characters and each probe is a full text layout.
            var low = 0, high = characters.count
            while low < high {
                let mid = (low + high + 1) / 2
                let candidate = String(characters[..<mid]) + tail
                if measure(candidate, font: font, style: style, width: nil).width <= width {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return String(characters[..<low]) + tail
        }.joined(separator: "\n")
    }

    /// The text drawn into an image, and the size that image occupies in scene units.
    ///
    /// A string only breaks where the author allowed it to. With `limitwidth` off — 348 of the
    /// library's 386 text objects — the authored box is just the extent of whatever string was
    /// baked, so wrapping at its width broke every string longer than that one: Honkai's and
    /// Angel's weekday showed "SATURD" over "AY" — a box measured from "DAY" is three letters
    /// wide — Road Infinite's showed "SUN" over "DAY", and Lost Landscape's date broke onto two
    /// lines and then shrank to half height to fit them back in. The old code shrank per string
    /// against the *wrapped* layout, so every wrap also cost the text its size: Lonely Cat's
    /// clock rendered at half its authored width for the same reason. Such a layer now grows
    /// with its string, away from the edge its alignment pins to the origin
    /// (see `Style.anchorPoint`). With `limitwidth` on, lines break at `maxwidth`, and at word
    /// boundaries only: a single word too wide for the bound shrinks the font instead, because
    /// AppKit's word wrapping falls back to splitting the word itself.
    ///
    /// The face has already been fitted to the box when the style was resolved — see
    /// `fitted(_:baked:style:)` — so a later string keeps the size the baked one got.
    static func image(_ text: String, style: Style) -> (image: NSImage, size: CGSize)? {
        guard !text.isEmpty else { return nil }

        var text = text
        var font = style.font
        // Wrapping happens at the bound plus a sliver of slack: Wallpaper Engine laid this out
        // with its own metrics, so an exact bound puts the last word on a line of its own
        // whenever rounding goes the wrong way.
        let wrapWidth = style.wrapWidth.map { $0 * 1.02 }
        var layoutWidth: CGFloat?
        if let wrapWidth {
            if style.singleLine {
                text = truncated(text, font: font, style: style, width: wrapWidth,
                                 ellipsis: style.ellipsis)
            } else {
                let widestWord = text
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { measure($0, font: font, style: style, width: nil).width }
                    .max() ?? 0
                if widestWord > wrapWidth, font.pointSize * wrapWidth / widestWord >= 1 {
                    font = NSFont(descriptor: font.fontDescriptor,
                                  size: font.pointSize * wrapWidth / widestWord) ?? font
                }
                layoutWidth = wrapWidth
            }
        }
        let measured = measure(text, font: font, style: style, width: layoutWidth)
        let attrs = attributes(font, style: style)

        let size = CGSize(width: max(style.box.width, ceil(measured.width)),
                          height: max(style.box.height, ceil(measured.height)))

        // Text is the one layer that is read rather than looked at, so it is rasterised above
        // scene resolution and let the sampler bring it back down — a 1080p-authored scene on a
        // 4K display otherwise shows a clock upscaled 2×. Dropped for boxes already large
        // enough that the supersample would cost more than the legibility is worth.
        let scale: CGFloat = size.width * size.height > 1_000_000 ? 1 : 2
        let pixelsWide = Int(ceil(size.width * scale))
        let pixelsHigh = Int(ceil(size.height * scale))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)

        if let background = style.background {
            background.setFill()
            CGRect(origin: .zero, size: size).fill()
        }

        // AppKit's origin is bottom-left and the text draws downward from the rect's top, so
        // "top" is the whole box and the other two are inset from it.
        let y: CGFloat
        switch style.verticalAlign {
        case .top: y = size.height - measured.height
        case .center: y = (size.height - measured.height) / 2
        case .bottom: y = 0
        }
        (text as NSString).draw(
            with: CGRect(x: 0, y: y, width: size.width, height: measured.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return (image, size)
    }
}
