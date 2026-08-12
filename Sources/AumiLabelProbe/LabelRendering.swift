import Foundation
import AppKit
import CoreImage
import IOBluetooth

struct PrintJob {
    let widthDots: Int
    let heightDots: Int
    let raster: Data

    /// Reproduces the app's captured print order: reset, density, receipt mode, raster, LABELAT1.
    var transmission: Data {
        Data([0x1B, 0x40]) + // ESC @ — print initialization
        Data([0x1D, 0x49, 0xF0, 0x50]) + // density 80, as used by the captured app print
        Data([0xE7, 0xBA, 0xB8, 0xE5, 0x9E, 0x01]) + // "receipt" paper mode
        raster +
        Data("LABELAT1".utf8)
    }
}

struct PrinterProtocol {
    // All label design is expressed in this normal orientation: 30 mm wide × 15 mm high.
    static let canonicalWidth = 207
    static let canonicalHeight = 96

    static func canonicalToPrinterCoordinate(x: Int, y: Int) -> (x: Int, y: Int) {
        // Clockwise conversion to the printer's 96×207 raster orientation.
        (canonicalHeight - 1 - y, x)
    }

    static let observedProbeCommands: [Data] = [
        Data([0x1D, 0x67, 0x39]),
        Data([0x1E, 0x47, 0x03]),
        Data([0x1D, 0x67, 0x53]),
        Data([0x1D, 0x67, 0x69]),
    ]

    /// The AumiLabel calibration action: select receipt media then issue LABELV1.
    static let receiptCalibration = Data([0xE7, 0xBA, 0xB8, 0xE5, 0x9E, 0x01]) + Data("LABELV1".utf8)
    static func expandEmojiShortcodes(_ text: String) -> String {
        EmojiShortcodes.values.reduce(text) { result, replacement in result.replacingOccurrences(of: replacement.key, with: replacement.value) }
    }

    struct FontFit { let text: NSAttributedString; let bounds: NSRect; let size: CGFloat }

    static func maxFontFit(text: String, fontName: String, maximumSize: CGFloat, in rectangle: NSSize, color: NSColor = .black) throws -> FontFit {
        guard NSFont(name: fontName, size: maximumSize) != nil else { throw CLIError.unsupportedFont(fontName) }
        var best: FontFit?
        // Grow from the minimum instead of shrinking from the requested maximum. This
        // makes the intended operation explicit and keeps every line independent.
        for size in stride(from: CGFloat(8), through: maximumSize, by: 0.05) {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont(name: fontName, size: size)!, .foregroundColor: color])
            // A CLI --text is one physical line: measure its natural (unwrapped) extent.
            let bounds = attributed.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).integral
            guard bounds.width <= rectangle.width && bounds.height <= rectangle.height else { break }
            best = FontFit(text: attributed, bounds: bounds, size: size)
        }
        guard let best else { throw CLIError.usage("text cannot fit within the printable label") }
        return best
    }

    static func twoLineLaneWidths(contentWidth: CGFloat, firstHeight: CGFloat, secondHeight: CGFloat) -> [CGFloat] {
        let half = contentWidth / 2
        // Only exactly one short line gives its unused space to the other; if both are
        // short or both are tall, retain a balanced half-and-half layout.
        if firstHeight < half && secondHeight >= half { return [contentWidth - firstHeight, firstHeight] }
        if secondHeight < half && firstHeight >= half { return [secondHeight, contentWidth - secondHeight] }
        return [half, half]
    }

    /// Dimensions sent by the captured AumiLabel print: 96 × 207 dots.
    static let testLabel15x30mm: PrintJob = makeTestLabel()
    static let blackDiagnosticLabel: PrintJob = makeRasterJob(canonicalPixels: Array(repeating: true, count: canonicalWidth * canonicalHeight))
    static let overscanDiagnosticLabel: PrintJob = blackDiagnosticLabel
    static let cursiveHelloLabel15x30mm: PrintJob = makeCursiveLabel(lines: ["Hello"], fontName: "SnellRoundhand", pointSize: 82)

    static func qrLabel(value: String) throws -> PrintJob {
        guard !value.isEmpty else { throw CLIError.usage("--qr must not be empty") }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw CLIError.usage("QR generation is unavailable") }
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw CLIError.usage("could not create QR code") }
        let modules = Int(image.extent.width)
        let scale = max(1, min(7, 88 / modules))
        let side = modules * scale
        var rgba = Array(repeating: UInt8(0), count: side * side * 4)
        CIContext().render(
            image.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))),
            toBitmap: &rgba, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        var canonicalPixels = Array(repeating: false, count: canonicalWidth * canonicalHeight)
        let sourceOffsetX = (canonicalWidth - side) / 2
        let sourceOffsetY = (canonicalHeight - side) / 2
        for pixelY in 0..<side {
            for pixelX in 0..<side where rgba[(pixelY * side + pixelX) * 4] < 128 {
                canonicalPixels[(sourceOffsetY + pixelY) * canonicalWidth + sourceOffsetX + pixelX] = true
            }
        }
        return makeRasterJob(canonicalPixels: canonicalPixels)
    }

    static func textLabel(text: String, fontName: String, pointSize: CGFloat) throws -> PrintJob {
        try textLabel(lines: [text], fontName: fontName, pointSize: pointSize)
    }

    static func textLabel(lines: [String], fontName: String, pointSize: CGFloat, inverted: Bool = false) throws -> PrintJob {
        guard NSFont(name: fontName, size: pointSize) != nil else { throw CLIError.unsupportedFont(fontName) }
        return makeCursiveLabel(lines: lines.map(expandEmojiShortcodes), fontName: fontName, pointSize: pointSize, inverted: inverted)
    }

    private static func makeCursiveLabel(lines: [String], fontName: String, pointSize: CGFloat, inverted: Bool = false) -> PrintJob {
        // Render at native printer resolution using macOS's Snell Roundhand script face.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: canonicalWidth, pixelsHigh: canonicalHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Unable to create cursive text raster")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: canonicalWidth, height: canonicalHeight))
        // Font metrics can underreport script glyph overhang. Clip to the printable inset
        // so no long-text stroke can escape the label canvas.
        NSBezierPath(rect: NSRect(x: 4, y: 4, width: CGFloat(canonicalWidth - 8), height: CGFloat(canonicalHeight - 8))).addClip()
        // Fit each line independently along the 30 mm axis; multiple --text flags split the 15 mm width.
        let availableLong = CGFloat(canonicalWidth - 12)
        // Reserve a two-dot gap between text lanes. More importantly, size each line to
        // its lane on both axes: emoji fallback glyphs can be far taller than script text.
        let interLineGap: CGFloat = lines.count > 1 ? 1 : 0
        let contentWide = CGFloat(canonicalHeight - 8) - interLineGap * CGFloat(lines.count - 1)
        let textColor = inverted ? NSColor.white : NSColor.black

        let fullLineRectangle = NSSize(width: availableLong, height: contentWide)
        // First calculate each line at its largest size within the whole printable label.
        let fullFits = try! lines.map { try maxFontFit(text: $0, fontName: fontName, maximumSize: pointSize, in: fullLineRectangle, color: textColor) }
        let laneWidths: [CGFloat] = lines.count == 2
            ? twoLineLaneWidths(contentWidth: contentWide, firstHeight: fullFits[0].bounds.height, secondHeight: fullFits[1].bounds.height)
            : Array(repeating: contentWide / CGFloat(lines.count), count: lines.count)

        for (lineIndex, line) in lines.enumerated() {
            let physicalLine = lineIndex
            let availableWide = laneWidths[physicalLine]
            // Re-fit against the chosen lane; this is the sole source of font sizing.
            let fit = try! maxFontFit(text: line, fontName: fontName, maximumSize: pointSize, in: NSSize(width: availableLong, height: availableWide), color: textColor)
            let x = max(2, (CGFloat(canonicalWidth) - fit.bounds.width) / 2)
            let canonicalLaneOrigin = 4 + laneWidths.prefix(physicalLine).reduce(0, +) + CGFloat(physicalLine) * interLineGap
            // Layout coordinates are conventional y-down. AppKit draws y-up, so convert
            // the allocated canonical lane only at this rendering boundary.
            let laneOrigin = CGFloat(canonicalHeight) - canonicalLaneOrigin - availableWide
            let y = laneOrigin + (availableWide - fit.bounds.height) / 2
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 4, y: laneOrigin, width: CGFloat(canonicalWidth - 8), height: availableWide)).addClip()
            fit.text.draw(at: NSPoint(x: x, y: y))
            NSGraphicsContext.restoreGraphicsState()
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var canonicalPixels = Array(repeating: false, count: canonicalWidth * canonicalHeight)
        for y in 0..<canonicalHeight { for x in 0..<canonicalWidth {
            guard let color = bitmap.colorAt(x: x, y: canonicalHeight - 1 - y) else { continue }
            let glyphPixel = color.alphaComponent > 0.5
            canonicalPixels[y * canonicalWidth + x] = inverted ? !glyphPixel : glyphPixel
        }}
        return makeRasterJob(canonicalPixels: canonicalPixels)
    }

    static func writePreviewPNG(of job: PrintJob, to output: String) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canonicalWidth, pixelsHigh: canonicalHeight, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let pixels = bitmap.bitmapData else { throw CLIError.usage("could not allocate preview bitmap") }
        memset(pixels, 0xFF, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bytesPerRow = job.widthDots / 8
        for y in 0..<job.heightDots { for x in 0..<job.widthDots {
            let byte = job.raster[8 + y * bytesPerRow + x / 8]
            guard byte & UInt8(1 << (7 - x % 8)) != 0 else { continue }
            // Decode the printer raster through the same canonical mapping used to encode it.
            let canonicalX = y
            let canonicalY = canonicalHeight - 1 - x
            let offset = (canonicalHeight - 1 - canonicalY) * bitmap.bytesPerRow + canonicalX * 4
            pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
        }}
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CLIError.usage("could not encode preview PNG") }
        try data.write(to: URL(fileURLWithPath: output))
    }

    static func inkRows(in job: PrintJob) -> [Int] {
        let bytesPerRow = job.widthDots / 8
        return (0..<job.heightDots).filter { row in
            job.raster.dropFirst(8 + row * bytesPerRow).prefix(bytesPerRow).contains { $0 != 0 }
        }
    }

    private static func makeTestLabel() -> PrintJob {
        var pixels = Array(repeating: false, count: canonicalWidth * canonicalHeight)
        func setPixel(_ x: Int, _ y: Int) {
            guard x >= 0, x < canonicalWidth, y >= 0, y < canonicalHeight else { return }
            pixels[y * canonicalWidth + x] = true
        }
        for x in 2..<(canonicalWidth - 2) { setPixel(x, 2); setPixel(x, canonicalHeight - 3) }
        for y in 2..<(canonicalHeight - 2) { setPixel(2, y); setPixel(canonicalWidth - 3, y) }
        return makeRasterJob(canonicalPixels: pixels)
    }

    private static func makeRasterJob(canonicalPixels: [Bool]) -> PrintJob {
        precondition(canonicalPixels.count == canonicalWidth * canonicalHeight)
        let printerWidth = canonicalHeight
        let printerHeight = canonicalWidth
        let bytesPerRow = printerWidth / 8
        var raster = Data([0x1D, 0x76, 0x30, 0x00, UInt8(bytesPerRow), 0x00, UInt8(printerHeight & 0xFF), UInt8(printerHeight >> 8)])
        for printerY in 0..<printerHeight {
            for byteIndex in 0..<bytesPerRow {
                var value: UInt8 = 0
                for bit in 0..<8 {
                    let printerX = byteIndex * 8 + bit
                    let canonicalX = printerY
                    let canonicalY = canonicalHeight - 1 - printerX
                    if canonicalPixels[canonicalY * canonicalWidth + canonicalX] { value |= UInt8(1 << (7 - bit)) }
                }
                raster.append(value)
            }
        }
        return PrintJob(widthDots: printerWidth, heightDots: printerHeight, raster: raster)
    }
}

