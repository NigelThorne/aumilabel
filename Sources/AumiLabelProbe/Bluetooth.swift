import Foundation
import AppKit
import IOBluetooth

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
