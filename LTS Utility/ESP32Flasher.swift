import Foundation
import Darwin

private func portIsPresent(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

private actor DataAccumulator {
    private var data = Data()
    func append(_ d: Data) { data.append(d) }
    func snapshot() -> Data { data }
}

private func runEspflashCommand(_ args: [String]) async -> Int32 {
    guard let tool = Bundle.main.resourceURL?.appendingPathComponent("espflash") else { return -1 }

    return await Task.detached(priority: .utility) {
        let process = Process()
        process.executableURL = tool
        // Skip update check for faster UX.
        process.arguments = ["-S"] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("espflash: Failed to run command \(args.joined(separator: " ")) — \(error.localizedDescription)")
            return -1
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(decoding: outData, as: UTF8.self)
        let errStr = String(decoding: errData, as: UTF8.self)
        let combined = (outStr + "\n" + errStr).trimmingCharacters(in: .whitespacesAndNewlines)

        if !combined.isEmpty {
            print("espflash (cmd output)\n", combined)
        }

        return process.terminationStatus
    }.value
}

private func setSerial115200Raw(_ fd: Int32) -> Bool {
    var tio = termios()
    if tcgetattr(fd, &tio) != 0 { return false }

    // Raw-ish mode.
    cfmakeraw(&tio)

    // 8N1, local, read enable.
    tio.c_cflag |= (UInt(CLOCAL) | UInt(CREAD))
    tio.c_cflag &= ~UInt(CSTOPB)
    tio.c_cflag &= ~UInt(PARENB)
    tio.c_cflag &= ~UInt(CSIZE)
    tio.c_cflag |= UInt(CS8)

    // 115200 baud.
    if cfsetispeed(&tio, speed_t(B115200)) != 0 { return false }
    if cfsetospeed(&tio, speed_t(B115200)) != 0 { return false }

    // Non-blocking writes are fine; reads not used.
    tio.c_cc.16 = 0 // VMIN
    tio.c_cc.17 = 0 // VTIME

    if tcsetattr(fd, TCSANOW, &tio) != 0 { return false }
    tcflush(fd, TCIOFLUSH)
    return true
}

private func writeVariantOverSerial(port: String, variant: RespoolerVariant) -> Bool {
    // "Universell" => no configuration write.
    guard variant != .universal else { return true }

    let payload: String
    switch variant {
    case .pro:
        payload = "{\"SET\":{\"VAR\":\"PRO\"}}\n"
    case .v4:
        payload = "{\"SET\":{\"VAR\":\"STD\"}}\n"
    case .universal:
        payload = ""
    }

    let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 {
        print("serial: Failed to open \(port) — \(String(cString: strerror(errno)))")
        return false
    }
    defer { close(fd) }

    guard setSerial115200Raw(fd) else {
        print("serial: Failed to configure \(port) at 115200")
        return false
    }

    let bytes = Array(payload.utf8)
    let written = bytes.withUnsafeBytes { ptr -> Int in
        guard let base = ptr.baseAddress else { return -1 }
        return Darwin.write(fd, base, ptr.count)
    }

    if written <= 0 {
        print("serial: Write failed on \(port) — \(String(cString: strerror(errno)))")
        return false
    }

    // Give the target a moment to consume the line.
    tcdrain(fd)
    return true
}

enum ESP32Flasher {
    static func flash(binPath: String, port: String, variant: RespoolerVariant = .universal) async -> Bool {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("espflash") else { return false }
        guard FileManager.default.fileExists(atPath: binPath) else { return false }
        guard portIsPresent(port) else {
            print("espflash: Port '\(port)' not present at launch time.")
            return false
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "-S",
            "write-bin",
            "--baud", "921600",
            "--port", port,
            "0x0", binPath
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = nil
        process.environment = ProcessInfo.processInfo.environment

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let accumulator = DataAccumulator()

        outHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty {
                Task { await accumulator.append(data) }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    print("espflash ⟶", chunk)
                }
            }
        }
        errHandle.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty {
                Task { await accumulator.append(data) }
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    print("espflash (stderr) ⟶", chunk)
                }
            }
        }

        do {
            try process.run()

            let status: Int32 = await withCheckedContinuation { cont in
                process.terminationHandler = { p in
                    outHandle.readabilityHandler = nil
                    errHandle.readabilityHandler = nil
                    try? outHandle.close()
                    try? errHandle.close()
                    cont.resume(returning: p.terminationStatus)
                }
            }

            if !portIsPresent(port) {
                print("espflash: Port '\(port)' disappeared during flashing (post-termination check).")
            }
            print("espflash termination — reason: \(process.terminationReason == .exit ? "exit" : "uncaughtSignal"), status: \(status)")

            let collectedData = await accumulator.snapshot()
            let output = String(decoding: collectedData, as: UTF8.self)
            print("espflash output (final)\n", output)
            if status == 0 {
                // Apply Respooler variant config (matches the Web Flasher JS):
                // PRO => {"SET":{"VAR":"PRO"}}\n
                // STD (V4) => {"SET":{"VAR":"STD"}}\n
                // Universal => do nothing.
                if variant != .universal {
                    print("espflash: Applying variant config: \(variant.rawValue)")

                    // Reset once to boot the freshly flashed firmware.
                    _ = await runEspflashCommand(["reset", "--port", port])
                    try? await Task.sleep(nanoseconds: 500_000_000)

                    let wrote = writeVariantOverSerial(port: port, variant: variant)
                    if !wrote {
                        print("espflash: Warning — failed to write VAR over serial")
                    }

                    try? await Task.sleep(nanoseconds: 150_000_000)
                    _ = await runEspflashCommand(["reset", "--port", port])
                }
            }
            return status == 0
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            try? outHandle.close()
            try? errHandle.close()

            let present = portIsPresent(port)
            print("espflash: Failed to start process — error: \(error.localizedDescription). Port present: \(present ? "yes" : "no")")
            return false
        }
    }
}
