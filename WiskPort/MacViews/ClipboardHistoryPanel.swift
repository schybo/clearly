import AppKit
import SwiftUI

struct ClipboardHistoryPanel: View {
    @Environment(ClipboardHistoryController.self) private var controller
    @FocusState private var searchFocused: Bool
    @AppStorage("wisk.mac.appearance") private var appearanceRawValue = WiskAppearance.light.rawValue

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                TextField("Search clips", text: $controller.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityIdentifier("wisk.mac.clipboard.search")

                if !controller.recordingEnabled {
                    HStack(spacing: Spacing.sm) {
                        Text("Recording is off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Turn On") {
                            controller.recordingEnabled = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("wisk.mac.clipboard.turnOn")
                    }
                }
            }
            .padding(Spacing.md)

            Divider()

            clipList

            Divider()

            footer
        }
        .frame(width: 380, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme((WiskAppearance(rawValue: appearanceRawValue) ?? .light).colorScheme)
        .tint(.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wisk.mac.clipboard.panel")
        .onChange(of: controller.panelPresented) { _, shown in
            guard shown else { return }
            controller.statusMessage = nil
            controller.syncHighlightToSearch()
            searchFocused = true
        }
        .onChange(of: controller.searchQuery) { _, _ in
            controller.syncHighlightToSearch()
        }
        .onChange(of: controller.store.clips.map(\.id)) { _, _ in
            controller.syncHighlightToSearch()
        }
    }

    private var clipList: some View {
        let clips = controller.visibleClips()
        return ScrollViewReader { proxy in
            ScrollView {
                if clips.isEmpty {
                    ContentUnavailableView(
                        controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Clips" : "No Matches",
                        systemImage: "doc.on.clipboard",
                        description: Text(
                            controller.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Copy text and it will show up here."
                                : "Try a different search."
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            if clip.pinned && index == 0 {
                                sectionLabel("Pinned")
                            }
                            if !clip.pinned && (index == 0 || clips[index - 1].pinned) {
                                sectionLabel(clips.contains(where: \.pinned) ? "Recent" : "Clips")
                            }
                            clipRow(clip)
                        }
                    }
                    .padding(.vertical, Spacing.sm)
                }
            }
            .onChange(of: controller.highlightedClipID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(controller.statusMessage ?? controller.pasteHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("wisk.mac.clipboard.status")

            HStack {
                Text("⌃⌥V")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Control Option V")
                Spacer(minLength: 0)
                Button("Quit Wisk") {
                    controller.quit()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityIdentifier("wisk.mac.clipboard.quit")
            }
        }
        .padding(Spacing.md)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.xs)
    }

    private func clipRow(_ clip: ClipboardClip) -> some View {
        let highlighted = clip.id == controller.highlightedClipID
        return HStack(alignment: .center, spacing: Spacing.sm) {
            Button {
                controller.paste(clip)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(previewLine(clip.plainText))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Spacing.xs) {
                        Text(clip.updatedAt, format: .relative(presentation: .named))
                        if let sourceAppName = clip.sourceAppName, !sourceAppName.isEmpty {
                            Text("·")
                            Text(sourceAppName)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(previewLine(clip.plainText))
            .accessibilityIdentifier("wisk.mac.clipboard.row")

            Button {
                controller.togglePinned(clip.id)
            } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(clip.pinned ? AnyShapeStyle(Color.accent) : AnyShapeStyle(.secondary))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(clip.pinned ? "Unpin" : "Pin")
            .accessibilityLabel(clip.pinned ? "Unpin" : "Pin")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(
            highlighted ? Color.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, Spacing.sm)
        .id(clip.id)
        .contextMenu {
            Button(clip.pinned ? "Unpin" : "Pin") {
                controller.togglePinned(clip.id)
            }
            Button("Delete", role: .destructive) {
                controller.store.delete(id: clip.id)
                controller.syncHighlightToSearch()
            }
        }
    }

    private func previewLine(_ text: String) -> String {
        let line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.count > 180 {
            return String(line.prefix(180)) + "…"
        }
        return line
    }
}
