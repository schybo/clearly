# PORT-NOTES — Clearly → Wisk sandbox port findings

Consolidated from four parallel read-only exploration agents (2026 session).
Fork: `schybo/clearly` @ `e79f602` ("[mac] feat: add Rich Text export (#412)"), upstream `Shpigford/clearly`.
Checkout: `~/clarved/clearly` — independent of the Wisk repo; Wisk stays untouched until the decision gate.

> §4 (data model & integration surface) is still being written by its exploration agent and will be appended when it lands.

---

## TL;DR for the port

1. **The composer engine is two classes with a tiny contract** — `MarkdownSyntaxHighlighter` (regex-driven, 100% attribute-only) plus an optional Mac gutter layer. No cmark, no DocumentGroup coupling inside the engine. Highly transplantable.
2. **TextKit 1 everywhere, deliberately.** The engine requires a live `NSTextStorage` + `NSLayoutManager`; attribute edits are dead on TextKit 2's `NSTextContentStorage`. This is the repo's #1 documented invariant (`CLAUDE.md:93`). Wisk's current editor is TextKit 2 — the sandbox is a full pivot, not a retrofit.
3. **QuickType-safe by construction:** zero programmatic content edits per keystroke. The visible string only ever changes from the user or IME. Three guards (marked-text gate, `pendingBindingUpdates`, `isHighlighting`) are load-bearing — port them together with the engine.
4. **Rebranding to a sandbox app is mechanical** — bundle ids, product names, icons, signing team, Sparkle feed. No deep coupling between app shell and engine.
5. **The data layer is thin** (DocumentGroup `.md` files, UserDefaults, no SwiftData/sync/attachments) — everything Wisk adds, Clearly lacks, so there is nothing to *undo* when supplanting Wisk systems.

---

## 1. Project structure & build

### Layout

| Path | Role |
|---|---|
| `Clearly/` | macOS app source (editor, windows, commands) |
| `Clearly/iOS/` | iOS app source (browser, editor, preview, extensions) |
| `Shared/` | Cross-platform resources only — no shared Swift code |
| `Packages/ClearlyCore/` | The shared engine package (SPM local package) |
| `ClearlyQuickLook/` | macOS Quick Look app extension |
| `scripts/` | notarize-mac.sh, notarize-ios.sh, install-local-mac.sh, gen-xcode.sh |
| `website/` | Marketing site (clearly.md) — decoupled from the app |
| `docs/` | Architecture docs incl. `markdown-rendering-architecture.md` |
| `project.yml` | XcodeGen manifest (Wisk uses the same generator — familiar) |

### Targets (project.yml)

| Target | Platform | Type |
|---|---|---|
| `Clearly` | macOS 15+ | app |
| `Clearly-iOS` | iOS 17+, device family 1,2 | app |
| `ClearlyQuickLook` | macOS | app extension (Finder preview) |
| `ClearlyPreview-iOS` | iOS | app extension |
| `ClearlyThumbnail-iOS` | iOS | app extension |

- Bundle ids: `com.sabotage.clearly` (`.dev` for Debug, per-target suffixes for extensions). `DEVELOPMENT_TEAM: W33JZPPPFN` (Shpigford's — must change or build with `CODE_SIGNING_ALLOWED=NO`).
- Mac and iOS version **independently** (Mac 3.3.0, iOS 2.1.0 in project.yml) — mirrors Wisk's dual-target scheme.
- External SPM deps: `cmark-gfm` (read-only preview rendering only), `Sparkle` (Mac updater), `KeyboardShortcuts` (Mac global shortcuts).
- **Local package `ClearlyCore`** is included in *all five* targets: 41 Swift files, ~11.2k LOC. Contents: `SyntaxHighlighter.swift` (composer), `MarkdownParser.swift`, `DocumentRender.swift` (markdown → HTML for preview), `DocumentURL.swift`, document thumbnail/preview types, `Extensions/` (MarkdownDocument, DocumentModel, SettingsModel, Theme, SwiftUIHelpers, OpenGraphFetcher), `Utilities/`.

### Boot sequence

- **Mac:** `ClearlyApp.swift` → `DocumentGroup(newDocument: MarkdownDocument.empty, editor: EditorRootView)` → `WindowSplitView` — `NavigationSplitView` with sidebar `SourceListView` and detail `MarkdownEditorView`.
- **iOS:** `DocumentGroup(.markdown)` → `DocumentBrowserView` (file list) → `DocumentDetailView` hosting a `TabView`-style `MarkdownSegment` / `PreviewSegment` split with `MarkdownToolbar` above the keyboard.

### Build-system notes

- `scripts/gen-xcode.sh` wraps `xcodegen` — the `.xcodeproj` is generated, not committed by hand (same workflow as Wisk).
- Shared JS/CSS resources (mermaid, katex, highlight.js, svg-pan-zoom, fonts) are **duplicated in all five targets' source lists** as `buildPhase: resources`; folder-type resources use `type: folder`. Adding a shared resource means editing every target block.
- `ExportOptions*.plist` at repo root are for release notarization; not needed for sandbox dev.

### Rebrand checklist (Clearly → sandbox app, working name WiskNext)

1. `project.yml`: `name:` → WiskNext; all `PRODUCT_BUNDLE_IDENTIFIER`s (`com.sabotage.clearly.*` → own id); `PRODUCT_NAME`s; `DEVELOPMENT_TEAM` → Brent's team.
2. Debug-variant names ("Clearly Dev") and per-extension bundle-id suffixes.
3. `Clearly/Info.plist` + `Clearly/iOS/Info-iOS.plist` display names, URL schemes.
4. App icons: `Clearly/AppIcon` (macOS), `Clearly/iOS/AppIcon.icon` (iOS).
5. Sparkle updater feed URL + EdDSA signing key — **drop or replace** for the sandbox (no auto-updates wanted).
6. `ExportOptions-*.plist` — ignore for dev builds.
7. Scripts: hardcoded app names/paths in `notarize-*.sh`, `install-local-mac.sh` (not needed pre-gate).
8. Menu-bar strings/window titles ("Clearly") — sweep with grep at rebrand time.
9. `ClearlyQuickLook` target name/ids.
10. Keep `upstream` remote pointing at Shpigford/clearly for future pulls; fork remote is `schybo/clearly`.

---

## 2. Text composer / input pipeline  ⭐ the crown jewel

**Engine file:** `Packages/ClearlyCore/Sources/ClearlyCore/Rendering/MarkdownSyntaxHighlighter.swift` (757 lines), shared verbatim by both platforms via `PlatformTextStorage`/`PlatformFont` typealiases (`Platform/Platform.swift:5-22`).

**Model:** pure regex enumeration over the live string — ~24 precompiled `NSRegularExpression`s with paired `HighlightStyle`s (`:30-120`): frontmatter, fenced code, `$$` math, headings, emphasis, strikethrough, inline code, images/links, blockquotes, list markers, tasks, HR, `==highlight==`, footnotes, table rows, setext headings, HTML tags. No parse tree, no cmark in the editor path (cmark-gfm is preview-only). Consequence: editor styling and cmark preview can disagree on edge cases — accepted trade.

**Highlight application is 100% attribute-only.** Every entry point wraps work in `beginEditing()`/`endEditing()` and calls only `addAttributes`/`addAttribute`/`removeAttribute` on existing ranges. No `replaceCharacters`, no wipe-and-rewrite, no invisible markers. `**` stays visibly in the string, styled in a marker color.

**Range strategy: paragraph-scoped incremental with full-reparse fallbacks.**
- `highlightAll(_:caller:)` (`:163-407`): base attributes full-range, all patterns full-range, collecting *protected ranges* (code/math/frontmatter) that suppress inner styling.
- `highlightAround(_:editedRange:replacementLength:caller:)` (`:448-729`): expand post-edit range to paragraph via `paragraphRange(for:)`, reset + re-run patterns only there. >5 M-char paragraphs bail out (`Limits.swift:8`) to avoid catastrophic regex.
- Edits touching a block delimiter (```` ``` ````, `$$`, `---`) set `needsFullHighlight` → host schedules a **deferred 0.3 s full re-highlight** while the paragraph still paints immediately.
- Optimizations that matter on large docs: skip font reset when paragraph is already default-font ("avoids glyph regeneration, which is the main per-keystroke cost", `:507-524`); protected ranges shifted by edit delta instead of rebuilt (`:528-551`).

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
- Mac: `EditorView.swift:611-714` (Coordinator), text view `ClearlyTextView.swift:47` inside a hand-built TextKit 1 stack (`MarkdownHeadingLayout.swift:206-215`).
- Mac scratchpad (menu-bar windows): `ScratchpadEditorView.swift:151-177` — proves the engine runs outside DocumentGroup.
- iOS: `EditorView_iOS.swift:411-477` + `ClearlyUITextView.swift:10` which forces TextKit 1 by passing a non-nil container to `super.init(frame:textContainer:)` (`:14-23`).

### Why QuickType/autocorrect survive (the fix for Wisk's original bug)

1. **Zero app-driven content edits per keystroke.** The input manager's model (marked ranges, undo, autocorrect candidates, selectedRange) is never invalidated. Autocorrect *replacements* arrive as normal user edits through `shouldChangeTextIn` and highlight correctly.
2. **IME guards:** `markedTextRange == nil` gate before any content write (`EditorView_iOS.swift:44-52`), `hasMarkedText()` gate (`EditorView.swift:345`), stale-range validation with safe fallback to `highlightAll` (`MarkdownSyntaxHighlighter.swift:453-464`).
3. **SwiftUI round-trip suppression:** `pendingBindingUpdates` counter so `updateNSView`/`updateUIView` never overwrite the text view mid-composition (`EditorView_iOS.swift:47,472-477`; `EditorView.swift:344`).
4. **Where harmony couldn't be guaranteed, they disabled the rewriter:** iOS sets `autocorrectionType/smartQuotesType/smartDashesType/smartInsertDeleteType = .no` (`ClearlyUITextView.swift:32-35`); Mac disables quote/dash/text replacement (`EditorView.swift:87-89`). Spell check (overlay, non-rewriting) stays on.

### Undo, cursor, scroll

- Mac: **dedicated `UndoManager` per text view** (`EditorView.swift:397-406`) — SwiftUI DocumentGroup registers an undo per binding write which breaks NSTextView coalescing when shared (#390). Port this if the sandbox writes bindings per keystroke.
- iOS: native UITextView undo; find/replace has its own grouped undo (`EditorView_iOS.swift:330-361`).
- Selection is never restored during typing — attribute edits can't move it. Content paths (external load, paste) clamp/restore explicitly.
- Scroll preserved around re-highlights (`EditorView.swift:635-666`); `scrollViewDidScroll` suppressed during highlighting (deadlock comment `:716-742`); repaint via visible-rect `setNeedsDisplay` (`:751-755`).
- Document open: set text → `highlightAll`, delegate attached *after* (`EditorView.swift:115-123`); 50 MB open cap (`Limits.swift`).

### Engine ↔ host contract (what a host app must supply)

1. A real TextKit 1 `NSTextStorage`.
2. Edited range + replacement length captured from `shouldChangeTextIn` before the edit lands.
3. A post-edit delegate callback to trigger `highlightAround`.
4. A re-entrancy suppression flag for programmatic writes.

That's it — no cmark, no model objects, no document reference. `Theme` + `Limits` are its only ClearlyCore dependencies.

### Transplant risks for Wisk

- **Attribute namespace collision:** the highlighter *resets* `.font/.foregroundColor/.paragraphStyle/.backgroundColor/.strikethroughStyle` per paragraph (`:507-524`). Wisk attachment placeholders living on those keys would be stripped per keystroke → must move Wisk attachment styling to custom `NSAttributedString.Key`s and add attachment ranges to the protected-ranges mechanism (`isInsideProtectedRange`, `:733`).
- **TextKit 2 incompatibility** — Wisk's editor is TextKit 2; the sandbox is a deliberate pivot to TextKit 1.
- **IME/SwiftUI guards are load-bearing** — each was added after a real bug; port together or reproduce those bugs.
- **Regex semantics** — editor vs preview can disagree on nested emphasis edge cases.
- **iOS smart features default off** — Wisk may want autocorrect ON; Clearly's evidence says replacement-style edits flow fine through the pipeline, so this is a choice, not a constraint.

---

## 3. UI layer

### macOS (Clearly/, excluding iOS/)

- `EditorRootView.swift` — root editor scene (DocumentGroup editor closure).
- `WindowSplitView.swift` — `NavigationSplitView` shell: sidebar (`SourceListView`: recent documents, tags) + detail (`MarkdownEditorView`).
- `MarkdownEditorView.swift` — bridges `EditorView` (NSViewRepresentable) with document state, find bar, TOC.
- `EditorView.swift` — the `EditorView` NSViewRepresentable + Coordinator (composer host, §2), wraps `ClearlyTextView` + `LineNumberRulerView` (gutter) + `FindBarView` (⌘F, :394/:520 are the only `insertNewline` refs — no list auto-continuation by design).
- `SearchView.swift` — in-document search UI; `TableOfContentsView.swift` — heading outline panel.
- `PreviewView.swift` — read-only rendered preview (WKWebView).
- `ScratchpadEditorView.swift` / `ScratchpadView.swift` — menu-bar quick-capture windows (separate editor instance of the same engine).
- `SettingsView.swift` — Mac settings (theme, fonts, editor behavior); `StatsView.swift` — word/char counts.
- Menu/keyboard commands: app-scoped via `KeyboardShortcuts` + standard `CommandMenu`s in `ClearlyApp.swift`.
- Custom touches worth keeping: 2 pt custom caret (`ClearlyTextView.swift:52-70`), hanging `#` gutter via `MarkdownLayoutManager.setExtraLineFragmentRect` (`MarkdownHeadingLayout.swift:221-249`), non-contiguous layout for large docs (`EditorView.swift:109`).

### iOS (Clearly/iOS/)

- `DocumentBrowserView.swift` — DocumentGroup browser customization (list of `.md` files).
- `DocumentDetailView.swift` — editor screen; `MarkdownSegment` / `PreviewSegment` for the source/preview toggle; `InfoSheet.swift` for metadata.
- `MarkdownToolbar.swift` — the formatting accessory above the keyboard (bold/italic/heading/list/link/quote/code insertion via `insertMarkdown`, `ClearlyUITextView.swift:128-137`).
- `ClearlyUITextView.swift` + `EditorView_iOS.swift` — the composer host (§2). `keyboardDismissMode = .interactive`.
- iPad: same single-column editor (device family 1,2; no split-editor adaptation).

### Preview pipeline

- Editor → `DocumentRender` (ClearlyCore) uses **cmark-gfm** → HTML → `WKWebView` (`PreviewView` Mac / `PreviewSegment` iOS).
- Shared/Resources carry the preview stack: `mermaid.min.js` (diagrams), `katex.min.js/.css` (math), `highlight.min.js` + `highlight-theme.css` (code), `svg-pan-zoom.min.js`, bundled fonts, plus `demo.md`/`getting-started.md` seeds.
- Sync with editing: preview refresh is on segment switch / save cadence (see docs/markdown-rendering-architecture.md) — not per-keystroke.

### Themes & typography

- `Theme` lives in ClearlyCore (`Extensions/Theme.swift`): syntax colors, marker colors, background; consumed by both highlighter and preview CSS generation.
- Font/size settings in SettingsModel; dark mode via appearance change → full `highlightAll` re-run (`EditorView.swift:314-323`).

### Extensions

- `ClearlyQuickLook` (macOS): renders `.md` previews in Finder via the same `DocumentRender` + WKWebView stack.
- `ClearlyPreview-iOS` / `ClearlyThumbnail-iOS`: share the same rendering path for Files-app previews/thumbnails.

### PORT CONSIDERATIONS

- **Editor-coupled (keep):** `EditorView`/`EditorView_iOS` hosts, `ClearlyTextView`/`ClearlyUITextView`, `MarkdownSyntaxHighlighter`, gutter, find bar, toolbar.
- **Document-model-coupled (replace):** `DocumentGroup` wiring, `MarkdownDocument` file I/O, browser views → becomes Wisk SwiftData + list UI.
- **Generic/reusable (keep or adapt):** preview pipeline (WKWebView + cmark + katex/mermaid/highlight), `Theme`, settings UI patterns, Quick Look extensions (nice-to-have later).

---

## 4. Data model & integration surface

### Document model

- `Clearly/MarkdownDocument.swift` — `MarkdownDocument: FileDocument`, UTType `net.daringfireball.markdown`. Three initializers: `init()`, `init(text:)`, and `init(configuration:)` (the read path).
- **Value semantics, not reference semantics**: SwiftUI's DocumentGroup treats the document as a value — **every edit produces a new `MarkdownDocument` instance** flowing through the `@Binding`. The editor host writes the full string back on each `textDidChange` (via `commitTextViewContents` → binding). There is no long-lived document object with incremental mutations.
- Read/write: `fileWrapper`/`init(fileWrapper:)` round-trips plain UTF-8 markdown text. `documentURL` is passed through for the editor's per-document state (fold state, etc. keyed by URL).
- **No autosave machinery of its own** — DocumentGroup + the system handle scheduling/coordination.

### Persistence inventory (what does NOT exist)

- **No SwiftData, no CoreData, no UserDefaults persistence** (verified by grep — `@AppStorage`/`UserDefaults` absent from data paths; settings live in `SettingsModel` within the document-bound app state, not a global store).
- **No database of any kind.** The Files-app document browser *is* the note list. No tags, no folders-of-its-own, no recents of its own (system recents only).
- Scratchpads (Mac menu-bar quick notes) are **in-memory only** — lost on quit (`ScratchpadManager.swift`).

### Attachments story

- Images are referenced by markdown syntax `![alt](path)`; `LocalImageSupport` resolves **relative paths next to the document** for preview; remote URLs are fetched live.
- `ImagePasteService` writes pasted images as **sibling PNG files** next to the `.md` and inserts the reference (Mac `ClearlyTextView.paste` :85-176, iOS `ClearlyUITextView.paste` :60-95, shared `ImageDownloader` with placeholder + `replacePlaceholder`).
- No embedded binary resources, no asset management, no attachment attribution system.

### Search

- In-document only: `FindState`/`TextMatcher`/`ReplaceEngine` (ClearlyCore). **No cross-document search exists.**

### Extensions & networking

- Quick Look/Preview/Thumbnail extensions each read the `.md` file URL directly and re-render via the shared `DocumentRender` + WKWebView stack — no shared cache or daemon.
- Only networking in the app: `OpenGraphFetcher` (link previews) and `ImageDownloader` (pasted image URLs). No sync, no accounts, no API client.

### Integration seams for Wisk systems

| Wisk system | Attachment point | Replace vs add |
|---|---|---|
| SwiftData models | `MarkdownDocument.swift` + all `DocumentGroup` wiring in `ClearlyApp.swift` / `ClearlyApp_iOS.swift` | **Replace** — the editor host only needs a text string + binding; it never touches the file URL |
| Firestore sync | the per-keystroke binding write (`commitTextViewContents` / `parent.text =`) | **Add** — enqueue to `SyncMutationWriter` at the same cadence Wisk's autosave uses (never `syncNow` from the typing path) |
| Attachments | `ImagePasteService` + `LocalImageSupport` | **Replace** — route to Wisk's attachment pipeline; move attachment styling to custom `NSAttributedString.Key`s; register attachment ranges as protected ranges in the highlighter |
| Buckets/tags/search | `SourceListView` (Mac) / `DocumentBrowserView` (iOS) | **Replace** — Wisk list UI + `NoteSearchEngine`; Clearly has no cross-doc search to build on |
| AI parse client | none exists | **Add** — copy the `OpenGraphFetcher` pattern for the HTTP surface |

### Highest-risk coupling found

1. **Document identity is the string itself.** Wisk's sync/snapshot model keys off a stable note identity; Clearly's value-semantics document has none — the sandbox must introduce Wisk's `Note` identity as the source of truth and treat the editor as a transient view of `note.body`.
2. **The file URL is the only key** Clearly's per-document state uses (fold state, scratchpads excluded) — swap to Wisk's note ID everywhere.
3. DocumentGroup cannot be kept as the container for SwiftData+Firestore — the sandbox app's scene wiring is a rewrite of `ClearlyApp.swift`/`ClearlyApp_iOS.swift` entry points, while `EditorView`/`EditorView_iOS` hosts survive intact.

---

## 5. What this means for WiskNext (synthesis)

**Keep wholesale:** composer engine + host pattern (§2), preview stack (§3), Mac window chrome as the starting shell.

**Replace first:** data layer — DocumentGroup/.md → Wisk's SwiftData models + Firestore sync. The sandbox editor must learn to render from a SwiftData-backed string instead of a file URL (engine contract §2 confirms it needs no file URL — only an `NSTextStorage`).

**Adapt:** image paste (Clearly writes sibling PNG files via `ImagePasteService` — route to Wisk's attachment pipeline + custom attribute keys + protected ranges), note list/organization UI (Wisk buckets/tags/search replaces `SourceListView` contents), AI parse client hooks at save/sync cadence.

**Risk register (top):** (1) TextKit 1 pivot invalidates Wisk's TextKit 2 typing-path fixes — by design; (2) attachment attribute collisions with the highlighter's per-paragraph resets; (3) SwiftUI binding round-trip guards must be ported exactly; (4) regex editor vs cmark preview disagreement; (5) clearly's own repo conventions (resource duplication across 5 targets) will bite during rebrand — follow checklist §1.
