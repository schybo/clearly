import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WiskProfileAvatarView: View {
    let photoURL: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.14))

            if let photoURL {
                AsyncImage(url: photoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: size * 0.58, weight: .medium))
            .foregroundStyle(.accent)
    }
}

struct WiskMacSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @Environment(WiskProfileService.self) private var profileService
    @Environment(WiskProEntitlementService.self) private var proEntitlement
    @Environment(WiskFontManager.self) private var fontManager
    @Environment(ClipboardHistoryController.self) private var clipboard
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var activeBuckets: [NoteBucket]

    @AppStorage("wisk.mac.appearance") private var appearanceRawValue = WiskAppearance.light.rawValue
    @AppStorage(WiskBetaFeatures.plaudEnabledKey) private var plaudEnabled = false
    @State private var welcomeNotesMessage: String?
    @AppStorage(WiskEditorDefaults.macFontSizeKey) private var editorFontSize = WiskEditorDefaults.defaultFontSize
    @AppStorage(WiskEditorDefaults.formattingControlsKey) private var formattingControlsEnabled = false
    @AppStorage(WiskEditorDefaults.showMarkdownSyntaxKey) private var showMarkdownSyntax = false

    @State private var bucketNameDraft = ""
    @State private var bucketDescriptionDraft = ""
    @State private var bucketExamplesDraft = ""
    @State private var showingGoogleFonts = false
    @State private var confirmingClipboardClear = false
    @State private var clipboardAccessibilityTrusted = false

    private var appearanceBinding: Binding<WiskAppearance> {
        Binding(
            get: { WiskAppearance(rawValue: appearanceRawValue) ?? .light },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    private var selectedBuiltInFont: WiskEditorFontFamily? {
        fontManager.selection.source == .builtIn ? fontManager.selection.builtInFont : nil
    }

    private func selectBuiltInFont(_ family: WiskEditorFontFamily) {
        fontManager.selectBuiltIn(family)
        Task {
            await profileService.syncGoogleFontSelection(nil)
        }
    }

    var body: some View {
        TabView {
            accountTab
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }

            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            editorTab
                .tabItem {
                    Label("Editor", systemImage: "textformat")
                }

            clipboardTab
                .tabItem {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                }

            bucketsTab
                .tabItem {
                    Label("Buckets", systemImage: "square.stack.3d.up")
                }

            routingTab
                .tabItem {
                    Label("Routing", systemImage: "arrowshape.turn.up.right")
                }
        }
        .frame(width: 560, height: 620)
        .task {
            profileService.startObserving()
        }
    }

    private var accountTab: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    WiskProfileAvatarView(photoURL: profileService.photoURL, size: 72)
                        .accessibilityLabel("Profile photo")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(authService.displayName)
                            .font(.title3.weight(.semibold))
                        Text(authService.accountSubtitle)
                            .foregroundStyle(.secondary)

                        if profileService.isUploading {
                            ProgressView("Updating photo...")
                                .controlSize(.small)
                        } else if let message = profileService.lastErrorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                HStack {
                    Button("Choose Image...") {
                        chooseAvatar()
                    }
                    .accessibilityIdentifier("wisk.mac.settings.chooseAvatarButton")

                    Button("Remove Photo") {
                        Task {
                            await profileService.removeAvatar()
                        }
                    }
                    .disabled(profileService.photoURL == nil || profileService.isUploading)
                    .accessibilityIdentifier("wisk.mac.settings.removeAvatarButton")
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    try? authService.signOut()
                    profileService.stopObserving()
                }
                .accessibilityIdentifier("wisk.mac.settings.signOutButton")
            }

            Section("Welcome Notes") {
                Text("New accounts start with short helper notes. Restore any you deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore welcome notes") {
                    let restored = WiskHelperNoteSeedService.restoreMissingHelpers(
                        context: modelContext,
                        syncService: syncService,
                        uid: authService.firebaseUID
                    )
                    welcomeNotesMessage = restored > 0
                        ? "Restored \(restored) welcome note\(restored == 1 ? "" : "s")."
                        : "Welcome notes are already in your library."
                }
                .accessibilityIdentifier("wisk.mac.settings.restoreWelcomeNotesButton")
                if let welcomeNotesMessage {
                    Text(welcomeNotesMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if DEBUG
            Section {
                Toggle("Unlock Wisk Pro", isOn: Bindable(proEntitlement).debugForceProAccess)
                    .accessibilityIdentifier("wisk.mac.settings.debugUnlockPro")
                Toggle("Plaud import (beta)", isOn: $plaudEnabled)
                    .accessibilityIdentifier("wisk.mac.settings.betaPlaudToggle")
                LabeledContent("AI API", value: WiskAPIConfiguration.resolvedBaseURL().absoluteString)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wisk.mac.settings.debugAIAPI")
            } header: {
                Text("Developer")
            } footer: {
                Text("Unlock Pro bypasses StoreKit in Debug. Plaud is an internal beta and stays hidden unless enabled here. AI parse defaults to hosted wisk-api; override with WISK_API_BASE_URL.")
            }
            #endif

            Section {
                Link(destination: URL(string: "https://clarved.com/apps")!) {
                    Label("More Clarved Apps", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("settings_clarved_apps_link")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.account")
    }

    private var appearanceTab: some View {
        Form {
            Section {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(WiskAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("wisk.mac.settings.appearancePicker")
            } footer: {
                Text("System follows your Mac's current appearance.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.appearance")
    }

    private var editorTab: some View {
        Form {
            Section {
                ForEach(WiskEditorFontFamily.allCases) { family in
                    WiskBuiltInFontChoiceRow(
                        family: family,
                        isSelected: selectedBuiltInFont == family,
                        accessibilityIdentifier: "wisk.mac.settings.editorFontPicker.\(family.rawValue)",
                        onSelect: { selectBuiltInFont(family) }
                    )
                }

                Stepper(value: $editorFontSize, in: 11...30, step: 1) {
                    Text("Font Size: \(Int(editorFontSize))")
                }
                .accessibilityIdentifier("wisk.mac.settings.editorFontSizeStepper")

                Text(WiskBuiltInFontChooser.sample)
                    .font(fontManager.resolvedFont(size: editorFontSize))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Toggle("Show Markdown formatting menu", isOn: $formattingControlsEnabled)
                    .accessibilityIdentifier("wisk.mac.settings.formattingControlsToggle")

                Toggle("Show Markdown characters", isOn: $showMarkdownSyntax)
                    .accessibilityIdentifier("wisk.mac.settings.showMarkdownSyntaxToggle")
            } footer: {
                Text("The rich editor is the only general-note editor. Turn this on to see heading markers, list prefixes, and other Markdown syntax in place.")
            }
            .accessibilityIdentifier("wisk.mac.settings.editorFontPicker")

            Section {
                LabeledContent("Current Font") {
                    Text(fontManager.selection.title)
                }

                if let message = fontManager.statusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Import Font...") {
                        chooseEditorFont()
                    }
                    .disabled(fontManager.isWorking)
                    .accessibilityIdentifier("wisk.mac.settings.importFontButton")

                    Button("Browse Google Fonts...") {
                        showingGoogleFonts = true
                    }
                    .disabled(fontManager.isWorking)
                    .accessibilityIdentifier("wisk.mac.settings.googleFontsButton")

                    Button("Remove Custom Font") {
                        fontManager.removeCustomFontSelection()
                        Task {
                            await profileService.syncGoogleFontSelection(nil)
                        }
                    }
                    .disabled(fontManager.selection.source == .builtIn || fontManager.isWorking)
                }

                if fontManager.isWorking {
                    ProgressView("Updating font...")
                        .controlSize(.small)
                }
            } header: {
                Text("Custom Fonts")
            } footer: {
                Text("Imported font files stay on this Mac. Google Fonts sync by family and variant so your other devices can redownload them.")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.editor")
        .sheet(isPresented: $showingGoogleFonts) {
            WiskGoogleFontPickerView { font in
                Task {
                    await fontManager.installGoogleFont(font)
                    await profileService.syncGoogleFontSelection(fontManager.selection)
                }
            }
            .frame(width: 440, height: 520)
        }
    }

    private var clipboardTab: some View {
        Form {
            Section {
                if clipboard.store.clips.isEmpty {
                    Text("Copy text while Wisk is open and it will show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(clipboard.store.clips) { clip in
                                clipboardHistoryRow(clip)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }

                if let statusMessage = clipboard.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Open Menu Bar Clipboard") {
                    clipboard.showPanel()
                }
                .accessibilityIdentifier("wisk.mac.settings.clipboardShow")
            } header: {
                Text("History")
            } footer: {
                Text("This is the same list as the Clips item in the menu bar. You can also open it with ⌃⌥V.")
            }

            Section {
                Toggle("Remember copies", isOn: Bindable(clipboard).recordingEnabled)
                    .accessibilityIdentifier("wisk.mac.settings.clipboardRecording")

                Stepper(
                    value: Bindable(clipboard).historyLimit,
                    in: ClipboardHistoryPreferences.minimumHistoryLimit...ClipboardHistoryPreferences.maximumHistoryLimit
                ) {
                    Text("Remember \(clipboard.historyLimit) clips")
                }
                .accessibilityIdentifier("wisk.mac.settings.clipboardLimit")

            } footer: {
                Text("Wisk remembers text you copy while it is open. Clips stay on this Mac and are not synced.")
            }

            Section {
                Toggle("Paste as plain text", isOn: Bindable(clipboard).pasteAsPlainText)
                    .accessibilityIdentifier("wisk.mac.settings.clipboardPlainText")

                Toggle("Paste into the front app", isOn: Bindable(clipboard).directPaste)
                    .accessibilityIdentifier("wisk.mac.settings.clipboardDirectPaste")

                LabeledContent("Accessibility") {
                    Text(clipboardAccessibilityTrusted ? "Allowed" : "Not allowed")
                        .foregroundStyle(.secondary)
                }

                if clipboard.directPaste && !clipboardAccessibilityTrusted {
                    Button("Allow Accessibility…") {
                        ClipboardAccessibility.prompt()
                    }
                }
            } footer: {
                Text("Direct paste needs Accessibility permission. Without it, choosing a clip copies it so you can press ⌘V. Open the history with ⌃⌥V.")
            }

            Section {
                LabeledContent("Saved clips", value: "\(clipboard.store.clips.count)")

                Button("Delete All Clips", role: .destructive) {
                    confirmingClipboardClear = true
                }
                .disabled(clipboard.store.clips.isEmpty)
                .accessibilityIdentifier("wisk.mac.settings.clipboardClear")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.clipboard")
        .onAppear {
            clipboardAccessibilityTrusted = ClipboardAccessibility.isTrusted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboardAccessibilityTrusted = ClipboardAccessibility.isTrusted
        }
        .confirmationDialog(
            "Delete all clips?",
            isPresented: $confirmingClipboardClear,
            titleVisibility: .visible
        ) {
            Button("Delete All Clips", role: .destructive) {
                clipboard.store.clear()
            }
        } message: {
            Text("This removes clipboard history from this Mac. Notes are not affected.")
        }
    }

    private func clipboardHistoryRow(_ clip: ClipboardClip) -> some View {
        let preview = clip.plainText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? clip.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = preview.count > 140 ? String(preview.prefix(140)) + "…" : preview

        return HStack(alignment: .center, spacing: 8) {
            Button {
                clipboard.paste(clip)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        if clip.pinned {
                            Image(systemName: "pin.fill")
                        }
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
            .accessibilityIdentifier("wisk.mac.settings.clipboard.row")

            Button {
                clipboard.togglePinned(clip.id)
            } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(clip.pinned ? "Unpin" : "Pin")

            Button(role: .destructive) {
                clipboard.store.delete(id: clip.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    private var routingTab: some View {
        Form {
            NoteRouteSettingsForm()
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.routing")
    }

    private var bucketsTab: some View {
        Form {
            Section("Active Buckets") {
                if activeBuckets.isEmpty {
                    Text("No active buckets yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeBuckets) { bucket in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(bucket.name.trimmedNonEmpty ?? "Untitled bucket")
                                        .font(.headline)
                                    if bucket.isDefault {
                                        Text("Default")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                if let description = bucket.descriptionText.trimmedNonEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !bucket.examples.isEmpty {
                                    Text("Examples: \(bucket.examples.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            if !bucket.isDefault {
                                Button("Archive") {
                                    archive(bucket)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Add Bucket") {
                TextField("Name", text: $bucketNameDraft)
                TextField("Description", text: $bucketDescriptionDraft, axis: .vertical)
                    .lineLimit(2...4)
                TextField("Examples, comma separated", text: $bucketExamplesDraft)

                Button("Add Bucket") {
                    addBucket()
                }
                .disabled(bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("wisk.mac.settings.addBucketButton")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("wisk.mac.settings.buckets")
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await profileService.uploadAvatar(from: url)
        }
    }

    private func chooseEditorFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WiskFontImportTypes.allowed
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await fontManager.importLocalFont(from: url)
            await profileService.syncGoogleFontSelection(nil)
        }
    }

    private func addBucket() {
        let name = bucketNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let examples = bucketExamplesDraft
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let bucket = NoteBucket(
            name: name,
            descriptionText: bucketDescriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            examples: examples,
            sortOrder: (activeBuckets.map(\.sortOrder).max() ?? -1) + 1,
            isDefault: false
        )
        modelContext.insert(bucket)
        try? modelContext.save()

        bucketNameDraft = ""
        bucketDescriptionDraft = ""
        bucketExamplesDraft = ""

        Task {
            await syncService.syncNow(context: modelContext)
        }
    }

    private func archive(_ bucket: NoteBucket) {
        bucket.archivedAt = Date()
        bucket.updatedAt = Date()
        try? modelContext.save()

        Task {
            await syncService.syncNow(context: modelContext)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
