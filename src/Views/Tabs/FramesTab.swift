import SwiftUI

struct FramesTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto Sampling Range")
                .font(.headline)
                .monoFont(size: 11, weight: .bold)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Start Delay")
                    Spacer()
                    Text("\(Int(state.startDelayPercent))%")
                }
                Slider(value: $state.startDelayPercent, in: 0...30, step: 1.0)
                Text("Ignores opening titles and credits.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("End Delay")
                    Spacer()
                    Text("\(Int(state.endDelayPercent))%")
                }
                Slider(value: $state.endDelayPercent, in: 0...30, step: 1.0)
                Text("Ignores end credits and black screens.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Nudge Step")
                    Spacer()
                    Text(String(format: "%g s", state.nudgeStepSeconds))
                }
                Slider(value: $state.nudgeStepSeconds, in: 0.1...10, step: 0.1)
                Text("Per-thumbnail < > time shift on hover.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .monoFont()
    }
}
