import EmblaPresentation
import SwiftUI

struct QuickActionCards: View {
    let actions: [QuickAction]
    let enabled: Bool
    let select: (QuickAction) -> Void

    var body: some View {
        ActionBubbleLayout(spacing: 8) {
            ForEach(actions) { action in
                Button {
                    select(action)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(action.label).fixedSize(horizontal: false, vertical: true)
                            if action.autoSend {
                                Image(systemName: "arrow.up")
                                    .font(.caption.weight(.semibold)).accessibilityHidden(true)
                            }
                        }
                        if action.type == .skill {
                            Text(action.skill ?? "Skill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain).disabled(!enabled)
                .accessibilityLabel(action.label + (action.autoSend ? ", sends immediately" : ""))
                .accessibilityIdentifier("action-\(action.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Natural-width bubbles retain file order and wrap without a horizontal carousel.
private struct ActionBubbleLayout: Layout {
    let spacing: CGFloat

    private func arrange(width: CGFloat, subviews: Subviews) -> (
        size: CGSize, items: [(position: CGPoint, size: CGSize)]
    ) {
        var items: [(CGPoint, CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var minimumWidth: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(
                ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            items.append((CGPoint(x: x, y: y), size))
            minimumWidth = max(minimumWidth, size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (
            CGSize(
                width: max(width, minimumWidth),
                height: items.isEmpty ? 0 : y + rowHeight), items
        )
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let idealWidth = subviews.reduce(CGFloat(0)) {
            $0 + $1.sizeThatFits(.unspecified).width + spacing
        }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? idealWidth
        return arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (view, item) in zip(subviews, layout.items) {
            view.place(
                at: CGPoint(
                    x: bounds.minX + item.position.x,
                    y: bounds.minY + item.position.y),
                anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }
}

/// Human-editable JSON stays in Files; this screen loads it and reports its actual selected source.
struct QuickActionSettingsView: View {
    let actions: QuickActionsModel
    let cloud: ConversationCloudSync
    @State private var confirmStarter = false

    var body: some View {
        Form {
            Section("Configuration") {
                Text(actions.sourceDescription).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("actions-source")
                Text(
                    "Edit or copy actions.json in this Actions folder, then reload. "
                        + "The global iCloud setting selects the on-device or iCloud folder."
                )
                .font(.callout).foregroundStyle(.secondary)
                Button("Reload actions") { actions.reload(using: cloud) }
                    .disabled(actions.loading)
                Button("Create starter actions…") { confirmStarter = true }
                    .disabled(actions.loading || (cloud.enabled && !cloud.folderAccessReady))
                if actions.loading { ProgressView("Loading actions…") }
                if let error = actions.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("actions-error")
                }
            }
            Section("Behavior") {
                Text(
                    "Bubbles appear on new chats. The composer lightning button reveals them in ongoing chats. A prompt fills the composer "
                        + "for editing unless autoSend is true. Replacing a draft requires confirmation."
                )
                Text(
                    "Skill actions select a copied skill. Set autoSend to true with a nonempty prompt to send immediately; an arrow marks these actions. Registered MCP tools can run automatically when the prompt needs them."
                )
                .foregroundStyle(.secondary)
            }
            Section("Configured cards") {
                if actions.actions.isEmpty && !actions.loading { Text("No available cards.") }
                ForEach(actions.actions) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(action.label).font(.headline)
                            if action.autoSend {
                                Label("Sends immediately", systemImage: "arrow.up")
                            }
                        }
                        if action.type == .prompt {
                            if let prompt = action.prompt {
                                Text(prompt).font(.callout).textSelection(.enabled)
                            } else {
                                Text("Prompt missing in actions.json").foregroundStyle(.red)
                            }
                        } else {
                            Text(action.skill ?? "Skill reference missing").foregroundStyle(
                                .secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Quick actions")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Create starter actions?", isPresented: $confirmStarter) {
            Button("Create") { actions.createStarter(using: cloud) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Creates Actions/actions.json only if it is missing. Existing files and edits are kept."
            )
        }
    }
}
