import SwiftUI

#if os(iOS)

enum WiskIOSNotesFilterFollowUp: Equatable {
    case adages
    case emptyPermanently
}

struct WiskIOSNotesTopPlacement<Bar: View>: ViewModifier {
    var bar: Bar

    @State private var columnWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { columnWidth = $0 }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                bar
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xs)
                    .frame(width: columnWidth > 1 ? columnWidth : nil)
            }
    }
}

struct WiskIOSNotesTopBar: View {
    let title: String
    let filterIsActive: Bool
    var showsSidebarToggle: Bool
    @Binding var searchText: String
    let onFilter: () -> Void
    let onToggleSidebar: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chromeNamespace
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var circle: CGFloat = 44
    @State private var isSearching = false

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, showsSidebarToggle ? (circle * 2 + 20) : (circle + 18))
                .frame(maxWidth: .infinity)
                .opacity(isSearching ? 0 : 1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(isSearching)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.12), value: isSearching)

            HStack(spacing: 10) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        if showsSidebarToggle {
                            sidebarToggle
                        }
                        filterButton
                    }
                }
                if isSearching == false {
                    Spacer(minLength: 0)
                }
                GlassEffectContainer(spacing: 0) {
                    searchControl
                }
                .frame(maxWidth: isSearching ? .infinity : circle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: circle)
        .animation(chromeAnimation, value: isSearching)
        .onAppear {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                isSearching = true
                searchFocused = true
            }
        }
        .onChange(of: isSearching) { _, searching in
            if searching {
                Task { @MainActor in
                    searchFocused = true
                }
            } else {
                searchFocused = false
            }
        }
    }

    private var chromeAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.08)
    }

    private var sidebarToggle: some View {
        Button(action: onToggleSidebar) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: circle, height: circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle Sidebar")
    }

    private var filterButton: some View {
        Button(action: onFilter) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filterIsActive ? Color.accent : Color.primary)
                .frame(width: circle, height: circle)
                .overlay(alignment: .topTrailing) {
                    if filterIsActive {
                        Circle()
                            .fill(Color.accent)
                            .frame(width: 8, height: 8)
                            .padding(7)
                    }
                }
                .wiskGlassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("notes-filter", in: chromeNamespace)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter")
        .accessibilityValue(filterIsActive ? "Active" : "")
        .accessibilityIdentifier("wisk.notes.scopeMenu")
    }

    private var searchControl: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            if isSearching {
                TextField("Search notes or tags", text: $searchText)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("wisk.notes.searchField")
                    .transition(.opacity)
                Button(action: collapseSearch) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
                .transition(.opacity)
            }
        }
        .modifier(WiskIOSSearchContentFade(reduceMotion: reduceMotion, isSearching: isSearching))
        .padding(.horizontal, isSearching ? 12 : 0)
        .frame(width: isSearching ? nil : circle, height: circle)
        .frame(maxWidth: isSearching ? .infinity : circle, minHeight: circle)
        .wiskGlassEffect(.regular.interactive(), in: Capsule())
        .glassEffectID("notes-search", in: chromeNamespace)
        .glassEffectTransition(reduceMotion ? .materialize : .matchedGeometry)
        .overlay {
            if isSearching == false {
                Button(action: expandSearch) {
                    Color.clear
                        .frame(width: circle, height: circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
                .accessibilityIdentifier("wisk.notes.searchButton")
            }
        }
    }

    private func expandSearch() {
        isSearching = true
    }

    private func collapseSearch() {
        isSearching = false
        searchText = ""
    }
}

private struct WiskIOSSearchContentFade: ViewModifier {
    var reduceMotion: Bool
    var isSearching: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content.animation(.easeOut(duration: 0.15), value: isSearching)
        } else {
            content
        }
    }
}

struct WiskIOSNotesFilterSheet: View {
    @Binding var scope: WiskNotesScope
    @Binding var sortRawValue: String
    let tags: [String]
    let showsLibrary: Bool
    let emptyableCount: Int
    let onAdages: () -> Void
    let onEmptyPermanently: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if showsLibrary {
                    Section("Library") {
                        scopeButton(.all)
                        scopeButton(.archive)
                        scopeButton(.trash)
                        scopeButton(.untagged)
                    }
                    if tags.isEmpty == false {
                        Section("Tags") {
                            ForEach(tags, id: \.self) { tag in
                                tagButton(tag)
                            }
                        }
                    }
                }
                Section("Sort") {
                    Picker("Sort", selection: $sortRawValue) {
                        ForEach(WiskNoteSortMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("wisk.notes.sortMenu")
                }
                Section {
                    Button(action: onAdages) {
                        Label("Adages", systemImage: "text.quote")
                    }
                    .accessibilityIdentifier("wisk.notes.adagesButton")
                    if emptyableCount > 0 {
                        Button(role: .destructive, action: onEmptyPermanently) {
                            Label("Delete All Permanently", systemImage: "trash")
                        }
                        .accessibilityIdentifier("wisk.notes.deleteAllPermanentlyButton")
                    }
                }
            }
            .navigationTitle(showsLibrary ? "Filter" : "Sort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func scopeButton(_ value: WiskNotesScope) -> some View {
        let selected = scope == value
        return Button {
            scope = value
        } label: {
            HStack {
                Label(value.title, systemImage: value.systemImage)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accent)
                }
            }
        }
        .foregroundStyle(selected ? Color.accent : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("wisk.notes.scope.\(value.id)")
    }

    private func tagButton(_ tag: String) -> some View {
        let selected: Bool = {
            if case .tag(let name) = scope {
                return name == tag
            }
            return false
        }()
        return Button {
            scope = .tag(tag)
        } label: {
            HStack {
                Label(tag, systemImage: "tag")
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accent)
                }
            }
        }
        .foregroundStyle(selected ? Color.accent : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("wisk.notes.scope.tag:\(tag)")
    }
}

struct WiskIOSNotesCreateButtons: View {
    let structuredTemplates: [StructuredNoteTemplate]
    let createNote: () -> Void
    let createStructuredNote: (StructuredNoteTemplate) -> Void
    let createList: () -> Void
    let createTracker: () -> Void

    @ScaledMetric(relativeTo: .body) private var types: CGFloat = 46
    @ScaledMetric(relativeTo: .title3) private var compose: CGFloat = 56

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                typesMenu
                composeButton
            }
        }
    }

    private var typesMenu: some View {
        Menu {
            ForEach(structuredTemplates) { template in
                Button {
                    createStructuredNote(template)
                } label: {
                    Label(template.title, systemImage: template.isUserDefined ? "person.crop.square" : "rectangle.stack.badge.plus")
                }
            }
            Button("New List", systemImage: "checklist", action: createList)
                .accessibilityIdentifier("wisk.notes.newListButton")
            Button("New Tracker", systemImage: "plus.forwardslash.minus", action: createTracker)
                .accessibilityIdentifier("wisk.notes.newTrackerButton")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: types, height: types)
                .wiskGlassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New structured note")
        .accessibilityIdentifier("wisk.notes.newStructuredButton")
    }

    private var composeButton: some View {
        Button(action: createNote) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: compose, height: compose)
                .wiskGlassEffect(.regular.tint(Color.accent).interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New note")
        .accessibilityIdentifier("wisk.notes.newButton")
    }
}

#endif
