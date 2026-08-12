import XCTest
@testable import AumiLabelProbe

final class ProtocolTests: XCTestCase {
    func testParsesRepeatedTextArgumentsAsLines() throws {
        let command = try CLICommand.parse(["print", "--text", "Nigel", "--text", "Cath", "--font", "SignPainter", "--size", "72", "--address", "25-00-02-00-26-c4"])
        XCTAssertEqual(command, .printText(lines: ["Nigel", "Cath"], font: "SignPainter", size: 72, inverted: false, address: "25-00-02-00-26-c4", device: nil))
    }

    func testParsesQRCodePrintFlag() throws {
        let command = try CLICommand.parse(["print", "--qr", "https://example.com", "--address", "25-00-02-00-26-c4"])
        XCTAssertEqual(command, .printQR(value: "https://example.com", address: "25-00-02-00-26-c4", device: nil))
    }

    func testQRCodeLabelUsesConfirmedCanvasAndContainsInk() throws {
        let job = try PrinterProtocol.qrLabel(value: "https://example.com")
        XCTAssertEqual(job.widthDots, 96)
        XCTAssertEqual(job.heightDots, 207)
        XCTAssertTrue(job.raster.dropFirst(8).contains { $0 != 0 })
    }

    func testParsesInvertPrintFlag() throws {
        let command = try CLICommand.parse(["print", "--text", "Nigel", "--invert", "--address", "25-00-02-00-26-c4"])
        XCTAssertEqual(command, .printText(lines: ["Nigel"], font: "SnellRoundhand", size: 82, inverted: true, address: "25-00-02-00-26-c4", device: nil))
    }

    func testInvertedTextLabelHasBlackBackgroundAndWhiteText() throws {
        let job = try PrinterProtocol.textLabel(lines: ["Hello"], fontName: "SnellRoundhand", pointSize: 82, inverted: true)
        XCTAssertEqual(job.raster.dropFirst(8).first, 0xFF)
        XCTAssertTrue(job.raster.dropFirst(8).contains { $0 != 0xFF })
    }

    func testLongTextAutoFitsWithinThePrintableLongAxis() throws {
        let job = try PrinterProtocol.textLabel(text: "Nigel loves you Cath", fontName: "SignPainter-HouseScript", pointSize: 82)
        let rows = PrinterProtocol.inkRows(in: job)
        XCTAssertGreaterThan(rows.count, 40)
        XCTAssertLessThan(rows.last!, 204)
    }

    func testTwoTextLinesBothRender() throws {
        let job = try PrinterProtocol.textLabel(lines: ["Nigel", "Cath"], fontName: "SignPainter-HouseScript", pointSize: 82)
        let rows = PrinterProtocol.inkRows(in: job)
        XCTAssertGreaterThan(rows.count, 80)
    }

    func testMaxFontSizeFitsTextWithinRectangle() throws {
        let fit = try PrinterProtocol.maxFontFit(text: "Cath", fontName: "AppleSDGothicNeo-Bold", maximumSize: 82, in: NSSize(width: 195, height: 88))
        XCTAssertEqual(fit.size, 73.85, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fit.bounds.width, 195)
        XCTAssertLessThanOrEqual(fit.bounds.height, 88)
    }

    func testEachLineGetsItsOwnFittedFontSize() throws {
        let top = try PrinterProtocol.maxFontFit(text: "❤️ Love you ❤️", fontName: "AppleSDGothicNeo-Bold", maximumSize: 82, in: NSSize(width: 195, height: 88))
        let bottom = try PrinterProtocol.maxFontFit(text: "Cath", fontName: "AppleSDGothicNeo-Bold", maximumSize: 82, in: NSSize(width: 195, height: 88))
        XCTAssertLessThan(top.size, bottom.size)
    }

    func testFontFitBumpsUpToTheLargestSizeWithinBounds() throws {
        let fit = try PrinterProtocol.maxFontFit(text: "Cath", fontName: "AppleSDGothicNeo-Bold", maximumSize: 82, in: NSSize(width: 195, height: 51))
        XCTAssertEqual(fit.size, 42.75, accuracy: 0.001)
        XCTAssertGreaterThan(try PrinterProtocol.maxFontFit(text: "Cath", fontName: "AppleSDGothicNeo-Bold", maximumSize: 82, in: NSSize(width: 195, height: 52)).size, fit.size)
    }

    func testTwoShortLinesSplitTheLabelEvenly() {
        XCTAssertEqual(PrinterProtocol.twoLineLaneWidths(contentWidth: 86, firstHeight: 20, secondHeight: 25), [43, 43])
    }

    func testOneShortLineGivesRemainingSpaceToTheOther() {
        XCTAssertEqual(PrinterProtocol.twoLineLaneWidths(contentWidth: 86, firstHeight: 20, secondHeight: 60), [66, 20])
    }

    func testMultilineLabelLeavesAGapBetweenAppleGothicLines() throws {
        let job = try PrinterProtocol.textLabel(lines: ["❤️ Love you ❤️", "Cath"], fontName: "AppleSDGothicNeo-Bold", pointSize: 82)
        let bytesPerRow = job.widthDots / 8
        func columnHasInk(_ column: Int) -> Bool {
            (0..<job.heightDots).contains { row in
                let byte = job.raster[8 + row * bytesPerRow + column / 8]
                return byte & UInt8(1 << (7 - column % 8)) != 0
            }
        }
        XCTAssertFalse(columnHasInk(48), "the divider between the intentionally larger lower lane and top line must remain blank")
    }

    func testExpandsEmojiShortcodesBeforeRendering() {
        XCTAssertEqual(PrinterProtocol.expandEmojiShortcodes("Hello :heart: :fire:"), "Hello ❤️ 🔥")
    }

    func testLeavesUnknownEmojiShortcodesUntouched() {
        XCTAssertEqual(PrinterProtocol.expandEmojiShortcodes(":not-real:"), ":not-real:")
    }

    func testExpandsGitHubEmojiAliasesFromBundledDataset() {
        XCTAssertEqual(PrinterProtocol.expandEmojiShortcodes(":tada: :+1: :green_heart:"), "🎉 👍 💚")
    }

    func testEmojiOnlyTextRendersInkWithScriptFont() throws {
        let empty = try PrinterProtocol.textLabel(lines: [""], fontName: "SnellRoundhand", pointSize: 82)
        let emoji = try PrinterProtocol.textLabel(lines: [":tada:"], fontName: "SnellRoundhand", pointSize: 82)
        XCTAssertGreaterThan(PrinterProtocol.inkRows(in: emoji).count, PrinterProtocol.inkRows(in: empty).count)
    }

    func testParsesPreviewWithoutAPrinterTarget() throws {
        XCTAssertEqual(
            try CLICommand.parse(["preview", "--text", "Hello", "--output", "/tmp/label.png"]),
            .previewText(lines: ["Hello"], font: "SnellRoundhand", size: 82, inverted: false, output: "/tmp/label.png")
        )
    }

    func testParsesDeviceNameForPrinterLookup() throws {
        XCTAssertEqual(
            try CLICommand.parse(["print", "--text", "Hello", "--device", "AL-1234"]),
            .printText(lines: ["Hello"], font: "SnellRoundhand", size: 82, inverted: false, address: "", device: "AL-1234")
        )
    }

    func testExplicitAddressTakesPrecedenceOverDeviceName() throws {
        XCTAssertEqual(
            try CLICommand.parse(["connect", "--device", "AL-1234", "--address", "25-00-02-00-26-c4"]),
            .connect(address: "25-00-02-00-26-c4", device: "AL-1234")
        )
    }

    func testParsesPersistentConnectCommandWithExplicitAddress() throws {
        XCTAssertEqual(try CLICommand.parse(["connect", "--address", "25-00-02-00-26-c4"]), .connect(address: "25-00-02-00-26-c4", device: nil))
    }

    func testRejectsPrinterCommandsWithoutAnAddress() {
        XCTAssertThrowsError(try CLICommand.parse(["connect"]))
    }

    func testRejectsPrintWithoutText() {
        XCTAssertThrowsError(try CLICommand.parse(["print"]))
    }

    func testRejectsUnknownCommand() {
        XCTAssertThrowsError(try CLICommand.parse(["banana"]))
    }

    func testObservedProbeCommandsMatchCapturedBytes() {
        XCTAssertEqual(PrinterProtocol.observedProbeCommands.map(\.hexString), [
            "1D6739", // serial number
            "1E4703", // hardware/version/status
            "1D6753", // printer error status
            "1D6769", // public ID
        ])
    }

    func testCanonicalCanvasMapsDirectlyToPrinterRaster() {
        let first = PrinterProtocol.canonicalToPrinterCoordinate(x: 0, y: 0)
        XCTAssertEqual(first.x, 95); XCTAssertEqual(first.y, 0)
        let last = PrinterProtocol.canonicalToPrinterCoordinate(x: 206, y: 95)
        XCTAssertEqual(last.x, 0); XCTAssertEqual(last.y, 206)
    }

    func testBlackDiagnosticFillsEveryRasterByte() {
        let job = PrinterProtocol.blackDiagnosticLabel
        XCTAssertTrue(job.raster.dropFirst(8).allSatisfy { $0 == 0xFF })
    }

    func testOverscanDiagnosticExceedsTheKnownAppCanvas() {
        let job = PrinterProtocol.overscanDiagnosticLabel
        XCTAssertEqual(job.widthDots, 96)
        XCTAssertEqual(job.heightDots, 207)
        XCTAssertTrue(job.raster.dropFirst(8).allSatisfy { $0 == 0xFF })
    }

    func testCalibrationUsesTheExactVendorReceiptProfileSequence() {
        XCTAssertEqual(PrinterProtocol.receiptCalibration.hexString, "E7BAB8E59E014C4142454C5631")
    }

    func testCursiveHelloLabelUsesTheConfirmedCanvasAndContainsInk() {
        let job = PrinterProtocol.cursiveHelloLabel15x30mm

        XCTAssertEqual(job.widthDots, 96)
        XCTAssertEqual(job.heightDots, 207)
        XCTAssertTrue(job.raster.dropFirst(8).contains { $0 != 0 })
        XCTAssertGreaterThan(PrinterProtocol.inkRows(in: job).max()!, 160, "cursive text must use the label's long axis")
        XCTAssertEqual(job.transmission.suffix(8).hexString, "4C4142454C415431")
    }

    func test15By30MillimetreTestLabelUsesCapturedReceiptProfileAndFraming() {
        let job = PrinterProtocol.testLabel15x30mm

        // These dimensions and the 8-byte LABELAT1 trailer are from the captured app print.
        XCTAssertEqual(job.widthDots, 96)
        XCTAssertEqual(job.heightDots, 207)
        XCTAssertEqual(job.raster.prefix(8).hexString, "1D7630000C00CF00")
        XCTAssertEqual(job.raster.count, 8 + (12 * 207))
        XCTAssertEqual(job.transmission.suffix(8).hexString, "4C4142454C415431")
        XCTAssertEqual(job.transmission.count, 2 + 4 + 6 + 2500)
    }
}
