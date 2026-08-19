import Foundation
import AppKit

enum CLICommand: Equatable {
    case scan
    case status(address: String, device: String?)
    case connect(address: String, device: String?)
    case calibrate(address: String, device: String?)
    case fonts(filter: String?)
    case printBlack(address: String, device: String?)
    case printOverscan(address: String, device: String?)
    case printQR(value: String, address: String, device: String?)
    case printText(lines: [String], font: String, size: Double, inverted: Bool, address: String, device: String?)
    case previewText(lines: [String], font: String, size: Double, inverted: Bool, output: String)

    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CLICommand {
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
        let address = values["--address"] ?? environment["AUMILABEL_ADDRESS"] ?? ""
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
        case "print", "preview":
            let isPreview = action == "preview"
            let allowed = isPreview ? ["--font", "--size", "--invert", "--output"] : ["--font", "--size", "--address", "--device", "--invert", "--qr"]
            guard values.keys.allSatisfy({ allowed.contains($0) }) else { throw CLIError.usage("\(action) accepts --text, --font, --size, --invert\(isPreview ? ", --output" : ", --address, --device, --qr")") }
            if let qr = values["--qr"] {
                guard textLines.isEmpty, !qr.isEmpty else { throw CLIError.usage("--qr cannot be combined with --text and must not be empty") }
                let target = try requireTarget(); return .printQR(value: qr, address: target.0, device: target.1)
            }
            guard !textLines.isEmpty, textLines.allSatisfy({ !$0.isEmpty }) else { throw CLIError.usage("print requires --text TEXT") }
            let size = Double(values["--size"] ?? "82")
            guard let size, size > 0 else { throw CLIError.usage("--size must be a positive number") }
            let font = values["--font"] ?? environment["AUMILABEL_FONT"] ?? "SnellRoundhand"
            if isPreview {
                return .previewText(lines: textLines, font: font, size: size, inverted: values["--invert"] == "true", output: values["--output"] ?? "aumilabel-preview.png")
            }
            let target = try requireTarget(); return .printText(lines: textLines, font: font, size: size, inverted: values["--invert"] == "true", address: target.0, device: target.1)
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


func printHelp() {
    print("aumilabel — print 15×30 mm labels via Bluetooth\ncommands: scan | status --address ADDRESS | connect --address ADDRESS | calibrate --address ADDRESS | print --text TEXT [--text TEXT ...] [--font NAME] [--size POINTS] [--invert] --address ADDRESS | preview --text TEXT [--text TEXT ...] [--font NAME] [--size POINTS] [--invert] [--output FILE.png] | print --qr VALUE --address ADDRESS")
}

