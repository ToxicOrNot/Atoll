import SwiftUI

struct CodexApprovalCard: View {
    let request: CodexApprovalManager.Request
    let onDecision: (CodexApprovalManager.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex approval required", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(.white)
            Text("\(request.tool) · \(request.directory)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.directory)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let reason = request.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.callout)
                    }
                    Text(request.detail)
                        .font(.system(.caption, design: .monospaced))
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 104)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button("Defer to Codex") { onDecision(.deferToCodex) }
                    .help("Continue with the usual Codex approval prompt")
                Spacer()
                Button("Deny", role: .destructive) { onDecision(.deny) }
                Button("Allow once") { onDecision(.allow) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
