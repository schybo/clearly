import SwiftUI

struct WiskInitialSyncPlaceholderView: View {
    let kind: WiskLibraryEmptyKind
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch kind {
            case .initialSync:
                syncingStatus
            case .initialSyncFailed(let message):
                failedStatus(message: message)
            case .none, .contentUnavailable:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("wisk.notes.initialSyncStatus")
    }

    private var syncingStatus: some View {
        ContentUnavailableView {
            VStack(spacing: Spacing.md) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.pulse, options: .repeating, isActive: reduceMotion == false)
                ProgressView()
                    .controlSize(.regular)
                    .tint(Color.accent)
            }
        } description: {
            Text("Syncing your notes…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Syncing your notes")
    }

    private func failedStatus(message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't sync your notes", systemImage: "exclamationmark.icloud")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wisk.notes.initialSyncRetryButton")
        }
    }
}
