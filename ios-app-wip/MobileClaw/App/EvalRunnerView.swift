import SwiftUI

// Minimal UI surface for eval-mode launches. Mirrors android-app's
// `EvalActivity` headless Activity — no chat UI, no model picker, no
// settings. The off-device runner (`test/eval/run.py`) launches the app
// with `MOBILECLAW_EVAL_MODE=1`, sends `mobileclaw://eval?…`, and polls
// the trace file for completion. The user never sees this view in normal
// operation; it exists so eval runs don't ride on top of the regular
// `AppRouter` and can't accidentally interact with chat-side state.

struct EvalRunnerView: View {
    @State private var status = EvalRunStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()

            Text("Mobile-Claw Eval")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))

            statusPill

            if !status.prompt.isEmpty {
                Text("Prompt")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 8)
                Text(status.prompt)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .truncationMode(.tail)
            }

            if !status.modelName.isEmpty {
                Text("Model: \(status.modelName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 4)
            }

            Spacer()

            if !status.runId.isEmpty {
                Text("Trace: \(status.runId)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.4))
            }

            exitButton
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black)
    }

    // Lets the developer drop out of the headless surface after a run
    // (or before one starts) and into the normal `AppRouter` to inspect
    // chat / settings / model state. Hidden mid-run so a stray tap can't
    // tear down an in-flight eval — the off-device runner relies on the
    // trace file completing.
    @ViewBuilder
    private var exitButton: some View {
        if canExit {
            Button("Exit eval mode") {
                EvalRunStatus.shared.requestExit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var canExit: Bool {
        switch status.phase {
        case .idle, .completed, .failed: return true
        case .loadingModel, .running:    return false
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(pillColor)
                .frame(width: 10, height: 10)
            Text(pillLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }

    private var pillLabel: String {
        switch status.phase {
        case .idle:         return "Waiting for eval URL"
        case .loadingModel: return "Loading model"
        case .running:      return "Running"
        case .completed:    return "Done"
        case .failed:       return "Failed"
        }
    }

    private var pillColor: Color {
        switch status.phase {
        case .idle:         return .gray
        case .loadingModel: return .yellow
        case .running:      return .blue
        case .completed:    return .green
        case .failed:       return .red
        }
    }
}

#Preview {
    EvalRunnerView()
}
