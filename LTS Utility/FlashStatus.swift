import SwiftUI
import AppKit

enum FlashStatus {
    case idle, downloading, downloaded, flashed, downloadFailed, flashFailed

    var downloadIndicator: StepStatus {
        switch self {
        case .downloading: return .inProgress
        case .downloaded: return .success
        case .downloadFailed: return .failure
        default: return .idle
        }
    }

    var flashSuccessIndicator: StepStatus {
        switch self {
        case .flashed: return .success
        case .flashFailed: return .failure
        default: return .idle
        }
    }
}

enum BoardType: String, CaseIterable, Identifiable {
    case esp32 = "ESP32"
    case control = "Control Board"
    var id: String { rawValue }
}
