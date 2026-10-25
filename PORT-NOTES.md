# PORT-NOTES — Clearly → Wisk sandbox port findings

Consolidated from parallel read-only exploration agents (2026 session), re-verified
against the tree at fork `schybo/clearly` @ `e79f602` ("[mac] feat: add Rich Text
export (#412)"), upstream `Shpigford/clearly`.
Checkout: `~/clarved/clearly` — independent of the Wisk repo; Wisk stays untouched
until the decision gate.

> v2 note: an earlier draft of this file described files that do not exist
> (`SourceListView`, `MarkdownToolbar`, `WindowSplitView`, `EditorRootView`,
> `DocumentBrowserView`, `OpenGraphFetcher`, `SettingsModel`). Every claim below is
> re-verified with file:line citations against the current tree.

---

## TL;DR for the port

1. **The composer engine is two classes with a tiny contract** —
   `MarkdownSyntaxHighlighter` (regex-driven, 100% attribute-only) plus an optional
   Mac gutter/indent layer. No cmark, no DocumentGroup coupling inside the engine.
   Already proven to run outside DocumentGroup by the scratchpad windows.
2. **TextKit 1 everywhere, deliberately.** The engine requires a live `NSTextStorage`
   + `NSLayoutManager`; attribute edits are dead on TextKit 2's
   `NSTextContentStorage`. This is the repo's #1 documented invariant
   (`CLAUDE.md:93`). Wisk's current editor is TextKit 2 — the sandbox is a full
   pivot, not a retrofit.
3. **QuickType-safe by construction:** zero programmatic content edits per
   keystroke. The visible string only ever changes from the user or IME. Three
   guards (marked-text gate, `pendingBindingUpdates`, re-entrancy flag) are
   load-bearing — port them together with the engine.
4. **Clearly has no note list, no tags, no buckets, no cross-document search.** The
   system Files/NSDocument browser is the "list". WiskNext's primary navigation UI
   is greenfield; what ports is the per-document experience.
5. **Rebranding is mechanical but wide** — bundle ids (`com.sabotage.*`),
   Shpigford's signing team, Sparkle, plists, icons, scripts. No deep coupling
   between app shell and engine.

---

## 1. Project structure & build

### Layout

| Path | Role |
|---|---|
| `Clearly/` | macOS app source (editor hosts, windows, commands, scratchpads) |
| `Clearly/iOS/` | iOS app source (editor, preview, find overlay, outline sheet, extensions) |
| `Shared/` | Cross-platform web resources only — **no Swift code** |
| `Packages/ClearlyCore/` | The shared engine package (SPM local package, 34 source files) |
| `ClearlyQuickLook/` | macOS Quick Look app extension |
| `scripts/` | release.sh, release-appstore.sh, submit-appstore.sh, release-ios.sh, verify-entitlements.sh |
| `website/` | Marketing site + Sparkle appcast (clearly.md) — decoupled from the app |
| `project.yml` | XcodeGen manifest (Wisk uses the same generator — familiar) |

### Targets (project.yml)

| Target | Platform | Type | Bundle ID (release) |
|---|---|---|---|
| `Clearly` | macOS 15+ | app | `com.sabotage.clearly` |
| `Clearly-iOS` | iOS 17+, family 1,2 | app | `com.sabotage.clearly` (shared w/ Mac for Universal Purchase) |
| `ClearlyQuickLook` | macOS | app extension | `com.sabotage.clearly.quicklook` |
| `ClearlyPreview-iOS` | iOS | app extension | `com.sabotage.clearly.preview` |
| `ClearlyThumbnail-iOS` | iOS | app extension | `com.sabotage.clearly.thumbnail` |

- Every Debug config overrides to a `.dev` bundle id and `"Clearly Dev"` product name.
- `DEVELOPMENT_TEAM: W33JZPPPFN` (upstream's team) on all five targets — override or
  build with `CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""`.
- Mac and iOS version **independently** (Mac 3.3.0, iOS app 2.1.0, iOS extensions 2.0.0).
- External deps: `cmark-gfm` (preview only — single import site
  `MarkdownRenderer.swift:2`), `Sparkle` (Mac, `#if canImport(Sparkle)` guarded),
  `KeyboardShortcuts` (Mac, scratchpad hotkey only).
- ClearlyCore links into all targets **except** `ClearlyThumbnail-iOS`.
- **No Xcode test targets exist.** The only automated suite is the SPM package's
  `ClearlyCoreTests` (`swift test --package-path Packages/ClearlyCore`).

### ClearlyCore contents (all of it)

- `Platform/Platform.swift` — AppKit/UIKit typealiases; the package's only platform
  divergence point.
- `Rendering/` — `MarkdownSyntaxHighlighter.swift` (keystroke-time regex
  highlighter), `MarkdownRenderer.swift` (cmark → HTML + post-processing),
  `PreviewCSS.swift` (token palettes), `Theme.swift`, `PreviewUserScripts.swift`,
  `MermaidSupport`/`MermaidLightboxSupport`/`SyntaxHighlightSupport`/`TableSupport`/
  `WikilinkSupport`/`FrontmatterSupport`/`EmojiShortcodes`/`ATXHeadingPrefix`,
  `LocalImageSupport.swift` (relative image paths + custom `clearly-file`
  WKWebView scheme).
- `State/` — `OpenDocument`, `FindState`, `ReplaceEngine`, `TextMatcher`,
  `OutlineState`, `PositionSync` (editor↔preview scroll anchoring),
  `JumpToLineState`, `StatusBarState`, `FoldStateStore`, `NavigationGuard`,
  `ExternalFileWatcher` + `WatchExternalChangesModifier`.
- `Editor/` — `ImagePasteService.swift` (pasted/dropped images → sibling
  `<slug>-<N>.<ext>` files + markdown ref), `ImageDownloader.swift`.
- `Diagnostics/` — `DiagnosticLog` (os.Logger subsystem hardcoded
  `com.sabotage.clearly`), `BugReportURL` (hardcoded `Shpigford/clearly`),
  `MemoryUsage`.
- `Stats/MarkdownStats.swift`, `Limits.swift` (50 MB open cap, 20 MB image, 5 M-char
  highlight bail).

### Entry points

- **Mac:** `@main ClearlyApp` at `Clearly/ClearlyApp.swift:433` —
  `DocumentGroup(newDocument: MarkdownDocument()) { ContentView }` + `Settings`
  scene + `MenuBarExtra("Scratchpads")`. `ClearlyAppDelegate` (`:13-430`) is ~400
  lines of menubar-only activation / 'odoc' Apple-event interception.
- **iOS:** `@main ClearlyApp_iOS` at `Clearly/iOS/ClearlyApp_iOS.swift:4` — an
  8-line `DocumentGroup` body whose detail is `DocumentDetailBody`. The system
  Files browser is the entry UI.
- **Shared surface is tiny:** the only app-level file in both targets is
  `Clearly/MarkdownDocument.swift` (29-line `FileDocument` wrapping
  `text: String`, UTType `net.daringfireball.markdown`). Everything else shared
  lives in ClearlyCore.

### Build commands (this machine)

```bash
cd ~/clarved/clearly
xcodegen generate   # .xcodeproj is gitignored; re-run after project.yml/source changes

# Mac
xcodebuild -project Clearly.xcodeproj -scheme Clearly -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" build

# iOS simulator
xcodebuild -project Clearly.xcodeproj -scheme Clearly-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" build

# ClearlyCore unit suite
swift test --package-path Packages/ClearlyCore
```

Baseline status: all three commands green at `e79f602` on this machine
(2026-10-25; Mac needs xcodegen ≥ 2.46 — 2.45.2 mis-outputs `type: folder`
resource paths as repo-root-relative).

### Rebrand checklist (Clearly → sandbox app, working name WiskNext)

1. `project.yml`: `name:`, `bundleIdPrefix: com.sabotage`, 11 explicit
   `PRODUCT_BUNDLE_IDENTIFIER`s, `PRODUCT_NAME`s, `DEVELOPMENT_TEAM`.
2. Debug-variant names ("Clearly Dev") + per-extension bundle-id suffixes.
3. Hand-maintained plists (`GENERATE_INFOPLIST_FILE: NO`): `Clearly/Info.plist`,
   `Clearly/iOS/Info-iOS.plist`, extension plists — display names, `LSHandlerRank:
   Owner`, exported UTI claims (`net.daringfireball.markdown` etc.).
4. Icons: `Clearly/AppIcon.icon` (Icon Composer) + Mac menubar imageset.
5. Sparkle: feed URL + `SUPublicEDKey` in Info.plist, `#if canImport(Sparkle)`
   sites in `ClearlyApp.swift`/`SettingsView.swift` — **drop entirely** for the sandbox.
6. Hardcoded identity strings: Logger subsystem + queue labels
   (`DiagnosticLog.swift:5,21`, `FoldStateStore.swift:46`), bug-report repo
   (`BugReportURL.swift:15`), Help/Settings links to clearly.md/Shpigford
   (`ClearlyApp.swift:524,537`, `SettingsView.swift:188-190`), demo.md links.
7. The `clearly-file` WKWebView scheme (`LocalImageSupport.swift:6`) — a string
   constant, safe to rename.
8. Scripts carry the brand (release/DMG/appcast) — irrelevant pre-gate.
9. Keep `upstream` remote (Shpigford/clearly) for future pulls; origin is the fork.
10. Load-bearing rebrand invariants: the LaunchServices/QuickLook claims and the
    per-target resource duplication (shared web assets must be re-declared in every
    target's resources).

---

## 2. Text composer / input pipeline  ⭐ the crown jewel

**Engine file:** `Packages/ClearlyCore/Sources/ClearlyCore/Rendering/MarkdownSyntaxHighlighter.swift`
(757 lines), shared verbatim by both platforms via
`PlatformTextStorage`/`PlatformFont` typealiases (`Platform/Platform.swift`).

**Model:** pure regex enumeration over the live string — ~24 precompiled
`NSRegularExpression`s with paired `HighlightStyle`s: frontmatter, fenced code,
`$$` math, headings, emphasis, strikethrough, inline code, images/links,
blockquotes, list markers, tasks, HR, `==highlight==`, footnotes, table rows,
setext headings, HTML tags. No parse tree, no cmark in the editor path (cmark-gfm
is preview-only). Consequence: editor styling and cmark preview can disagree on
edge cases — accepted trade.

**Highlight application is 100% attribute-only.** Every entry point wraps work in
`beginEditing()`/`endEditing()` and calls only `addAttribute(s)`/`removeAttribute`
on existing ranges. No `replaceCharacters`, no wipe-and-rewrite, no invisible
markers. `**` stays visibly in the string, styled in a marker color.

**Range strategy: paragraph-scoped incremental with full-reparse fallbacks.**
- `highlightAll(_:caller:)` (`:163-407`): base attributes full-range, all patterns
  full-range, collecting *protected ranges* (code/math/frontmatter) that suppress
  inner styling.
- `highlightAround(_:editedRange:replacementLength:caller:)` (`:448-729`): expand
  post-edit range to paragraph via `paragraphRange(for:)`, reset + re-run patterns
  only there. >5 M-char paragraphs bail out (`Limits.swift:8`).
- Edits touching a block delimiter (```` ``` ````, `$$`, `---`) set
  `needsFullHighlight` → host schedules a **deferred 0.3 s full re-highlight**
  while the paragraph still paints immediately.
- Optimizations that matter on large docs: skip font reset when the paragraph is
  already default-font ("avoids glyph regeneration, which is the main
  per-keystroke cost", `:507-524`); protected ranges shifted by edit delta instead
  of rebuilt (`:528-551`).

### Keystroke lifecycle (the contract to port)

```
key event
→ shouldChangeTextIn(...)  — NEVER vetoes; records lastEditedRange + replacementLength
→ AppKit/UIKit mutates NSTextStorage   (the ONLY content edit; OS handles undo coalescing/IME)
→ textDidChange / textViewDidChange:
     guard !re-entrancy flag
     pendingBindingUpdates = 1          (blocks SwiftUI binding feedback loop)
     save scroll origin
     highlightAround(storage, editedRange, len)   — attribute-only
     deferred highlightAll if needsFullHighlight
     restore scroll origin
     setNeedsDisplay(visibleRect)       — attribute edits don't dirty the view
     write binding back async, reset pendingBindingUpdates next runloop
```

Platform hosts:
- Mac: `EditorView.swift` Coordinator (`:382+`), text view `ClearlyTextView.swift:47`
  inside a hand-built TextKit 1 stack (`MarkdownHeadingLayout.swift:206-215`).
- iOS: `EditorView_iOS.swift:411-477` + `ClearlyUITextView.swift:8`, which forces
  TextKit 1 by constructing its own `NSTextStorage → NSLayoutManager →
  NSTextContainer` and calling `super.init(frame:textContainer:)` (`:13-24`).
- Mac scratchpads: `ScratchpadEditorView.swift:20` — proves the engine runs outside
  DocumentGroup.

### Why QuickType/autocorrect survive (the fix for Wisk's original bug)

1. **Zero app-driven content edits per keystroke.** The input manager's model
   (marked ranges, undo, autocorrect candidates, selectedRange) is never
   invalidated. Autocorrect *replacements* arrive as normal user edits through
   `shouldChangeTextIn` and highlight correctly.
2. **IME guards:** `markedTextRange == nil` gate before any content write
   (`EditorView_iOS.swift:44-52`), `hasMarkedText()` gate (`EditorView.swift:345`),
   stale-range validation with safe fallback to `highlightAll`
   (`MarkdownSyntaxHighlighter.swift:453-464`).
3. **SwiftUI round-trip suppression:** `pendingBindingUpdates` counter so
   `updateNSView`/`updateUIView` never overwrite the text view mid-composition
   (`EditorView_iOS.swift:47,472-477`; `EditorView.swift:344-352`).
4. **Where harmony couldn't be guaranteed, they disabled the rewriter:** iOS sets
   `autocorrectionType/smartQuotesType/smartDashesType/smartInsertDeleteType = .no`
   (`ClearlyUITextView.swift:33-37`); Mac disables quote/dash/text replacement
   (`EditorView.swift:71-91`). Spell check (overlay, non-rewriting) stays on.

### Undo, cursor, scroll

- Mac: **dedicated `UndoManager` per text view** (`EditorView.swift:395-406`) —
  DocumentGroup registers an undo per binding write which breaks NSTextView
  coalescing when shared (#390).
- iOS: native UITextView undo; find/replace has its own grouped undo
  (`EditorView_iOS.swift:330-361`).
- Selection is never restored during typing — attribute edits can't move it.
  Content paths (external load, paste) clamp/restore explicitly.
- Scroll preserved around re-highlights (`EditorView.swift:635-666`);
  `scrollViewDidScroll` suppressed during highlighting (`:716-742`); repaint via
  visible-rect invalidation (`:751-755`).
- Document open: set text → `highlightAll`, delegate attached *after*
  (`EditorView.swift:115-123`); 50 MB open cap (`Limits.swift`).

### Engine ↔ host contract (what a host app must supply)

1. A real TextKit 1 `NSTextStorage`.
2. Edited range + replacement length captured from `shouldChangeTextIn` before the
   edit lands.
3. A post-edit delegate callback to trigger `highlightAround`.
4. A re-entrancy suppression flag for programmatic writes.

That's it — no cmark, no model objects, no document reference. `Theme` + `Limits`
are its only ClearlyCore dependencies.

### Transplant risks for Wisk

- **Attribute namespace collision:** the highlighter *resets*
  `.font/.foregroundColor/.paragraphStyle/.backgroundColor/.strikethroughStyle`
  per paragraph (`:507-524`). Wisk attachment placeholders living on those keys
  would be stripped per keystroke → move Wisk attachment styling to custom
  `NSAttributedString.Key`s and add attachment ranges to the protected-ranges
  mechanism (`isInsideProtectedRange`, `:733`).
- **TextKit 2 incompatibility** — Wisk's editor is TextKit 2; the sandbox is a
  deliberate pivot to TextKit 1.
- **IME/SwiftUI guards are load-bearing** — each was added after a real bug; port
  together or reproduce those bugs.
- **Regex semantics** — editor vs preview can disagree on nested emphasis edges.
- **iOS smart features default off** — Wisk may want autocorrect ON; Clearly's
  evidence says replacement-style edits flow fine through the pipeline, so this is
  a choice, not a constraint.

---

## 3. UI layer

### macOS

- **Window root:** `Clearly/ContentView.swift:8` — vertical `VStack`: `FindBarView`
  (`:57-58`) → `JumpToLineBar` (`:61-62`) → `HStack { mainPane; OutlineView(240pt) }`
  (`:104-107`) → hover-revealed `BottomToolbar` pill overlay (`:81-102`).
- **Editor/preview ZStack:** `mainPane` (`:170-196`) keeps `EditorView` and
  `PreviewView` **both always mounted**, toggled by `.opacity` + `.allowsHitTesting`
  on `viewMode` — mode switch is instant, no re-mount. Blank docs never open in
  preview (`:32-39`).
- **There is no sidebar / note list.** The only side panel is the heading outline —
  `OutlineView` (`Clearly/OutlineView.swift:4-57`) driven by `OutlineState`. The
  "note list" is the system's (NSDocumentController recents / file picker).
- **Formatting menu:** the `.textFormatting` menu is fully replaced — ⌘B, ⌘I,
  ⇧⌘X, ⇧⌘H, ⌘K, ⇧⌘T, lists, quote, HR, table, code, math, page break
  (`ClearlyApp.swift:488-521`), dispatched via `performFormattingCommand` →
  `NSApp.sendAction` to the focused `ClearlyTextView` (`:798-801`).
- **`ClearlyTextView`** (`Clearly/ClearlyTextView.swift:47`): 2 pt custom caret
  (`:52-70`), paste/drop routing (URL-on-selection → markdown link; image file/URL
  → sibling PNG via `ImagePasteService`; download placeholder flow, `:125-260`),
  ⌘F interception (`:270-283`), all `@objc` format selectors (`:285-440`),
  right-click "Text Format" submenu (`:442-505`).
- **BottomToolbar** (`Clearly/BottomToolbar.swift:9`): floating glass pill —
  Edit/Preview `ModePill`, live word/char count, Copy menu (Markdown/HTML/Rich
  Text/Plain/Path/Name), outline toggle; `BottomHoverTracker` NSView with
  nil `hitTest` (`:251-289`).
- **Find/replace:** `FindBarView` (`Clearly/FindBarView.swift:4`) + `JumpToLineBar`;
  Mac find paints layout-manager *temporary* attributes (`EditorView.swift:833-858`).
- **Settings:** `Clearly/SettingsView.swift:9` — General/Scratchpads/About tabs;
  appearance, launch behavior, default view mode, font-size 12–24, preview font
  (SF/New York/SF Mono), content width, hide-frontmatter, menubar-only toggle,
  launch-at-login, scratchpad hotkey recorder.
- **Scratchpads:** `MenuBarExtra` → `ScratchpadMenuBar`/`ScratchpadManager`
  (custom `NSPanel`) → `ScratchpadEditorView` reusing the same engine. File-backed
  store with debounced writes (`ScratchpadStore.swift:29`). A parallel mini-app
  (~1,200 lines) — candidate to cut for WiskNext.
- **`ClearlyAppDelegate`** (`ClearlyApp.swift:13-430`): menubar-only activation
  policy, 'odoc' multi-open → window tabs, launch behavior, quit-deferral hacks —
  all specific to "an editor that lives in the menu bar"; not needed by WiskNext.

### iOS

- **Entry:** `Clearly/iOS/ClearlyApp_iOS.swift:4-11` — bare `DocumentGroup`;
  no custom browser, no settings scene.
- **Root:** `Clearly/iOS/DocumentDetailBody.swift:7` — `FindOverlay_iOS` slides in
  above content (`:19-23`); same both-panes-mounted ZStack (`:74-97`); toolbar
  `.topBarTrailing`: Edit↔Preview eye/pencil, Find (⌘F), Outline → sheet
  (`OutlineSheet_iOS`, `:68-70`).
- **No keyboard accessory at all** — zero `inputAccessoryView`/`inputView` hits;
  no formatting bar exists on iOS. Editing affordances: nav-bar buttons, find
  overlay, paste/drop image handling.
- **`ClearlyUITextView`** (`Clearly/iOS/ClearlyUITextView.swift:8`): TextKit 1
  forced (`:13-24`), smart-input family off (`:33-37`),
  `keyboardDismissMode = .interactive` (`:38`), paste override with async image
  download + `replacePlaceholder` (`:61-168`).

### Preview pipeline (WKWebView + cmark-gfm)

- `MarkdownRenderer.renderHTML` (`ClearlyCore/Rendering/MarkdownRenderer.swift:12-66`):
  frontmatter extraction, math/wikilink protection, then
  `cmark_gfm_markdown_to_html` (`CMARK_OPT_UNSAFE | FOOTNOTES | STRIKETHROUGH_…
  | SOURCEPOS | TABLE_PREFER_STYLE_ATTRIBUTES`), then post-processing: KaTeX math,
  wikilinks, `==mark==`, sup/sub, emoji, `[!TYPE]` callouts, `[TOC]` nav, table
  captions, code-filename headers, `data-sourcepos` re-offset.
- **Mac host:** `PreviewView.swift` builds the full HTML (`loadHTML`, `:173-355`)
  with `PreviewCSS.css` tokens + KaTeX/mermaid/highlight.js guarded on content;
  local images via the custom `clearly-file` scheme handler (`:81`).
- **iOS host:** `PreviewView_iOS.swift:5` — same pipeline, smaller script set.
- **The same stack is reused by:** `ClearlyQuickLook/PreviewProvider.swift:14-47`,
  `Clearly/iOS/PreviewExtension/PreviewViewController.swift:24-45`,
  `PDFExporter.swift:78`, `CopyActions.swift:39-63`.
- **State exchange:** `ScrollBridge`/`SelectionBridge` keyed by `positionSyncID`
  (`PositionSync.swift:17-43`); shared `FindState` closures; outline jump via
  `data-sourcepos` + flash mark; DOM→native `taskToggle`/`linkClicked` messages.
- **Known drift:** Mac and iOS `loadHTML` inline JS blocks have diverged (Mac has
  scroll sync, selection capture, find marks, footnote popovers; iOS a subset).
  During the port, consolidate into `PreviewUserScripts` rather than porting two
  copies.

### Themes & typography

- Single source: `Theme` enum (`ClearlyCore/Rendering/Theme.swift:3`) — editor font
  (monospaced system, 12 Mac / 17 iOS defaults), `Theme.Typography`,
  `Theme.Spacing`, `Theme.Motion` tokens; ~22 dynamic colors from ClearlyCore's
  `Colors.xcassets` (`Theme.swift:43-66`).
- Preview palettes are **duplicated hex literals** in `PreviewCSS`
  (`PreviewPalette.light/dark/print`) — CLAUDE.md documents manual sync as a rule.
  A re-skin touches both `Colors.xcassets` and `PreviewPalette`.
- Preview font size = editor size +4 (Mac) / +2 (iOS) — scattered across
  `ContentView.swift:175`, `DocumentDetailBody.swift:88`, `Theme.swift:5-21`;
  centralize on `Theme` while porting.
- Editor re-applies theme + full `highlightAll` on appearance/font change
  (`EditorView.swift:297-323`).

### Keep / replace assessment

- **Keep (clean, self-contained):** ClearlyCore render stack; editor engine trio
  (`MarkdownSyntaxHighlighter` + `EditorView`/`EditorView_iOS` +
  `ClearlyTextView`/`ClearlyUITextView`); find/replace state objects + two thin
  bars; outline; `Theme` tokens; `BottomToolbar`; `SettingsView` patterns.
- **Replace:** `ClearlyApp.swift` + `ClearlyAppDelegate` (menubar machinery),
  `MarkdownDocument` + both `DocumentGroup` scenes, `DocumentWindowSizer`,
  scratchpad suite (cut or port last).
- **Greenfield:** note list / buckets / tags / cross-document search — Clearly
  never had any of it.

---

## 4. Data model & integration surface

### Document model

- `Clearly/MarkdownDocument.swift` — `MarkdownDocument: FileDocument`, UTType
  `net.daringfireball.markdown` (resolved via `UTType(...)` at `:7-8`). Three
  initializers: `init()`, `init(text:)`, `init(configuration:)` (read path).
- **Value semantics, not reference semantics:** DocumentGroup treats the document
  as a value — every edit produces a new `MarkdownDocument` instance through the
  `@Binding`. The editor host writes the full string back per `textDidChange`
  (`commitTextViewContents` → `parent.text`, `EditorView.swift:712-714`). There is
  no long-lived document object with incremental mutations.
- Read/write: `fileWrapper`/`init(fileWrapper:)` round-trips plain UTF-8 markdown.
- No autosave machinery of its own — DocumentGroup + the system schedule it.

### Persistence inventory

- **Settings persist via UserDefaults/AppStorage**: `themePreference`,
  `editorFontSize`, `previewFontFamily`, content width, line numbers, toolbar
  visibility, scratchpad preferences, `DocumentWindowSizer` window frames.
- **No SwiftData/CoreData, no database.** The system Files browser *is* the note
  list. No tags, no folders-of-its-own, no recents of its own (system recents only).
- Scratchpads (Mac menu-bar quick notes) are **file-backed** with debounced writes
  + retention sweeps (`ScratchpadStore.swift:29`) — a separate mini store, not part
  of the document model.
- Per-document editor state (code-fold state) is keyed by **file URL**
  (`FoldStateStore`).

### Attachments story

- Images are referenced by markdown syntax `![alt](path)`;
  `ClearlyCore/Editor/ImagePasteService.swift` writes pasted/dropped images as
  sibling `<slug>-<N>.<ext>` files **next to the `.md`** and inserts the reference
  (Mac paste routing `ClearlyTextView.swift:125-260`; iOS
  `ClearlyUITextView.swift:61-168`; remote URLs via `ImageDownloader` with a
  `![](downloading…)<!--clearly-paste:token-->` placeholder + `replacePlaceholder`).
- `ClearlyCore/Rendering/LocalImageSupport.swift` resolves relative paths for
  preview and registers the `clearly-file` WKWebView URL scheme.
- No embedded binary resources, no asset management, no attachment attribution.

### Search

- In-document only: `FindState`/`TextMatcher`/`ReplaceEngine` (ClearlyCore).
  **No cross-document search exists.**

### Networking

- Only `ImageDownloader` (pasted remote images). No sync, no accounts, no API
  client, no analytics.

### Integration seams for Wisk systems

| Wisk system | Attachment point | Replace vs add |
|---|---|---|
| SwiftData models | `MarkdownDocument.swift` + all `DocumentGroup` wiring in `ClearlyApp.swift` / `ClearlyApp_iOS.swift` | **Replace** — the editor host only needs a text string + binding; it never touches the file URL |
| Firestore sync | the per-keystroke binding write (`commitTextViewContents` / `parent.text =`) | **Add** — enqueue to `SyncMutationWriter` at the same cadence Wisk's autosave uses (never `syncNow` from the typing path) |
| Attachments | `ImagePasteService` + `LocalImageSupport` + both paste overrides | **Replace** — route to Wisk's attachment pipeline; move attachment styling to custom `NSAttributedString.Key`s; register attachment ranges as protected ranges in the highlighter |
| Buckets/tags/search | (no counterpart — greenfield UI) | **Add** — Wisk list UI + `Models/NoteSearchEngine.swift`; Clearly has nothing to build on |
| AI parse client | none exists | **Add** — simple HTTP surface; Wisk's `Wisk/api` `parse-note` client ports directly |

### Highest-risk coupling found

1. **Document identity is the string itself.** Wisk's sync/snapshot model keys off
   a stable note identity; Clearly's value-semantics document has none — the
   sandbox must introduce Wisk's `Note` identity as the source of truth and treat
   the editor as a transient view of `note.body`.
2. **The file URL is the only key** Clearly's per-document state uses (fold state,
   scratchpads) — swap to Wisk's note ID everywhere.
3. DocumentGroup cannot remain the container for SwiftData+Firestore — the scene
   wiring in `ClearlyApp.swift`/`ClearlyApp_iOS.swift` is a rewrite, while
   `EditorView`/`EditorView_iOS` hosts survive intact.

---

## 5. What this means for WiskNext (synthesis)

**Keep wholesale:** composer engine + host pattern (§2), preview stack (§3), find/
outline/theme, `BottomToolbar`, the Mac window chrome *minus* the menubar delegate.

**Replace first:** data layer — DocumentGroup/.md → Wisk's SwiftData models +
Firestore sync. The sandbox editor must learn to render from a SwiftData-backed
string instead of a file URL (engine contract §2 confirms it needs no file URL —
only an `NSTextStorage`).

**Adapt:** image paste (route `ImagePasteService`'s sibling-PNG flow to Wisk's
attachment pipeline + custom attribute keys + protected ranges), note
list/organization UI (greenfield — Wisk buckets/tags/search), AI parse client
hooks at save/sync cadence, consolidate the drifted Mac/iOS preview JS into
`PreviewUserScripts`.

**Risk register (top):** (1) TextKit 1 pivot invalidates Wisk's TextKit 2
typing-path fixes — by design; (2) attachment attribute collisions with the
highlighter's per-paragraph resets; (3) SwiftUI binding round-trip guards must be
ported exactly; (4) regex editor vs cmark preview disagreement; (5) Clearly's
resource bookkeeping (shared web assets re-declared per target) will bite during
rebrand — follow checklist §1; (6) the sandbox app has no note list today, so
WiskNext's primary navigation is net-new UI, not a port.
