import SwiftUI
import AppKit

enum RespoolerVariant: String, CaseIterable, Identifiable {
    case v4  = "Respooler V4"
    case pro = "Respooler Pro"
    case universal = "Universell"

    var id: String { rawValue }
}
struct MainFlasherView: View {
    @StateObject private var portMonitor = SerialPortMonitor()
    @State private var respoolerVariant: RespoolerVariant = .v4
    @State private var status: FlashStatus = .idle
    @State private var isFlashing = false
    @State private var progress: Double = 0.0
    @State private var latestFirmwareVersion: String = "0.0.0"
    @State private var shouldRefreshLatest = true
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Neuste Firmware Version: \(latestFirmwareVersion)")
                Spacer()
            }
            
            Picker("Variant", selection: $respoolerVariant) {
                Text("Respooler V4").tag(RespoolerVariant.v4)
                Text("Respooler Pro").tag(RespoolerVariant.pro)
                Text("U").tag(RespoolerVariant.universal)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            
            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 14) {
                    FlashStepView(title: NSLocalizedString("step_device_found", comment: ""), status: portMonitor.deviceFound ? .success : .failure, detail: AnyView(Text("Port: ") + Text(portMonitor.selectedDevice ?? "–")))
                    FlashStepView(
                        title: NSLocalizedString("step_firmware_downloaded", comment: ""),
                        status: status.downloadIndicator == .idle ? status.flashSuccessIndicator : status.downloadIndicator,
                        detail: AnyView(Text("Datei: ") + Text((status == .downloaded || status == .flashed) ? FirmwareDownloader.lastFilename : "–"))
                    )
                    FlashStepView(
                        title: NSLocalizedString("step_installation_running", comment: ""),
                        status: isFlashing ? .inProgress : status.flashSuccessIndicator,
                        detail: AnyView(
                            Group {
                                if isFlashing {
                                    Text("Fortschritt:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .overlay(
                                            ProgressView(value: progress)
                                                .progressViewStyle(.linear)
                                                .frame(width: 179, height: 4)
                                                .offset(x: 60, y: 5),
                                            alignment: .topLeading
                                        )
                                } else if status == .flashed {
                                    Text("Fortschritt: fertig!")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Fortschritt: –")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        )
                    )
                    FlashStepView(title: NSLocalizedString("step_successful", comment: ""), status: status.flashSuccessIndicator)
                }
                Spacer()
            }

            Spacer()

            HStack {
                if portMonitor.availableDevices.count > 1 {
                    Picker("Port:", selection: $portMonitor.selectedDevice) {
                        ForEach(portMonitor.availableDevices, id: \.self) { port in
                            Text(port).tag(Optional(port))
                        }
                    }
                    .pickerStyle(.menu)
                    .focusable(false)
                }
                Spacer()
                Button(portMonitor.availableDevices.count > 1 ? "Installieren" : "Herunterladen und installieren") {
                    Task {
                        await startFlashing()
                    }
                }
                .padding(.bottom, 2)
                .buttonStyle(.borderedProminent)
                .disabled(!portMonitor.deviceFound || portMonitor.isDetectingBoard || portMonitor.detectedBoardKind == .unknown || isFlashing)
            }
        }
        .padding (20)
        .task {
            await refreshLatestLoop()
        }
        .onDisappear {
            shouldRefreshLatest = false
        }
    }

    func startFlashing() async {
        guard let port = portMonitor.selectedDevice else {
            status = .flashFailed
            return
        }
        
        guard let detectedBoard = portMonitor.detectedBoardKind.boardType else {
            status = .flashFailed
            return
        }

        status = .downloading
        guard let bin = await FirmwareDownloader.download(for: detectedBoard) else {
            status = .downloadFailed
            return
        }
        status = .downloaded
        progress = 0.0
        isFlashing = true
        Task {
            let totalDuration: Double = (detectedBoard == .control) ? 14.5 : 26.0
            let interval: Double = 0.5
            var elapsed: Double = 0.0
            while isFlashing && elapsed < totalDuration {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                elapsed += interval
                let fraction = min(elapsed / totalDuration, 1.0)
                await MainActor.run { progress = fraction }
            }
        }
        let success = await ESP32Flasher.flash(binPath: bin, port: port, variant: respoolerVariant)
        isFlashing = false
        status = success ? .flashed : .flashFailed
        progress = success ? 1.0 : progress
        if !success { progress = 0.0 }
    }
    private func refreshLatestLoop() async {
        await fetchLatestFirmware()
        while shouldRefreshLatest && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await fetchLatestFirmware()
        }
    }

    @MainActor private func setLatest(_ value: String) {
        latestFirmwareVersion = value.isEmpty ? "0.0.0" : value
    }

    private func fetchLatestFirmware() async {
        guard let url = URL(string: "https://respooler.lts-design.com/Firmware/latest_board_firmware.txt") else {
            await MainActor.run { setLatest("0.0.0") }
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let raw = String(data: data, encoding: .utf8) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { setLatest(trimmed.isEmpty ? "0.0.0" : trimmed) }
            } else {
                await MainActor.run { setLatest("0.0.0") }
            }
        } catch {
            await MainActor.run { setLatest("0.0.0") }
        }
    }
}
