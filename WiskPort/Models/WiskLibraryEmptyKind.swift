import Foundation

enum WiskLibraryEmptyKind: Equatable, Hashable {
    case none
    case initialSync
    case initialSyncFailed(String)
    case contentUnavailable

    /// Decides whether an empty notes library should show first-sync status,
    /// a first-sync failure, or the usual “no notes” empty copy.
    ///
    /// First sync is “this device has no completed watermark for the signed-in
    /// account,” not “a 45s poll is currently running.”
    @MainActor
    static func resolve(
        hasVisibleNotes: Bool,
        isUnfilteredLibrary: Bool,
        isSignedIn: Bool,
        hasCompletedAccountSync: Bool,
        syncState: SyncService.State
    ) -> WiskLibraryEmptyKind {
        if hasVisibleNotes {
            return .none
        }
        if isUnfilteredLibrary == false || isSignedIn == false || hasCompletedAccountSync {
            return .contentUnavailable
        }
        if case .failed(let message) = syncState {
            return .initialSyncFailed(message)
        }
        return .initialSync
    }
}
