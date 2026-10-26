import SwiftUI

struct MacEmptyEditorView: View {
    let createNote: () -> Void
    let createStructuredNote: () -> Void
    let createList: () -> Void
    let createTracker: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let clusterWidth = min(Self.clusterMaxWidth, max(geometry.size.width - 48, 0))
            VStack(spacing: Spacing.xl) {
                header
                cardGrid(clusterWidth: clusterWidth)
            }
            .frame(width: clusterWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.xl)
        }
        .wiskEditorCanvas()
    }

    private var header: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accent.opacity(0.10))
                    .frame(width: 44, height: 44)
                Image(systemName: "note.text")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accent)
            }
            .accessibilityHidden(true)

            VStack(spacing: Spacing.sm) {
                Text("Start writing")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.wiskPrimaryText)
                Text("Select a note from the list, or create one below.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.wiskSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
    }

    private func cardGrid(clusterWidth: CGFloat) -> some View {
        let spacing = Spacing.md
        let columns: [GridItem] = clusterWidth >= Self.twoColumnMinWidth
            ? [
                GridItem(.flexible(minimum: 160), spacing: spacing),
                GridItem(.flexible(minimum: 160), spacing: spacing),
            ]
            : [GridItem(.flexible(minimum: 160))]

        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(actions) { action in
                MacEmptyCreateCard(action: action)
            }
        }
    }

    private var actions: [MacEmptyCreateAction] {
        [
            MacEmptyCreateAction.newNote(action: createNote),
            MacEmptyCreateAction(
                title: "Structured",
                accessibilityLabel: "New Structured Note",
                caption: "Sections and templates",
                systemImage: "rectangle.stack",
                shortcutLabel: "⇧⌘N",
                isEmphasized: false,
                accessibilityIdentifier: "wisk.mac.empty.createStructured",
                key: "n",
                modifiers: [.command, .shift],
                assignsKeyboardShortcut: true,
                action: createStructuredNote
            ),
            MacEmptyCreateAction(
                title: "List",
                accessibilityLabel: "New List",
                caption: "Checklist",
                systemImage: "checklist",
                shortcutLabel: "⌥⇧⌘L",
                isEmphasized: false,
                accessibilityIdentifier: "wisk.mac.empty.createList",
                key: "l",
                modifiers: [.command, .option, .shift],
                assignsKeyboardShortcut: true,
                action: createList
            ),
            MacEmptyCreateAction(
                title: "Tracker",
                accessibilityLabel: "New Tracker",
                caption: "Recurring items",
                systemImage: "plus.forwardslash.minus",
                shortcutLabel: "⇧⌘T",
                isEmphasized: false,
                accessibilityIdentifier: "wisk.mac.empty.createTracker",
                key: "t",
                modifiers: [.command, .shift],
                assignsKeyboardShortcut: true,
                action: createTracker
            ),
        ]
    }

    private static let clusterMaxWidth: CGFloat = 480
    private static let twoColumnMinWidth: CGFloat = 400
}

struct MacEmptyCreateAction: Identifiable {
    var id: String { accessibilityIdentifier }
    let title: String
    let accessibilityLabel: String
    let caption: String
    let systemImage: String
    let shortcutLabel: String
    let isEmphasized: Bool
    let accessibilityIdentifier: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let assignsKeyboardShortcut: Bool
    let action: () -> Void

    static func newNote(
        accessibilityIdentifier: String = "wisk.mac.empty.createNote",
        assignsKeyboardShortcut: Bool = true,
        action: @escaping () -> Void
    ) -> MacEmptyCreateAction {
        MacEmptyCreateAction(
            title: "Note",
            accessibilityLabel: "New Note",
            caption: "Plain text",
            systemImage: "square.and.pencil",
            shortcutLabel: "⌘N",
            isEmphasized: true,
            accessibilityIdentifier: accessibilityIdentifier,
            key: "n",
            modifiers: .command,
            assignsKeyboardShortcut: assignsKeyboardShortcut,
            action: action
        )
    }
}

struct MacEmptyCreateCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let action: MacEmptyCreateAction

    var body: some View {
        Button(action: action.action) {
            HStack(alignment: .top, spacing: Spacing.md) {
                iconWell
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text(action.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.wiskPrimaryText)
                            .lineLimit(1)
                        Spacer(minLength: Spacing.xs)
                        shortcutChip
                    }
                    Text(action.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.wiskSecondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(cardFill)
            .overlay(cardStroke)
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(MacEmptyCreateShortcutModifier(
            key: action.key,
            modifiers: action.modifiers,
            enabled: action.assignsKeyboardShortcut
        ))
        .onHover { hovering in
            AppMotion.perform(reduceMotion: reduceMotion, animation: AppMotion.macQuick) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(action.accessibilityLabel)
        .accessibilityHint(action.caption)
        .accessibilityIdentifier(action.accessibilityIdentifier)
        .help("\(action.accessibilityLabel) (\(action.shortcutLabel))")
    }

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(action.isEmphasized ? Color.accent.opacity(0.14) : Color.primary.opacity(0.06))
                .frame(width: 28, height: 28)
            Image(systemName: action.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(action.isEmphasized ? Color.accent : Color.wiskSecondaryText)
        }
        .accessibilityHidden(true)
    }

    private var shortcutChip: some View {
        Text(action.shortcutLabel)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.wiskTertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.cardBorder, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color.surfaceElevated)
            .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 6 : 1, y: isHovered ? 2 : 1)
            .overlay {
                if isHovered {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(action.isEmphasized ? Color.accent.opacity(0.06) : Color.primary.opacity(0.04))
                }
            }
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .strokeBorder(
                action.isEmphasized && isHovered ? Color.accent.opacity(0.35) : Color.cardBorder,
                lineWidth: 0.5
            )
    }

    private static let cornerRadius: CGFloat = 10
}

private struct MacEmptyCreateShortcutModifier: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}
