#if os(iOS)
import Foundation

enum PlaudTranscriptImportService {
    static func makeNote(from context: PlaudImportedNoteContext) -> Note {
        let title = title(for: context)
        let body = body(for: context)
        let kind = noteKind(for: context.noteType)
        let note = Note(
            title: title,
            body: body,
            kind: kind,
            dailyDate: context.noteType == .daily ? context.recording.createdAt : nil
        )
        note.markdownEnabled = context.noteType != .list && context.noteType != .tracker
        note.tags = [NoteTag(name: "plaud", suggestedByAI: false, note: note)]
        if let bucketID = context.bucketID {
            note.parsedItems = [
                ParsedNoteItem(
                    rawText: context.transcript.text,
                    title: title,
                    itemType: .reference,
                    confidence: 1,
                    sourceLineIndex: 0,
                    bucketId: bucketID.uuidString,
                    bucketReason: "Imported from Plaud\(context.bucketName.map { " into \($0)" } ?? "").",
                    note: note
                ),
            ]
        }
        note.snapshotIfNeeded(reason: "plaud-import")
        return note
    }

    private static func title(for context: PlaudImportedNoteContext) -> String {
        let firstLine = context.transcript.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let fallback = "Plaud recording \(context.recording.createdAt.formatted(date: .abbreviated, time: .shortened))"
        guard let firstLine else { return fallback }
        let words = firstLine.split(separator: " ").prefix(8).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")).nilIfBlank ?? fallback
    }

    private static func body(for context: PlaudImportedNoteContext) -> String {
        switch context.noteType {
        case .general, .daily:
            return markdownBody(for: context)
        case .structured:
            return structuredBody(for: context)
        case .list:
            return checklistBody(for: context)
        case .tracker:
            return trackerBody(for: context)
        }
    }

    private static func noteKind(for type: PlaudImportNoteType) -> NoteKind {
        switch type {
        case .general: .general
        case .structured: .structured
        case .list: .list
        case .tracker: .tracker
        case .daily: .daily
        }
    }

    private static func markdownBody(for context: PlaudImportedNoteContext) -> String {
        [
            metadataBlock(for: context),
            "## Transcript",
            speakerLabeledTranscript(context.transcript),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func structuredBody(for context: PlaudImportedNoteContext) -> String {
        let note = StructuredNote(
            templateID: "meeting-notes",
            sections: [
                StructuredNoteSection(id: "context", title: "Context", body: metadataBlock(for: context), sortOrder: 0),
                StructuredNoteSection(id: "notes", title: "Notes", body: speakerLabeledTranscript(context.transcript), sortOrder: 1),
                StructuredNoteSection(id: "decisions", title: "Decisions", body: "", sortOrder: 2),
                StructuredNoteSection(id: "action-items", title: "Action Items", body: "- [ ] Review Plaud transcript", mode: .checklist, sortOrder: 3),
            ]
        )
        return NoteStructuredSections.body(from: note)
    }

    private static func checklistBody(for context: PlaudImportedNoteContext) -> String {
        let lines = context.transcript.text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let items = (lines.isEmpty ? ["Review Plaud transcript"] : Array(lines.prefix(12))).map {
            NoteChecklistItem(text: $0, isCompleted: false)
        }
        return NoteChecklist.body(from: NoteChecklistList(items: items))
    }

    private static func trackerBody(for context: PlaudImportedNoteContext) -> String {
        let counter = NoteTracker.Counter(name: "Recorded minutes", sortOrder: 0)
        let durationMinutes = max((context.transcript.duration ?? context.recording.duration ?? 0) / 60, 0)
        let tracker = NoteTracker(
            unitLabel: "minutes",
            counters: [counter],
            events: durationMinutes > 0
                ? [NoteTracker.Event(counterID: counter.id, amount: durationMinutes, memo: "Plaud import")]
                : []
        )
        return NoteTrackerStore.body(from: tracker)
    }

    private static func metadataBlock(for context: PlaudImportedNoteContext) -> String {
        var lines = [
            "Source: Plaud",
            "Session ID: \(context.recording.sessionId)",
            "Recorded: \(context.recording.createdAt.formatted(date: .abbreviated, time: .shortened))",
            "Imported: \(context.importedAt.formatted(date: .abbreviated, time: .shortened))",
        ]
        if let deviceSerialNumber = context.recording.deviceSerialNumber {
            lines.append("Device: \(deviceSerialNumber)")
        }
        if let bucketName = context.bucketName {
            lines.append("Bucket: \(bucketName)")
        }
        if let duration = context.transcript.duration ?? context.recording.duration {
            lines.append("Duration: \(duration.formattedDuration)")
        }
        return lines.joined(separator: "\n")
    }

    private static func speakerLabeledTranscript(_ transcript: PlaudTranscript) -> String {
        guard !transcript.segments.isEmpty else {
            return transcript.text
        }
        return transcript.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment in
                let speaker = segment.speaker?.nilIfBlank ?? "Speaker"
                return "**\(speaker):** \(segment.text)"
            }
            .joined(separator: "\n\n")
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = Int(self.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            return "\(hours)h \(minutes % 60)m"
        }
        return "\(minutes)m \(seconds)s"
    }
}
#endif
