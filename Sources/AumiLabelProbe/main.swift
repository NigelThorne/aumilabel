import Foundation
import AppKit

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
    case .previewText(let lines, let font, let size, let inverted, let output):
        let job = try PrinterProtocol.textLabel(lines: lines, fontName: font, pointSize: CGFloat(size), inverted: inverted)
        try PrinterProtocol.writePreviewPNG(of: job, to: output)
        print("Wrote exact \(job.widthDots)×\(job.heightDots)-dot print raster: \(output)")
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
