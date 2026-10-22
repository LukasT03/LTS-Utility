import Foundation

enum FirmwareDownloader {
    static var lastFilename: String = ""

    static func download(for board: BoardType) async -> String? {
        let baseURL = "https://respooler.lts-design.com/Firmware/"
        let filename: String

        switch board {
        case .control:
            filename = "ControlBoard_V4_latest.bin"
        case .esp32:
            filename = "ESP32-WROOM-32_latest.bin"
        }

        lastFilename = filename

        guard let url = URL(string: baseURL + filename) else { return nil }

        do {
            let (tempFileURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.moveItem(at: tempFileURL, to: destination)
            return destination.path
        } catch {
            return nil
        }
    }
}
