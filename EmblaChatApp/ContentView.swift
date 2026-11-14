import SwiftUI

/// The launch screen for the scaffold milestone, before model setup is implemented.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Embla Chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Model setup and local chat are coming in the next milestone.")
            }
            .accessibilityIdentifier("scaffold-status")
            .navigationTitle("Embla Chat")
        }
    }
}
