import Foundation
import Combine

private let SERIAL_MON_DEBUG = true

private func serialMonLog(_ message: @autoclosure () -> String) {
    guard SERIAL_MON_DEBUG else { return }
    print("[SerialPortMonitor]", message())
}

private func serialMonTruncate(_ s: String, max: Int = 900) -> String {
    if s.count <= max { return s }
    let idx = s.index(s.startIndex, offsetBy: max)
    return String(s[..<idx]) + "\n…(truncated)…"
}

enum DetectedBoardKind: Equatable {
    case unknown
    case esp32DevKit
    case controlBoard

    var boardType: BoardType? {
        switch self {
        case .unknown: return nil
        case .esp32DevKit: return .esp32
        case .controlBoard: return .control
        }
    }

    var label: String {
        switch self {
        case .unknown: return "–"
        case .esp32DevKit: return "ESP32 DevKit"
        case .controlBoard: return "Control Board"
        }
    }
}

private func runEspflash(args: [String]) async -> (status: Int32, output: String) {
    await Task.detached(priority: .utility) {
        let process = Process()
        process.executableURL = Bundle.main.resourceURL?.appendingPathComponent("espflash")

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        guard process.executableURL != nil else {
            return (status: -1, output: "espflash binary not found in app bundle")
        }

        // Always skip update check to keep detection snappy.
        process.arguments = ["-S"] + args

        serialMonLog("espflash \(process.arguments?.joined(separator: " ") ?? "")")

        do {
            try process.run()
            process.waitUntilExit()

            serialMonLog("espflash exit status=\(process.terminationStatus)")
        } catch {
            return (status: -1, output: "Failed to run espflash: \(error.localizedDescription)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let outStr = String(decoding: outData, as: UTF8.self)
        let errStr = String(decoding: errData, as: UTF8.self)
        let combined = (outStr + "\n" + errStr).trimmingCharacters(in: .whitespacesAndNewlines)

        if SERIAL_MON_DEBUG {
            serialMonLog("espflash output:\n\(serialMonTruncate(combined))")
        }

        return (status: process.terminationStatus, output: combined)
    }.value
}

private func detectBoardKindViaEspflash(port: String) async -> (kind: DetectedBoardKind, rawOutput: String) {
    // Your espflash build supports `board-info` (see `espflash --help`).
    // IMPORTANT: With clap-style parsing, the command comes BEFORE its options.
    // So: espflash board-info --port /dev/cu.xxx
    let cmd: [String] = ["board-info", "--port", port]

    serialMonLog("detectBoardKindViaEspflash: port=\(port)")

    let res = await runEspflash(args: cmd)
    let bestOutput = res.output

    // If espflash couldn't talk to the target, do not guess.
    if res.status != 0 {
        return (kind: .unknown, rawOutput: bestOutput)
    }

    let upper = bestOutput.uppercased()

    // Prefer parsing the explicit chip type line (espflash prints e.g. `Chip type: esp32s3`).
    if let range = upper.range(of: "CHIP TYPE:") {
        let after = upper[range.upperBound...]
        if let lineEnd = after.firstIndex(of: "\n") {
            let line = after[..<lineEnd]
            // Extract the first contiguous token after the label.
            let token = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" })
                .first
                .map(String.init) ?? ""

            // Normalize token like `ESP32S3` / `ESP32`.
            let chip = token.replacingOccurrences(of: "-", with: "")

            if chip == "ESP32" {
                return (kind: .esp32DevKit, rawOutput: bestOutput)
            }

            // Treat any ESP32-* variant as a "Control Board" target for the flasher's purposes.
            // (Your Control Board is ESP32-S3; other variants will still not be "plain ESP32".)
            if chip.hasPrefix("ESP32") {
                return (kind: .controlBoard, rawOutput: bestOutput)
            }
        }
    }

    // Fallback: detect by common chip strings with/without hyphens.
    let normalized = upper.replacingOccurrences(of: "-", with: "")

    // Explicit variants => Control Board.
    if normalized.contains("ESP32S2") ||
        normalized.contains("ESP32S3") ||
        normalized.contains("ESP32C3") ||
        normalized.contains("ESP32C6") ||
        normalized.contains("ESP32H2") ||
        normalized.contains("ESP32P4") {
        return (kind: .controlBoard, rawOutput: bestOutput)
    }

    // Plain ESP32 => DevKit.
    if normalized.contains("ESP32") {
        return (kind: .esp32DevKit, rawOutput: bestOutput)
    }

    // Some outputs omit the literal "ESP32" string.
    if normalized.contains("XTENSA") || normalized.contains("LX6") || normalized.contains("WROOM") || normalized.contains("D0WD") {
        return (kind: .esp32DevKit, rawOutput: bestOutput)
    }

    return (kind: .unknown, rawOutput: bestOutput)
}

@MainActor
class SerialPortMonitor: ObservableObject {
    @Published var selectedDevice: String? = nil
    @Published var availableDevices: [String] = []

    @Published var detectedBoardKind: DetectedBoardKind = .unknown
    @Published var isDetectingBoard: Bool = false
    @Published var lastDetectionLog: String = ""

    var deviceFound: Bool {
        selectedDevice != nil
    }

    private var timer: Timer?

    private var detectTask: Task<Void, Never>?
    private var lastDetectedPort: String? = nil

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let ports = listAllSerialPorts()
                self.availableDevices = ports

                if SERIAL_MON_DEBUG {
                    serialMonLog("ports=\(ports)")
                }

                if self.selectedDevice == nil || (self.selectedDevice != nil && !ports.contains(self.selectedDevice!)) {
                    let old = self.selectedDevice
                    self.selectedDevice = ports.first
                    serialMonLog("selectedDevice changed: \(old ?? "nil") -> \(self.selectedDevice ?? "nil")")
                }

                self.scheduleBoardDetectionIfNeeded()
            }
        }
    }

    func stopMonitoring() {
        serialMonLog("stopMonitoring")
        timer?.invalidate()
        timer = nil
        detectTask?.cancel()
        detectTask = nil
    }

    func forceDetectBoardNow() {
        lastDetectedPort = nil
        scheduleBoardDetectionIfNeeded(force: true)
    }

    private func scheduleBoardDetectionIfNeeded(force: Bool = false) {
        serialMonLog("scheduleBoardDetectionIfNeeded(force=\(force)) selected=\(selectedDevice ?? "nil") lastDetected=\(lastDetectedPort ?? "nil") currentKind=\(detectedBoardKind.label)")

        guard let port = selectedDevice, !port.isEmpty else {
            detectedBoardKind = .unknown
            lastDetectionLog = ""
            isDetectingBoard = false
            lastDetectedPort = nil
            detectTask?.cancel()
            detectTask = nil
            return
        }

        if !force, lastDetectedPort == port {
            // If we already have a result, keep it.
            if detectedBoardKind != .unknown { return }
            // If a detection is already running for this port, don't start another one.
            if isDetectingBoard { return }
            if detectTask != nil { return }
        }

        lastDetectedPort = port
        detectTask?.cancel()
        detectTask = nil

        isDetectingBoard = true
        detectedBoardKind = .unknown
        lastDetectionLog = ""

        serialMonLog("starting detection task for port=\(port)")

        detectTask = Task { [port] in
            // Give macOS a moment to settle when a USB device appears.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            serialMonLog("running espflash board-info for \(port)")
            let res = await detectBoardKindViaEspflash(port: port)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.selectedDevice == port else { return }
                serialMonLog("detection result for \(port): \(res.kind.label)")
                self.detectedBoardKind = res.kind
                self.lastDetectionLog = res.rawOutput
                if SERIAL_MON_DEBUG {
                    serialMonLog("lastDetectionLog:\n\(serialMonTruncate(res.rawOutput))")
                }
                self.isDetectingBoard = false
            }
        }
    }
}

func findUSBDevice() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", "ls /dev/cu.* | grep -E 'usbserial|wchusbserial|cp210|usbmodem|ch34' | head -n1"]

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    } catch {
        return nil
    }
}

func listAllSerialPorts() -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", "ls /dev/cu.* | grep -E 'usbserial|wchusbserial|cp210|usbmodem|ch34'"]

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return output.split(separator: "\n").map { String($0) }
    } catch {
        return []
    }
}
