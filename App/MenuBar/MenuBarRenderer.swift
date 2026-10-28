import AppKit
import FreesideKit

/// Draws the status item as one image. The image is always the width
/// reserved for every style the item can switch to, with the current
/// content centered, so nothing in the menu bar moves when it switches.
///
/// The canvas and glyph-cell drawing are copied from flatline (PRD §12).
@MainActor
enum MenuBarRenderer {
    enum Piece: Sendable, Equatable {
        /// The drive glyph, with a `!` badge when a volume is low on space.
        case glyph(badge: Bool)
        /// Small caption over a value: `RAID` / `1.2T`.
        case stacked(caption: String, value: String)
        /// Read over write: `R 412M` / `W 380M`.
        case rates(read: String, write: String)
        /// Mini line graph; values are already scaled to 0...1.
        case trace(primary: [Double], secondary: [Double])
    }

    static let traceWidth: CGFloat = 28
    static let gap: CGFloat = 6
    static let innerGap: CGFloat = 4

    /// Everything that determines the pixels. Equal layouts render identical images,
    /// so the status item can skip redraws when nothing visible changed.
    struct Layout: Equatable {
        var pieces: [Piece]
        /// The reserved width, at least as wide as `pieces`.
        var width: CGFloat
    }

    /// What the layout is built from, gathered by the status item.
    struct Inputs {
        var style: MenuBarStyle
        var reserved: [MenuBarStyle]
        var pinnedName: String
        var pinnedAvailable: Double
        var pinnedLow: Bool
        var anyLow: Bool
        var readRate: Double
        var writeRate: Double
        var trace: (read: [Double], write: [Double])?
        var units: ByteUnits
    }

    static func layout(_ inputs: Inputs) -> Layout {
        let width = inputs.reserved.map { contentWidth(pieces(for: $0, inputs)) }.max() ?? 0
        return Layout(pieces: pieces(for: inputs.style, inputs), width: width)
    }

    private static func pieces(for style: MenuBarStyle, _ inputs: Inputs) -> [Piece] {
        let space = Piece.stacked(caption: caption(inputs.pinnedName, low: inputs.pinnedLow), value: Format.compact(inputs.pinnedAvailable, units: inputs.units))
        var activity: [Piece] = []
        if let trace = inputs.trace {
            // Scale to the window's peak, but never below 1 MB/s so idle stays flat.
            let peak = max(1_000_000, trace.read.max() ?? 0, trace.write.max() ?? 0)
            activity.append(.trace(primary: quantized(trace.write.map { $0 / peak }), secondary: quantized(trace.read.map { $0 / peak })))
        }
        activity.append(.rates(read: "R " + Format.compact(inputs.readRate, units: inputs.units).leftPadded(to: 4),
                               write: "W " + Format.compact(inputs.writeRate, units: inputs.units).leftPadded(to: 4)))
        return switch style {
        case .icon: [.glyph(badge: inputs.anyLow)]
        case .space: [space]
        case .activity: activity
        case .spaceActivity: [space] + activity
        }
    }

    /// The volume name, truncated to the caption's width, with `!` when it's low.
    static func caption(_ name: String, low: Bool) -> String {
        let limit = Int(stackedWidth / advance(of: captionFont)) - (low ? 1 : 0)
        let fitted = name.count > limit ? String(name.prefix(max(1, limit - 1))) + "…" : name
        return low ? fitted + "!" : fitted
    }

    /// Renders `layout` at `scale` pixels per point, in the menu bar's own label
    /// color (resolved for `appearance`) so it can go straight into a layer.
    ///
    /// Plain Core Graphics into canvases kept between ticks. Rasterizing here,
    /// rather than handing AppKit a drawing-handler image, also avoids a CoreText
    /// crash in the status bar's stylized drawing path on macOS 27 (flatline).
    static func image(for layout: Layout, appearance: NSAppearance, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: max(1, ceil(layout.width)), height: NSStatusBar.system.thickness)
        guard let canvas = canvas(size: size, scale: scale) else { return nil }
        let context = canvas.context
        let ink = colors(for: appearance, scale: scale)

        canvas.clear()
        drawingCanvas = canvas
        defer { drawingCanvas = nil }
        var x = ((size.width - contentWidth(layout.pieces)) / 2).rounded()
        for (index, piece) in layout.pieces.enumerated() {
            if index > 0 { x += spacing(before: piece, after: layout.pieces[index - 1]) }
            draw(piece, at: x, height: size.height, ink: ink, scale: scale, in: context)
            x += width(of: piece)
        }
        return canvas.image()
    }

    // MARK: - Layout

    private static func contentWidth(_ pieces: [Piece]) -> CGFloat {
        var total: CGFloat = 0
        for (index, piece) in pieces.enumerated() {
            if index > 0 { total += spacing(before: piece, after: pieces[index - 1]) }
            total += width(of: piece)
        }
        return ceil(total)
    }

    /// A trace sits close to its rates; space and activity are further apart.
    private static func spacing(before piece: Piece, after previous: Piece) -> CGFloat {
        if case .trace = previous { return innerGap }
        return gap
    }

    private static func width(of piece: Piece) -> CGFloat {
        switch piece {
        case .glyph: glyphWidth
        case .stacked: stackedWidth
        case .rates: ratesWidth
        case .trace: traceWidth
        }
    }

    // Segment widths that never change, measured once. The caption holds
    // eight characters; the value at most four ("856G").
    private static let stackedWidth = max(textWidth("88888888", font: captionFont), textWidth("8888", font: valueFont))
    private static let ratesWidth = textWidth("R 8888", font: ratesFont)
    /// The wider of the two symbols, so the badge doesn't change the width.
    private static let glyphWidth: CGFloat = ceil([plainSymbol, badgeSymbol].compactMap { $0?.size.width }.max() ?? 22)

    /// Rounds trace values to the trace's pixel grid so sub-pixel jitter doesn't force a redraw.
    private static func quantized(_ values: [Double]) -> [Double] {
        values.map { ($0 * 32).rounded() / 32 }
    }

    // MARK: - Drawing

    private static let captionFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
    private static let valueFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    private static let ratesFont = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)

    private static func draw(_ piece: Piece, at x: CGFloat, height: CGFloat, ink: Ink, scale: CGFloat, in context: CGContext) {
        let mid = height / 2
        switch piece {
        case let .glyph(badge):
            guard let image = glyph(badge: badge, ink: ink, scale: scale) else { return }
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let rect = CGRect(x: (x + (glyphWidth - size.width) / 2).rounded(), y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
            // The canvas is flipped; images draw upright in an unflipped space.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()

        case let .stacked(caption, value):
            drawText(caption, font: captionFont, color: ink.caption, centeredIn: stackedWidth, x: x, y: mid - 11, in: context)
            drawText(value, font: valueFont, color: ink.text, centeredIn: stackedWidth, x: x, y: mid - 2.5, in: context)

        case let .rates(read, write):
            drawText(read, font: ratesFont, color: ink.text, centeredIn: ratesWidth, x: x, y: mid - 11, in: context)
            drawText(write, font: ratesFont, color: ink.text, centeredIn: ratesWidth, x: x, y: mid - 0.5, in: context)

        case let .trace(primary, secondary):
            let rect = CGRect(x: x, y: mid - 8, width: traceWidth, height: 16)
            context.setFillColor(ink.baseline)
            context.fill(CGRect(x: rect.minX, y: rect.maxY - 0.5, width: rect.width, height: 0.5))
            stroke(secondary, in: rect, color: ink.secondary, context: context)
            stroke(primary, in: rect, color: ink.text, context: context)
        }
    }

    // MARK: Glyph

    private static var glyphImages: [String: CGImage] = [:]
    private static let plainSymbol = symbol("externaldrive")
    private static let badgeSymbol = symbol("externaldrive.badge.exclamationmark")

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// The SF Symbol tinted with the label color, rasterized once per ink.
    private static func glyph(badge: Bool, ink: Ink, scale: CGFloat) -> CGImage? {
        let key = "\(ink.key)|\(badge)"
        if let cached = glyphImages[key] { return cached }
        guard let symbol = badge ? badgeSymbol ?? plainSymbol : plainSymbol else { return nil }
        let size = symbol.size
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // Recolor whatever the symbol drew with the label color.
        context.setBlendMode(.sourceIn)
        context.setFillColor(ink.text)
        context.fill(CGRect(origin: .zero, size: size))
        let image = context.makeImage()
        glyphImages[key] = image
        return image
    }

    private static var widthCache: [String: CGFloat] = [:]

    private static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(string)"
        if let cached = widthCache[key] { return cached }
        let width = ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
        widthCache[key] = width
        return width
    }

    // MARK: - Canvas

    /// A bitmap drawn into on alternate ticks. Its CTM is flipped so y grows
    /// downward, like AppKit views. freeside owns the pixels so text can be
    /// copied straight in, and images are made from the same memory without a
    /// copy. Two canvases alternate: Core Animation copies an image's pixels
    /// when it commits the layer, so a canvas is free again two ticks later.
    private final class Canvas {
        let context: CGContext
        let buffer: UnsafeMutableRawPointer
        /// Owns `buffer`: frees it once the canvas and every image made from
        /// it are gone, so a resize can't free pixels an image still uses.
        let provider: CGDataProvider

        init?(pixelWidth: Int, pixelHeight: Int, scale: CGFloat, height: CGFloat) {
            let bytesPerRow = pixelWidth * 4
            let size = bytesPerRow * pixelHeight
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: size, releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
            }) else {
                buffer.deallocate()
                return nil
            }
            guard let context = CGContext(
                data: buffer, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: 0, y: -height)
            self.context = context
            self.buffer = buffer
            self.provider = provider
        }

        func clear() {
            memset(buffer, 0, context.bytesPerRow * context.height)
        }

        /// Wraps the current pixels without copying them.
        func image() -> CGImage? {
            CGImage(
                width: context.width, height: context.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: context.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    private static var canvases: [Canvas] = []
    private static var nextCanvas = 0
    /// The canvas being drawn this tick; text is copied into its buffer.
    private static var drawingCanvas: Canvas?

    private static func canvas(size: CGSize, scale: CGFloat) -> Canvas? {
        let pixelWidth = Int(size.width * scale), pixelHeight = Int(size.height * scale)
        if canvases.first.map({ $0.context.width != pixelWidth || $0.context.height != pixelHeight }) ?? true {
            canvases = (0..<2).compactMap { _ in Canvas(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, height: size.height) }
            guard canvases.count == 2 else { canvases = []; return nil }
        }
        nextCanvas = (nextCanvas + 1) % canvases.count
        return canvases[nextCanvas]
    }

    /// Label colors resolved for one appearance, plus that appearance's text images.
    private struct Ink {
        var key: String
        var text: CGColor
        var caption: CGColor
        var baseline: CGColor
        var secondary: CGColor
    }

    private static var currentInk: Ink?

    private static func colors(for appearance: NSAppearance, scale: CGFloat) -> Ink {
        let key = "\(appearance.name.rawValue)@\(scale)"
        if let currentInk, currentInk.key == key { return currentInk }
        var ink: Ink!
        appearance.performAsCurrentDrawingAppearance {
            let label = NSColor.labelColor
            ink = Ink(
                key: key,
                text: label.cgColor,
                caption: label.withAlphaComponent(0.7).cgColor,
                baseline: label.withAlphaComponent(0.25).cgColor,
                secondary: label.withAlphaComponent(0.45).cgColor
            )
        }
        currentInk = ink
        glyphCells.removeAll()
        glyphImages.removeAll()
        return ink
    }

    // MARK: Text
    //
    // Every menu bar font is monospaced, so a string is a row of equal cells.
    // Each character is rasterized once per font, color and scale; drawing a
    // string copies those cells into the canvas buffer. About 30 distinct
    // characters cover everything freeside shows, so after the first few ticks
    // drawing text never touches CoreText. (Caching whole strings missed on most
    // network rates, and each miss cost ~140 µs on an idle, clocked-down core.)

    private struct GlyphKey: Hashable {
        let fontSize: CGFloat
        let alpha: CGFloat
        let character: Character
    }

    /// Premultiplied RGBA pixels, top row first, `padding` px of margin each side
    /// so glyphs that overhang their advance aren't clipped. `ink` is the
    /// bounding box of non-transparent pixels; only that part is copied.
    private struct GlyphCell {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let ink: (columns: Range<Int>, rows: Range<Int>)
    }

    private static let padding = 2
    private static var glyphCells: [GlyphKey: GlyphCell] = [:]
    private static var advances: [CGFloat: CGFloat] = [:]

    private static func advance(of font: NSFont) -> CGFloat {
        if let cached = advances[font.pointSize] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "0", attributes: [.font: font]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        advances[font.pointSize] = advance
        return advance
    }

    /// Draws `string` with its line box's top edge at `y`, centered in `width`.
    private static func drawText(_ string: String, font: NSFont, color: CGColor, centeredIn width: CGFloat, x: CGFloat, y: CGFloat, in context: CGContext) {
        guard let buffer = drawingCanvas?.buffer else { return }
        let scale = context.ctm.a
        let advance = advance(of: font)
        let characters = Array(string)
        let start = x + (width - advance * CGFloat(characters.count)) / 2
        let top = Int((y * scale).rounded())
        let canvasWidth = context.width, canvasHeight = context.height, bytesPerRow = context.bytesPerRow
        let pixels = buffer.assumingMemoryBound(to: UInt8.self)

        for (index, character) in characters.enumerated() where character != " " {
            let key = GlyphKey(fontSize: font.pointSize, alpha: color.alpha, character: character)
            let cell: GlyphCell
            if let cached = glyphCells[key] {
                cell = cached
            } else {
                guard let rendered = renderGlyph(character, font: font, color: color, advance: advance, scale: scale) else { continue }
                glyphCells[key] = rendered
                cell = rendered
            }
            let left = Int(((start + advance * CGFloat(index)) * scale).rounded()) - padding
            let firstColumn = max(cell.ink.columns.lowerBound, -left)
            let lastColumn = min(cell.ink.columns.upperBound, canvasWidth - left)
            let firstRow = max(cell.ink.rows.lowerBound, -top)
            let lastRow = min(cell.ink.rows.upperBound, canvasHeight - top)
            guard firstColumn < lastColumn, firstRow < lastRow else { continue }
            // Composite with a per-byte max: neighboring cells can overlap at
            // their edges, and two same-colored glyphs over a cleared canvas
            // merge correctly that way. 16 bytes at a time, then the remainder.
            let spanBytes = (lastColumn - firstColumn) * 4
            cell.pixels.withUnsafeBytes { source in
                for row in firstRow..<lastRow {
                    let destination = UnsafeMutableRawPointer(pixels + (top + row) * bytesPerRow + (left + firstColumn) * 4)
                    let sourceRow = source.baseAddress! + (row * cell.width + firstColumn) * 4
                    var byte = 0
                    while byte + 16 <= spanBytes {
                        let merged = pointwiseMax(
                            destination.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self),
                            sourceRow.loadUnaligned(fromByteOffset: byte, as: SIMD16<UInt8>.self)
                        )
                        destination.storeBytes(of: merged, toByteOffset: byte, as: SIMD16<UInt8>.self)
                        byte += 16
                    }
                    while byte < spanBytes {
                        let value = sourceRow.load(fromByteOffset: byte, as: UInt8.self)
                        if value > destination.load(fromByteOffset: byte, as: UInt8.self) {
                            destination.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
                        }
                        byte += 1
                    }
                }
            }
        }
    }

    /// Rasterizes one character into a cell whose top edge is the font's line
    /// top, matching where NSString drawing places text.
    private static func renderGlyph(_ character: Character, font: NSFont, color: CGColor, advance: CGFloat, scale: CGFloat) -> GlyphCell? {
        let width = Int(ceil(advance * scale)) + 2 * padding
        let lineHeight = font.ascender - font.descender + font.leading
        let height = Int(ceil(lineHeight * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        let attributed = NSAttributedString(string: String(character), attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(color)
        context.textPosition = CGPoint(x: CGFloat(padding) / scale, y: CGFloat(height) / scale - font.ascender)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        // Ink bounds: rows and columns with any non-zero alpha.
        var minColumn = width, maxColumn = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where bytes[(row * width + column) * 4 + 3] != 0 {
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        let ink = maxColumn < 0 ? (0..<0, 0..<0) : (minColumn..<maxColumn + 1, minRow..<maxRow + 1)
        return GlyphCell(pixels: bytes, width: width, height: height, ink: ink)
    }

    private static func stroke(_ values: [Double], in rect: CGRect, color: CGColor, context: CGContext) {
        guard values.count > 1 else { return }
        let step = rect.width / CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - 0.75 - CGFloat(max(0, min(1, value))) * (rect.height - 1.5))
        }
        context.beginPath()
        context.addLines(between: points)
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.strokePath()
    }
}
