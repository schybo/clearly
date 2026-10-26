#if DEBUG
import Foundation

enum ScreenshotSeed {
    static var isActive: Bool {
        ProcessInfo.processInfo.environment["WISK_SCREENSHOT_MODE"] == "1"
    }

    static let sampleNoteTitle = "Tuesday review"
    static let sampleNoteBody = """
    Invite Alex Peats Bond
    [ ] Glasses Round wire rim
    SplitTab issues
    Disclosure comments respond
    Thorble live ad mob
    HTML Builder in Saffron
    Learned UserMoment -> UserEvent hardening needs two weeks
    """

    static var sampleParsedItems: [ParsedNoteItemDraft] {
        [
            ParsedNoteItemDraft(rawText: "Invite Alex Peats Bond", title: "Invite Alex Peats Bond", itemType: .action, confidence: 0.88, sourceLineIndex: 0, people: ["Alex"]),
            ParsedNoteItemDraft(rawText: "Disclosure comments respond", title: "Respond to disclosure comments", itemType: .action, confidence: 0.82, sourceLineIndex: 3, project: "Disclosure"),
            ParsedNoteItemDraft(rawText: "Learned UserMoment -> UserEvent hardening needs two weeks", title: "UserMoment to UserEvent hardening likely needs two weeks", itemType: .learning, confidence: 0.91, sourceLineIndex: 6, project: "Saffron"),
        ]
    }
}
#endif
