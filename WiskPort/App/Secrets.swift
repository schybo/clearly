import Foundation

enum Secrets {
    /// Dev-default credentials are intentionally blank in the WiskNext sandbox.
    /// Inject locally (env / untracked config) rather than committing keys —
    /// GitHub push protection blocks any committed secret.
    static let openAIAPIKey: String? = nil
    static let postHogAPIKey: String = ""
}
