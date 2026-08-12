import XCTest
@testable import AumiLabelProbe

final class ProtocolTests: XCTestCase {
    func testParsesRepeatedTextArgumentsAsLines() throws {
        let command = try CLICommand.parse(["print", "--text", "Nigel", "--text", "Cath", "--font", "SignPainter", "--size", "72"])
        XCTAssertEqual(command, .printText(lines: ["Nigel", "Cath"], font: "SignPainter", size: 72, inverted: false, address: CLICommand.defaultAddress))
    }

    func testParsesQRCodePrintFlag() throws {
        let command = try CLICommand.parse(["print", "--qr", "https://example.com"])
        XCTAssertEqual(command, .printQR(value: "https://example.com", address: CLICommand.defaultAddress))
    }

    func testQRCodeLabelUsesConfirmedCanvasAndContainsInk() throws {
        let job = try PrinterProtocol.qrLabel(value: "https://example.com")
        XCTAssertEqual(job.widthDots, 96)
        XCTAssertEqual(job.heightDots, 207)
        XCTAssertTrue(job.raster.dropFirst(8).contains { $0 != 0 })
    }

    func testParsesInvertPrintFlag() throws {
        let command = try CLICommand.parse(["print", "--text", "Nigel", "--invert"])
        XCTAssertEqual(command, .printText(lines: ["Nigel"], font: "SnellRoundhand", size: 82, inverted: true, address: CLICommand.defaultAddress))
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

    func testParsesPersistentConnectCommand() throws {
        XCTAssertEqual(try CLICommand.parse(["connect"]), .connect(address: CLICommand.defaultAddress))
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

    func testBlackDiagnosticFillsEveryRasterByte() {
        let job = PrinterProtocol.blackDiagnosticLabel
        XCTAssertTrue(job.raster.dropFirst(8).allSatisfy { $0 == 0xFF })
    }

    func testOverscanDiagnosticExceedsTheKnownAppCanvas() {
        let job = PrinterProtocol.overscanDiagnosticLabel
        XCTAssertEqual(job.widthDots, 120)
        XCTAssertEqual(job.heightDots, 250)
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
