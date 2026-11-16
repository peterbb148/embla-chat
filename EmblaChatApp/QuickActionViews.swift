import EmblaPresentation
import SwiftUI

struct QuickActionCards: View {
    let actions: [QuickAction]
    let enabled: Bool
    let select: (QuickAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(actions) { action in
                    Button {
                        select(action)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.label).lineLimit(2)
                            if action.type == .skill {
                                Text(action.skill ?? "Skill").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                        }
                        .font(.callout)
                        .frame(width: 134, alignment: .leading)
                        .padding(14)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityIdentifier("action-\(action.id)")
                }
            }
        }
        .accessibilityIdentifier("quick-action-cards")
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
                    "Cards appear on empty chats. Tapping a prompt fills the composer "
                        + "so you can edit it before sending. Replacing a draft requires confirmation."
                )
                Text(
                    "Skill actions select a copied skill. An optional prompt fills the draft; no action sends automatically. Configure and approve MCP calls separately."
                )
                .foregroundStyle(.secondary)
            }
            Section("Configured cards") {
                if actions.actions.isEmpty && !actions.loading { Text("No available cards.") }
                ForEach(actions.actions) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(action.label).font(.headline)
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
