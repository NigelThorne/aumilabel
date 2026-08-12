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
    static let observedProbeCommands: [Data] = [
        Data([0x1D, 0x67, 0x39]),
        Data([0x1E, 0x47, 0x03]),
        Data([0x1D, 0x67, 0x53]),
        Data([0x1D, 0x67, 0x69]),
    ]

    /// The AumiLabel calibration action: select receipt media then issue LABELV1.
    static let receiptCalibration = Data([0xE7, 0xBA, 0xB8, 0xE5, 0x9E, 0x01]) + Data("LABELV1".utf8)
    private static let emojiShortcodes = [
        ":heart:": "❤️", ":smile:": "😊", ":star:": "⭐", ":fire:": "🔥",
        ":thumbsup:": "👍", ":check:": "✅", ":warning:": "⚠️", ":coffee:": "☕",
        ":sparkles:": "✨", ":gift:": "🎁", ":home:": "🏠", ":party:": "🎉",
    ]

    static func expandEmojiShortcodes(_ text: String) -> String {
        emojiShortcodes.reduce(text) { result, replacement in result.replacingOccurrences(of: replacement.key, with: replacement.value) }
    }

    /// Dimensions sent by the captured AumiLabel print: 96 × 207 dots.
    static let testLabel15x30mm: PrintJob = makeTestLabel(widthDots: 96, heightDots: 207)
    static let blackDiagnosticLabel: PrintJob = makeRasterJob(widthDots: 96, heightDots: 207, pixels: Array(repeating: true, count: 96 * 207))
    static let overscanDiagnosticLabel: PrintJob = makeRasterJob(widthDots: 120, heightDots: 250, pixels: Array(repeating: true, count: 120 * 250))
    static let cursiveHelloLabel15x30mm: PrintJob = makeCursiveLabel(lines: ["Hello"], fontName: "SnellRoundhand", pointSize: 82, widthDots: 96, heightDots: 207)

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
        var pixels = Array(repeating: false, count: 96 * 207)
        let sourceOffsetX = (207 - side) / 2
        let sourceOffsetY = (96 - side) / 2
        for pixelY in 0..<side {
            for pixelX in 0..<side where rgba[(pixelY * side + pixelX) * 4] < 128 {
                // Rotate source (207×96) clockwise into printer (96×207).
                let printerX = 96 - 1 - (sourceOffsetY + pixelY)
                let printerY = sourceOffsetX + pixelX
                pixels[printerY * 96 + printerX] = true
            }
        }
        return makeRasterJob(widthDots: 96, heightDots: 207, pixels: pixels)
    }

    static func textLabel(text: String, fontName: String, pointSize: CGFloat) throws -> PrintJob {
        try textLabel(lines: [text], fontName: fontName, pointSize: pointSize)
    }

    static func textLabel(lines: [String], fontName: String, pointSize: CGFloat, inverted: Bool = false) throws -> PrintJob {
        guard NSFont(name: fontName, size: pointSize) != nil else { throw CLIError.unsupportedFont(fontName) }
        return makeCursiveLabel(lines: lines.map(expandEmojiShortcodes), fontName: fontName, pointSize: pointSize, inverted: inverted, widthDots: 96, heightDots: 207)
    }

    private static func makeCursiveLabel(lines: [String], fontName: String, pointSize: CGFloat, inverted: Bool = false, widthDots: Int, heightDots: Int) -> PrintJob {
        // Render at native printer resolution using macOS's Snell Roundhand script face.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: heightDots, pixelsHigh: widthDots,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Unable to create cursive text raster")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (inverted ? NSColor.black : NSColor.white).setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: heightDots, height: widthDots))
        // Fit each line independently along the 30 mm axis; multiple --text flags split the 15 mm width.
        let availableLong = CGFloat(heightDots - 8)
        let availableWide = CGFloat(widthDots - 8) / CGFloat(lines.count)
        for (lineIndex, line) in lines.enumerated() {
            var size = pointSize
            var font = NSFont(name: fontName, size: size)!
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inverted ? NSColor.white : NSColor.black]
            var attributedText = NSAttributedString(string: line, attributes: attributes)
            while attributedText.size().width > availableLong && size > 8 {
                size -= 1
                font = NSFont(name: fontName, size: size)!
                attributes[.font] = font
                attributedText = NSAttributedString(string: line, attributes: attributes)
            }
            let bounds = attributedText.boundingRect(with: NSSize(width: availableLong, height: availableWide), options: [.usesLineFragmentOrigin])
            let x = max(4, (CGFloat(heightDots) - bounds.width) / 2)
            // AppKit's source Y axis becomes the physical across-label axis after rotation.
            // Reverse indices so the first --text line is physically above the next one.
            let physicalLine = lines.count - 1 - lineIndex
            let y = 4 + CGFloat(physicalLine) * availableWide + (availableWide - bounds.height) / 2
            attributedText.draw(at: NSPoint(x: x, y: y))
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var pixels = Array(repeating: false, count: widthDots * heightDots)
        for printerY in 0..<heightDots {
            for printerX in 0..<widthDots {
                // Source canvas is long × wide. Map it clockwise onto printer width × long.
                guard let color = bitmap.colorAt(x: printerY, y: widthDots - 1 - printerX) else { continue }
                pixels[printerY * widthDots + printerX] = color.brightnessComponent < 0.5
            }
        }
        return makeRasterJob(widthDots: widthDots, heightDots: heightDots, pixels: pixels)
    }

    static func inkRows(in job: PrintJob) -> [Int] {
        let bytesPerRow = job.widthDots / 8
        return (0..<job.heightDots).filter { row in
            job.raster.dropFirst(8 + row * bytesPerRow).prefix(bytesPerRow).contains { $0 != 0 }
        }
    }

    private static func makeTestLabel(widthDots: Int, heightDots: Int) -> PrintJob {
        var pixels = Array(repeating: false, count: widthDots * heightDots)
        func setPixel(_ x: Int, _ y: Int) {
            guard x >= 0, x < widthDots, y >= 0, y < heightDots else { return }
            pixels[y * widthDots + x] = true
        }

        // A black border and four distinctive corner blocks make orientation obvious.
        for x in 2..<(widthDots - 2) { setPixel(x, 2); setPixel(x, heightDots - 3) }
        for y in 2..<(heightDots - 2) { setPixel(2, y); setPixel(widthDots - 3, y) }
        for origin in [(6, 6), (widthDots - 14, 6), (6, heightDots - 14), (widthDots - 14, heightDots - 14)] {
            for y in origin.1..<(origin.1 + 8) {
                for x in origin.0..<(origin.0 + 8) { setPixel(x, y) }
            }
        }

        return makeRasterJob(widthDots: widthDots, heightDots: heightDots, pixels: pixels)
    }

    private static func makeRasterJob(widthDots: Int, heightDots: Int, pixels: [Bool]) -> PrintJob {
        let bytesPerRow = widthDots / 8
        var raster = Data([0x1D, 0x76, 0x30, 0x00, UInt8(bytesPerRow), 0x00, UInt8(heightDots & 0xFF), UInt8(heightDots >> 8)])
        for y in 0..<heightDots {
            for byteIndex in 0..<bytesPerRow {
                var value: UInt8 = 0
                for bit in 0..<8 where pixels[y * widthDots + byteIndex * 8 + bit] {
                    value |= UInt8(1 << (7 - bit))
                }
                raster.append(value)
            }
        }
        return PrintJob(widthDots: widthDots, heightDots: heightDots, raster: raster)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

final class PrinterProbe: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var channel: IOBluetoothRFCOMMChannel?

    func connect(address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address) else { throw ProbeError.invalidAddress(address) }
        print("Target: \(device.name ?? "AL-26C4") (\(device.addressString ?? address))")
        var openedChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelSync(&openedChannel, withChannelID: 2, delegate: self)
        guard result == kIOReturnSuccess, let openedChannel else { throw ProbeError.connectionFailed(result) }
        channel = openedChannel
        print("Connected on RFCOMM channel 2.")
    }

    func send(_ command: Data, label: String) throws {
        guard let channel else { throw ProbeError.notConnected }
        let result = command.withUnsafeBytes { channel.writeSync(UnsafeMutableRawPointer(mutating: $0.baseAddress!), length: UInt16(command.count)) }
        guard result == kIOReturnSuccess else { throw ProbeError.writeFailed(result) }
        let summary = command.count > 32 ? "\(command.count) bytes" : command.hexString
        print("tx: \(label) (\(summary))")
    }

    func sendObservedProbes() throws {
        for command in PrinterProtocol.observedProbeCommands {
            try send(command, label: "probe")
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func calibrate() throws {
        print("Starting the vendor calibration sequence; the printer will advance labels until it finds the gap.")
        try send(PrinterProtocol.receiptCalibration, label: "calibration")
    }

    func sendPrint(job: PrintJob, description: String) throws {
        // The original app queries status immediately before every print.
        try send(Data([0x1E, 0x47, 0x03]), label: "pre-print status")
        try send(Data([0x1D, 0x67, 0x53]), label: "pre-print error status")
        Thread.sleep(forTimeInterval: 0.3)
        print("Printing one \(job.widthDots)×\(job.heightDots)-dot label: \(description)")
        try send(job.transmission, label: "print job")
    }

    func printTestLabel() throws {
        try sendPrint(job: PrinterProtocol.testLabel15x30mm, description: "border + corner blocks")
    }

    func printHello() throws {
        try sendPrint(job: PrinterProtocol.cursiveHelloLabel15x30mm, description: "large HELLO")
    }

    func printBlackDiagnostic() throws {
        try sendPrint(job: PrinterProtocol.blackDiagnosticLabel, description: "solid black current-canvas diagnostic")
    }

    func printOverscanDiagnostic() throws {
        try sendPrint(job: PrinterProtocol.overscanDiagnosticLabel, description: "solid black overscan diagnostic (120×250 dots)")
    }

    func close() { channel?.close(); channel = nil }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel, data: UnsafeMutableRawPointer, length: Int) {
        let response = Data(bytes: data, count: length)
        print("RX [\(response.hexString)] \(String(data: response, encoding: .utf8) ?? "<binary>")")
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel) { print("RFCOMM channel closed.") }
}

enum CLICommand: Equatable {
    static let defaultAddress = ProcessInfo.processInfo.environment["AUMILABEL_ADDRESS"] ?? ""
    case scan
    case status(address: String, device: String?)
    case connect(address: String, device: String?)
    case calibrate(address: String, device: String?)
    case fonts(filter: String?)
    case printBlack(address: String, device: String?)
    case printOverscan(address: String, device: String?)
    case printQR(value: String, address: String, device: String?)
    case printText(lines: [String], font: String, size: Double, inverted: Bool, address: String, device: String?)

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let action = arguments.first else { throw CLIError.usage("a command is required") }
        var values: [String: String] = [:]
        var textLines: [String] = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else { throw CLIError.usage("invalid argument: \(flag)") }
            if flag == "--invert" {
                values[flag] = "true"
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw CLIError.usage("missing value for \(flag)") }
            let value = arguments[index + 1]
            if flag == "--text" { textLines.append(value) } else { values[flag] = value }
            index += 2
        }
        let address = values["--address"] ?? defaultAddress
        let device = values["--device"]
        func requireTarget() throws -> (String, String?) {
            guard !address.isEmpty || device != nil else { throw CLIError.usage("--device or --address is required; run `aumilabel scan` first") }
            return (address, device)
        }
        switch action {
        case "scan":
            guard values.isEmpty, textLines.isEmpty else { throw CLIError.usage("scan accepts no flags") }
            return .scan
        case "status":
            guard values.keys.allSatisfy({ ["--address", "--device"].contains($0) }) else { throw CLIError.usage("status accepts --address or --device") }
            let target = try requireTarget(); return .status(address: target.0, device: target.1)
        case "connect":
            guard values.keys.allSatisfy({ ["--address", "--device"].contains($0) }) else { throw CLIError.usage("connect accepts --address or --device") }
            let target = try requireTarget(); return .connect(address: target.0, device: target.1)
        case "calibrate":
            guard values.keys.allSatisfy({ ["--address", "--device"].contains($0) }) else { throw CLIError.usage("calibrate accepts --address or --device") }
            let target = try requireTarget(); return .calibrate(address: target.0, device: target.1)
        case "fonts":
            guard values.keys.allSatisfy({ $0 == "--filter" }) else { throw CLIError.usage("fonts accepts only --filter") }
            return .fonts(filter: values["--filter"])
        case "print-black":
            guard values.keys.allSatisfy({ ["--address", "--device"].contains($0) }), textLines.isEmpty else { throw CLIError.usage("print-black accepts --address or --device") }
            let target = try requireTarget(); return .printBlack(address: target.0, device: target.1)
        case "print-overscan":
            guard values.keys.allSatisfy({ ["--address", "--device"].contains($0) }), textLines.isEmpty else { throw CLIError.usage("print-overscan accepts --address or --device") }
            let target = try requireTarget(); return .printOverscan(address: target.0, device: target.1)
        case "print": 
            guard values.keys.allSatisfy({ ["--font", "--size", "--address", "--device", "--invert", "--qr"].contains($0) }) else { throw CLIError.usage("print accepts --text, --qr, --font, --size, --invert, --address") }
            if let qr = values["--qr"] {
                guard textLines.isEmpty, !qr.isEmpty else { throw CLIError.usage("--qr cannot be combined with --text and must not be empty") }
                let target = try requireTarget(); return .printQR(value: qr, address: target.0, device: target.1)
            }
            guard !textLines.isEmpty, textLines.allSatisfy({ !$0.isEmpty }) else { throw CLIError.usage("print requires --text TEXT") }
            let size = Double(values["--size"] ?? "82")
            guard let size, size > 0 else { throw CLIError.usage("--size must be a positive number") }
            let target = try requireTarget(); return .printText(lines: textLines, font: values["--font"] ?? "SnellRoundhand", size: size, inverted: values["--invert"] == "true", address: target.0, device: target.1)
        default: throw CLIError.usage("unknown command: \(action)")
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case unsupportedFont(String)
    var description: String {
        switch self {
        case .usage(let message): message
        case .unsupportedFont(let font): "font not found: \(font); run `aumilabel fonts --filter script`"
        }
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case invalidAddress(String), connectionFailed(IOReturn), notConnected, writeFailed(IOReturn)
    var description: String {
        switch self {
        case .invalidAddress(let address): "Invalid Bluetooth address: \(address)"
        case .connectionFailed(let result): "RFCOMM connection failed (IOReturn \(result))."
        case .notConnected: "No active RFCOMM connection."
        case .writeFailed(let result): "RFCOMM write failed (IOReturn \(result))."
        }
    }
}

final class PrinterScanner: NSObject, IOBluetoothDeviceInquiryDelegate {
    let inquiry = IOBluetoothDeviceInquiry()
    override init() { super.init(); inquiry.delegate = self; inquiry.inquiryLength = 10; inquiry.updateNewDeviceNames = true }
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
        print("printer: \(device.name ?? "(unnamed)")\naddress: \(device.addressString ?? "unknown")")
    }
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) { CFRunLoopStop(CFRunLoopGetMain()) }
    func scan() throws { guard inquiry.start() == kIOReturnSuccess else { throw CLIError.usage("could not start Bluetooth scan") }; CFRunLoopRun() }
    static func resolve(_ deviceName: String) throws -> String {
        final class Finder: NSObject, IOBluetoothDeviceInquiryDelegate {
            let inquiry = IOBluetoothDeviceInquiry(); let wanted: String; var address: String?
            init(_ wanted: String) { self.wanted = wanted; super.init(); inquiry.delegate = self; inquiry.inquiryLength = 10; inquiry.updateNewDeviceNames = true }
            func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry, device: IOBluetoothDevice) {
                if device.name?.caseInsensitiveCompare(wanted) == .orderedSame { address = device.addressString; sender.stop() }
            }
            func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry, error: IOReturn, aborted: Bool) { CFRunLoopStop(CFRunLoopGetMain()) }
        }
        let finder = Finder(deviceName)
        guard finder.inquiry.start() == kIOReturnSuccess else { throw CLIError.usage("could not start Bluetooth scan") }
        CFRunLoopRun()
        guard let address = finder.address else { throw CLIError.usage("device not found: \(deviceName); put it in pairing mode and run `aumilabel scan`") }
        return address
    }
}

func printHelp() {
    print("aumilabel — print 15×30 mm labels via Bluetooth\ncommands: scan | status --address ADDRESS | connect --address ADDRESS | calibrate --address ADDRESS | print --text TEXT [--text TEXT ...] [--font NAME] [--size POINTS] [--invert] --address ADDRESS | print --qr VALUE --address ADDRESS")
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
if rawArguments.isEmpty || rawArguments == ["--help"] {
    printHelp()
    exit(0)
}
do {
    let command = try CLICommand.parse(rawArguments)
    func resolvedAddress(_ address: String, _ device: String?) throws -> String { !address.isEmpty ? address : try PrinterScanner.resolve(device!) }
    switch command {
    case .scan:
        try PrinterScanner().scan()
    case .fonts(let filter):
        let matches = NSFontManager.shared.availableFonts.filter { fontName in
            filter.map { fontName.localizedCaseInsensitiveContains($0) } ?? true
        }.sorted()
        print("fonts: \(matches.joined(separator: ", "))")
    case .status(let address, let device):
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device)); try probe.sendObservedProbes()
        RunLoop.current.run(until: Date().addingTimeInterval(2)); probe.close()
    case .connect(let address, let device):
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device)); try probe.sendObservedProbes()
        print("status: connected\nhelp: connection remains open; press Ctrl-C to disconnect")
        RunLoop.current.run()
        probe.close()
    case .calibrate(let address, let device):
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device)); try probe.calibrate()
        RunLoop.current.run(until: Date().addingTimeInterval(5)); probe.close()
    case .printBlack(let address, let device):
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device)); try probe.printBlackDiagnostic()
        RunLoop.current.run(until: Date().addingTimeInterval(5)); probe.close()
    case .printOverscan(let address, let device):
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device)); try probe.printOverscanDiagnostic()
        RunLoop.current.run(until: Date().addingTimeInterval(5)); probe.close()
    case .printQR(let value, let address, let device):
        let job = try PrinterProtocol.qrLabel(value: value)
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device))
        try probe.sendPrint(job: job, description: "QR code")
        RunLoop.current.run(until: Date().addingTimeInterval(5)); probe.close()
    case .printText(let lines, let font, let size, let inverted, let address, let device):
        let job = try PrinterProtocol.textLabel(lines: lines, fontName: font, pointSize: CGFloat(size), inverted: inverted)
        let probe = PrinterProbe(); try probe.connect(address: resolvedAddress(address, device))
        try probe.sendPrint(job: job, description: "\(lines.joined(separator: " / ")) in \(font)")
        RunLoop.current.run(until: Date().addingTimeInterval(5)); probe.close()
    }
} catch {
    print("error: \(error)")
    exit(error is CLIError ? 2 : 1)
}
