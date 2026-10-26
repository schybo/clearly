import Foundation

struct StructuredNote: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var templateID: String?
    var sections: [StructuredNoteSection]

    init(
        version: Int = Self.currentVersion,
        templateID: String? = nil,
        sections: [StructuredNoteSection] = []
    ) {
        self.version = version
        self.templateID = templateID
        self.sections = NoteStructuredSections.normalizedSections(sections)
    }
}

struct StructuredNoteSection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var body: String
    var isCollapsed: Bool
    var mode: StructuredNoteSectionMode
    var sortOrder: Int

    init(
        id: String = UUID().uuidString,
        title: String,
        body: String = "",
        isCollapsed: Bool = false,
        mode: StructuredNoteSectionMode = .text,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body
        self.isCollapsed = isCollapsed
        self.mode = mode
        self.sortOrder = sortOrder
    }
}

enum StructuredNoteSectionMode: String, Codable, Sendable {
    case text
    case checklist
}

struct StructuredNoteTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var sections: [StructuredNoteTemplateSection]
    var isUserDefined: Bool

    init(
        id: String,
        title: String,
        sections: [StructuredNoteTemplateSection],
        isUserDefined: Bool = false
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sections = sections
        self.isUserDefined = isUserDefined
    }
}

struct StructuredNoteTemplateSection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var placeholder: String
    var defaultCollapsed: Bool
    var defaultMode: StructuredNoteSectionMode

    init(
        id: String,
        title: String,
        placeholder: String = "",
        defaultCollapsed: Bool = false,
        defaultMode: StructuredNoteSectionMode = .text
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.placeholder = placeholder.trimmingCharacters(in: .newlines)
        self.defaultCollapsed = defaultCollapsed
        self.defaultMode = defaultMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case placeholder
        case defaultCollapsed
        case defaultMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.placeholder = try container.decode(String.self, forKey: .placeholder)
        self.defaultCollapsed = try container.decode(Bool.self, forKey: .defaultCollapsed)
        self.defaultMode = try container.decodeIfPresent(StructuredNoteSectionMode.self, forKey: .defaultMode) ?? .text
    }
}

enum NoteStructuredSections {
    static let userTemplatesKey = "wisk.structuredNote.userTemplates.v1"

    private static let headerPrefix = "<!-- wisk:structured-note"
    private static let sectionPrefix = "<!-- wisk:section"
    private static let commentSuffix = "-->"

    static let builtInTemplates: [StructuredNoteTemplate] = [
        StructuredNoteTemplate(
            id: "daily-workflow",
            title: "Daily Workflow",
            sections: [
                StructuredNoteTemplateSection(id: "everyday", title: "Everyday", placeholder: "- [ ] Respond to Friends 5 mins\n- [ ] Organize Todoist 8 mins\n- [ ] Check PRs", defaultMode: .checklist),
                StructuredNoteTemplateSection(id: "basement", title: "Basement", placeholder: "Add basement reminders or setup notes.", defaultCollapsed: true),
                StructuredNoteTemplateSection(id: "midfloor", title: "Midfloor", placeholder: "Add midfloor reminders.", defaultCollapsed: true),
                StructuredNoteTemplateSection(id: "upstairs", title: "Upstairs", placeholder: "Add upstairs reminders.", defaultCollapsed: true),
                StructuredNoteTemplateSection(id: "personal-real-life", title: "Personal Real Life", placeholder: "Add offline errands and follow-ups."),
                StructuredNoteTemplateSection(id: "personal-online", title: "Personal Online", placeholder: "- [ ] Add online admin tasks"),
                StructuredNoteTemplateSection(id: "work", title: "Work", placeholder: "Add work tasks, questions, and follow-ups."),
                StructuredNoteTemplateSection(id: "staging", title: "Staging", placeholder: "Park items that are not ready for today.", defaultCollapsed: true),
            ]
        ),
        StructuredNoteTemplate(
            id: "meeting-notes",
            title: "Meeting Notes",
            sections: [
                StructuredNoteTemplateSection(id: "agenda", title: "Agenda", placeholder: "- Topic"),
                StructuredNoteTemplateSection(id: "notes", title: "Notes", placeholder: "Capture discussion here."),
                StructuredNoteTemplateSection(id: "decisions", title: "Decisions", placeholder: "- Decision"),
                StructuredNoteTemplateSection(id: "action-items", title: "Action Items", placeholder: "- [ ] Owner - task"),
            ]
        ),
        StructuredNoteTemplate(
            id: "project-plan",
            title: "Project Plan",
            sections: [
                StructuredNoteTemplateSection(id: "goal", title: "Goal", placeholder: "What should be true when this is done?"),
                StructuredNoteTemplateSection(id: "scope", title: "Scope", placeholder: "In scope:\nOut of scope:"),
                StructuredNoteTemplateSection(id: "tasks", title: "Tasks", placeholder: "- [ ] First task"),
                StructuredNoteTemplateSection(id: "risks", title: "Risks", placeholder: "Known risks and open questions.", defaultCollapsed: true),
            ]
        ),
        StructuredNoteTemplate(
            id: "blank-sections",
            title: "Blank Sections",
            sections: [
                StructuredNoteTemplateSection(id: "notes", title: "Notes"),
                StructuredNoteTemplateSection(id: "tasks", title: "Tasks", placeholder: "- [ ] "),
            ]
        ),
    ]

    static var defaultTemplate: StructuredNoteTemplate {
        builtInTemplates[0]
    }

    static func allTemplates(userDefaults: UserDefaults = .standard) -> [StructuredNoteTemplate] {
        builtInTemplates + loadUserTemplates(userDefaults: userDefaults)
    }

    static func structuredNote(from body: String) -> StructuredNote {
        let lines = body.components(separatedBy: .newlines)
        var templateID: String?
        var sections: [StructuredNoteSection] = []
        var current: StructuredNoteSection?
        var currentBodyLines: [String] = []
        var pendingMetadata: SectionMetadata?
        var usesStructuredMetadata = false

        func finishCurrent() {
            guard var section = current else { return }
            let joinedBody = currentBodyLines.joined(separator: "\n")
            section.body = usesStructuredMetadata ? joinedBody : joinedBody.trimmingCharacters(in: .newlines)
            sections.append(section)
            current = nil
            currentBodyLines = []
        }

        func materializePendingSectionIfNeeded() {
            guard current == nil, let metadata = pendingMetadata else { return }
            current = StructuredNoteSection(
                id: uniqueID(base: metadata.id, existing: Set(sections.map(\.id))),
                title: "",
                isCollapsed: metadata.isCollapsed,
                mode: metadata.mode,
                sortOrder: sections.count
            )
            pendingMetadata = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(headerPrefix) {
                usesStructuredMetadata = true
                templateID = attributes(in: trimmed)["template"]
                continue
            }

            if trimmed.hasPrefix(sectionPrefix) {
                usesStructuredMetadata = true
                materializePendingSectionIfNeeded()
                finishCurrent()
                let parsed = attributes(in: trimmed)
                pendingMetadata = SectionMetadata(
                    id: parseSectionID(preferred: parsed["id"], title: nil, existing: sections),
                    isCollapsed: parsed["collapsed"] == "true",
                    mode: StructuredNoteSectionMode(rawValue: parsed["mode"] ?? "") ?? .text
                )
                continue
            }

            if let heading = headingTitle(from: trimmed) {
                finishCurrent()
                current = StructuredNoteSection(
                    id: parseSectionID(preferred: pendingMetadata?.id, title: heading, existing: sections),
                    title: heading,
                    isCollapsed: pendingMetadata?.isCollapsed ?? false,
                    mode: pendingMetadata?.mode ?? .text,
                    sortOrder: sections.count
                )
                pendingMetadata = nil
                continue
            }

            if current == nil, isHTMLCommentLine(trimmed) {
                continue
            }

            if current == nil, !trimmed.isEmpty {
                materializePendingSectionIfNeeded()
                if current == nil {
                    current = StructuredNoteSection(
                        id: parseSectionID(preferred: nil, title: "Notes", existing: sections),
                        title: "Notes",
                        sortOrder: sections.count
                    )
                }
            }

            if current != nil {
                currentBodyLines.append(rawLine)
            }
        }

        materializePendingSectionIfNeeded()
        finishCurrent()

        if sections.isEmpty {
            return StructuredNote(templateID: templateID, sections: [])
        }

        return StructuredNote(templateID: templateID, sections: sections)
    }

    static func body(from structuredNote: StructuredNote) -> String {
        let normalized = StructuredNote(
            version: structuredNote.version,
            templateID: structuredNote.templateID,
            sections: structuredNote.sections
        )
        var chunks = ["<!-- wisk:structured-note version=\(normalized.version) template=\(normalized.templateID ?? "custom") -->"]

        for section in normalized.sections {
            let title = section.title.structuredNilIfBlank ?? "Untitled Section"
            chunks.append("<!-- wisk:section id=\(section.id) collapsed=\(section.isCollapsed ? "true" : "false") mode=\(section.mode.rawValue) -->")
            chunks.append("## \(title)")
            if !section.body.isEmpty {
                chunks.append(section.body)
            }
        }

        return chunks.joined(separator: "\n")
    }

    static func body(from template: StructuredNoteTemplate) -> String {
        body(from: structuredNote(from: template))
    }

    static func structuredNote(from template: StructuredNoteTemplate) -> StructuredNote {
        StructuredNote(
            templateID: template.id,
            sections: template.sections.enumerated().map { index, section in
                StructuredNoteSection(
                    id: section.id,
                    title: section.title,
                    body: section.placeholder,
                    isCollapsed: section.defaultCollapsed,
                    mode: section.defaultMode,
                    sortOrder: index
                )
            }
        )
    }

    static func titleForNewNote(from template: StructuredNoteTemplate) -> String {
        template.id == "daily-workflow"
            ? Date().formatted(date: .abbreviated, time: .omitted)
            : template.title
    }

    static func isEmptyStructuredBody(_ body: String) -> Bool {
        structuredNote(from: body).sections.allSatisfy { section in
            section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func addingSection(title: String, to body: String) -> String {
        var note = structuredNote(from: body)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "New Section" : trimmed
        note.sections.append(StructuredNoteSection(
            id: uniqueID(base: slug(for: finalTitle, fallback: "section"), existing: Set(note.sections.map(\.id))),
            title: finalTitle,
            sortOrder: note.sections.count
        ))
        return self.body(from: note)
    }

    static func updatingSectionTitle(id: String, title: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.sections[index].title != trimmed else { return body }
        note.sections[index].title = trimmed
        return self.body(from: note)
    }

    static func updatingSectionBody(id: String, sectionBody: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        guard note.sections[index].body != sectionBody else { return body }
        note.sections[index].body = sectionBody
        return self.body(from: note)
    }

    static func settingSectionMode(_ mode: StructuredNoteSectionMode, id: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }),
              note.sections[index].mode != mode else {
            return body
        }

        note.sections[index].mode = mode
        note.sections[index].body = normalizedBody(note.sections[index].body, for: mode)
        return self.body(from: note)
    }

    static func appendingItem(_ text: String, toSection id: String, in body: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        let separator = note.sections[index].body.isEmpty || note.sections[index].body.hasSuffix("\n") ? "" : "\n"
        let line = note.sections[index].mode == .checklist ? "- [ ] \(trimmed)" : trimmed
        note.sections[index].body += "\(separator)\(line)"
        note.sections[index].isCollapsed = false
        return self.body(from: note)
    }

    static func checklistItems(in section: StructuredNoteSection) -> [NoteChecklistItem] {
        NoteChecklist.items(from: section.body)
    }

    static func checklistProgressSummary(for section: StructuredNoteSection) -> String {
        NoteChecklist.progressSummary(for: section.body)
    }

    static func togglingChecklistItem(at index: Int, sectionID: String, in body: String) -> String {
        updatingChecklistSection(sectionID: sectionID, in: body) { sectionBody in
            NoteChecklist.togglingItem(at: index, in: sectionBody)
        }
    }

    static func deletingChecklistItem(at index: Int, sectionID: String, in body: String) -> String {
        updatingChecklistSection(sectionID: sectionID, in: body) { sectionBody in
            NoteChecklist.deletingItem(at: index, in: sectionBody)
        }
    }

    static func togglingSection(id: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        note.sections[index].isCollapsed.toggle()
        return self.body(from: note)
    }

    static func settingSectionCollapsed(_ isCollapsed: Bool, id: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        note.sections[index].isCollapsed = isCollapsed
        return self.body(from: note)
    }

    static func deletingSection(id: String, in body: String) -> String {
        var note = structuredNote(from: body)
        guard note.sections.count > 1 else { return body }
        note.sections.removeAll { $0.id == id }
        return self.body(from: note)
    }

    static func movingSection(id: String, direction: MoveDirection, in body: String) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == id }) else { return body }
        let newIndex: Int
        switch direction {
        case .up:
            newIndex = max(index - 1, 0)
        case .down:
            newIndex = min(index + 1, note.sections.count - 1)
        }
        guard newIndex != index else { return body }
        let section = note.sections.remove(at: index)
        note.sections.insert(section, at: newIndex)
        return self.body(from: note)
    }

    static func summary(for body: String) -> String {
        let note = structuredNote(from: body)
        guard !note.sections.isEmpty else { return "No sections yet" }
        let filled = note.sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return "\(note.sections.count) section\(note.sections.count == 1 ? "" : "s") • \(filled) with notes"
    }

    static func firstSectionTitle(in body: String) -> String? {
        structuredNote(from: body).sections.first?.title.structuredNilIfBlank
    }

    static func containsStructuredMarkup(_ body: String) -> Bool {
        body.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(headerPrefix)
        }
    }

    static func isHTMLCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!--")
    }

    /// Non-empty body lines with HTML comments removed, for list previews.
    static func visibleBodyLines(in body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isHTMLCommentLine(trimmed) else { return nil }
            return trimmed
        }
    }

    static func excerpt(for body: String) -> String {
        let note = structuredNote(from: body)
        for section in note.sections {
            if let line = section.body
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .compactMap(previewLine(from:))
                .first {
                return "\(section.title): \(line)"
            }
        }
        return summary(for: body)
    }

    static func aiText(from title: String, body: String) -> String {
        let note = structuredNote(from: body)
        let sectionText = note.sections.map { section -> String in
            let body = section.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? section.title : "\(section.title)\n\(body)"
        }
        .joined(separator: "\n\n")
        return [title.structuredNilIfBlank, sectionText.structuredNilIfBlank].compactMap(\.self).joined(separator: "\n\n")
    }

    static func templateFromCurrentStructure(title: String, body: String) -> StructuredNoteTemplate? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        let note = structuredNote(from: body)
        guard !note.sections.isEmpty else { return nil }
        return StructuredNoteTemplate(
            id: uniqueTemplateID(for: trimmedTitle),
            title: trimmedTitle,
            sections: note.sections.enumerated().map { index, section in
                StructuredNoteTemplateSection(
                    id: section.id.structuredNilIfBlank ?? "section-\(index + 1)",
                    title: section.title.structuredNilIfBlank ?? "Section \(index + 1)",
                    placeholder: templatePlaceholder(for: section),
                    defaultCollapsed: section.isCollapsed,
                    defaultMode: section.mode
                )
            },
            isUserDefined: true
        )
    }

    static func saveUserTemplate(_ template: StructuredNoteTemplate, userDefaults: UserDefaults = .standard) {
        var templates = loadUserTemplates(userDefaults: userDefaults)
        templates.removeAll { $0.id == template.id || $0.title.caseInsensitiveCompare(template.title) == .orderedSame }
        var userTemplate = template
        userTemplate.isUserDefined = true
        templates.append(userTemplate)
        templates.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        guard let data = try? JSONEncoder().encode(templates) else { return }
        userDefaults.set(data, forKey: userTemplatesKey)
    }

    static func loadUserTemplates(userDefaults: UserDefaults = .standard) -> [StructuredNoteTemplate] {
        guard let data = userDefaults.data(forKey: userTemplatesKey),
              let templates = try? JSONDecoder().decode([StructuredNoteTemplate].self, from: data) else {
            return []
        }
        return templates.map {
            StructuredNoteTemplate(id: $0.id, title: $0.title, sections: $0.sections, isUserDefined: true)
        }
    }

    static func deleteUserTemplate(id: String, userDefaults: UserDefaults = .standard) {
        let templates = loadUserTemplates(userDefaults: userDefaults).filter { $0.id != id }
        guard let data = try? JSONEncoder().encode(templates) else { return }
        userDefaults.set(data, forKey: userTemplatesKey)
    }

    static func normalizedSections(_ sections: [StructuredNoteSection]) -> [StructuredNoteSection] {
        sections.enumerated().map { index, section in
            StructuredNoteSection(
                id: section.id.structuredNilIfBlank ?? "section-\(index)",
                title: section.title.structuredNilIfBlank ?? "Untitled Section",
                body: section.body,
                isCollapsed: section.isCollapsed,
                mode: section.mode,
                sortOrder: index
            )
        }
    }

    enum MoveDirection {
        case up
        case down
    }

    private struct SectionMetadata {
        let id: String
        let isCollapsed: Bool
        let mode: StructuredNoteSectionMode
    }

    private static func updatingChecklistSection(
        sectionID: String,
        in body: String,
        transform: (String) -> String
    ) -> String {
        var note = structuredNote(from: body)
        guard let index = note.sections.firstIndex(where: { $0.id == sectionID }),
              note.sections[index].mode == .checklist else {
            return body
        }
        note.sections[index].body = transform(note.sections[index].body)
        return self.body(from: note)
    }

    private static func previewLine(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHTMLCommentLine(trimmed) else { return nil }
        if headingTitle(from: trimmed) != nil { return nil }
        if let checklistText = checklistPreviewText(from: trimmed) {
            return checklistText.structuredNilIfBlank
        }
        return trimmed
    }

    private static func checklistPreviewText(from line: String) -> String? {
        guard line.first == "-" || line.first == "*" || line.first == "+" else { return nil }
        let rest = line.dropFirst().drop(while: \.isWhitespace)
        guard rest.first == "[", rest.count >= 3 else { return nil }
        let afterBracket = rest.dropFirst()
        guard let closer = afterBracket.firstIndex(of: "]") else { return nil }
        let mark = afterBracket[..<closer].trimmingCharacters(in: .whitespaces)
        guard mark.isEmpty || mark.caseInsensitiveCompare("x") == .orderedSame else { return nil }
        return String(afterBracket[afterBracket.index(after: closer)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSectionID(
        preferred: String?,
        title: String?,
        existing: [StructuredNoteSection]
    ) -> String {
        let existingIDs = Set(existing.map(\.id))
        if let preferred = preferred?.structuredNilIfBlank {
            return uniqueID(base: preferred, existing: existingIDs)
        }
        if let title = title?.structuredNilIfBlank {
            return uniqueID(base: slug(for: title, fallback: "section-\(existing.count)"), existing: existingIDs)
        }
        return uniqueID(base: existing.isEmpty ? "notes" : "section-\(existing.count)", existing: existingIDs)
    }

    private static func headingTitle(from line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func attributes(in comment: String) -> [String: String] {
        let trimmed = comment
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: commentSuffix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed
            .split(separator: " ")
            .dropFirst()
            .reduce(into: [String: String]()) { result, token in
                let parts = token.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }
    }

    private static func slug(for title: String, fallback: String) -> String {
        let slug = title
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? fallback : slug
    }

    private static func uniqueID(base: String, existing: Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private static func uniqueTemplateID(for title: String) -> String {
        "\(slug(for: title, fallback: "template"))-\(UUID().uuidString.prefix(8))"
    }

    private static func templatePlaceholder(for section: StructuredNoteSection) -> String {
        guard section.mode == .checklist else { return "" }
        return checklistItems(in: section)
            .map { "- [ ] \($0.text)" }
            .joined(separator: "\n")
    }

    private static func normalizedBody(_ body: String, for mode: StructuredNoteSectionMode) -> String {
        switch mode {
        case .checklist:
            return NoteChecklist.body(from: NoteChecklist.items(from: body))
        case .text:
            return NoteChecklist.items(from: body)
                .map(\.text)
                .joined(separator: "\n")
        }
    }
}

private extension String {
    var structuredNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
