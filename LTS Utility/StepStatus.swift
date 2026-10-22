import SwiftUI
import AppKit

enum StepStatus { case idle, inProgress, success, failure }

struct FlashStepView: View {
    var title: String
    var status: StepStatus
    var detail: AnyView? = nil

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch status {
                case .success: Circle().fill(.green)
                case .failure: Circle().fill(.red)
                case .inProgress: ProgressView().scaleEffect(0.5)
                case .idle: Circle().fill(.gray)
                }
            }
            .frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text(title)
                if let detail = detail {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
