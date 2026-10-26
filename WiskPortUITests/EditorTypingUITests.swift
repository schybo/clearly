import XCTest

/// Reproducible harness for the reported iOS rich-markdown editor typing
/// symptoms (Views/WiskRichMarkdownEditor.swift):
///
///   1. Characters not appearing while typing (dropped input).
///   2. Backspace misbehaving across word / paragraph / bullet boundaries.
///   3. Odd newlines around list continuation and list exit.
///
/// Harness rules:
/// - Real keyboard input only (`typeText`), exactly like a user typing.
/// - Assertions compare the editor's accessibility `value` (the visible text)
///   against exact expected strings, so one dropped character or one stray
///   newline fails the test.
/// - Caret position is not exposed by XCUITest, so it is asserted indirectly
///   with a sentinel character typed after the operation under test: where the
///   sentinel lands in the resulting text reveals the caret.
/// - Autocapitalization: the editor capitalizes sentence starts (see the
///   existing `testSentenceStartCapitalization`), so expectations use already
///   capitalized words and avoid ambiguity.
/// - Each test uses a unique `WISK_SYNC_TEST_UID` so
///   `WISK_RESET_LOCAL_STORE=1` gives it an empty local store.
final class EditorTypingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Symptom 1: characters not appearing

    /// One rapid burst: a long sentence typed in a single `typeText` call.
    @MainActor
    func testRapidLongSentenceTypesAllCharacters() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-rapid")
        let editor = openNewBodyEditor(app: app)

        let sentence = "The quick brown fox jumps over the lazy dog and keeps typing rapidly across the whole line without pausing"
        editor.typeText(sentence)

        assertValue(editor, equals: sentence, message: "rapid single-burst typing dropped or altered characters")
    }

    /// Rapid chunked bursts: words typed back to back with no waits.
    @MainActor
    func testChunkedBurstTypingDoesNotDropCharacters() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-burst")
        let editor = openNewBodyEditor(app: app)

        let words = ["Alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
                     "golf", "hotel", "india", "juliett", "kilo", "lima"]
        for word in words {
            editor.typeText(word + " ")
        }
        let expected = words.map { $0 + " " }.joined()

        assertValue(editor, equals: expected, message: "chunked burst typing dropped or altered characters")
    }

    // MARK: - Symptom 2: backspace behavior

    /// Backspace within/across word boundaries, with a sentinel typed after
    /// each step to pin the caret.
    @MainActor
    func testBackspaceAcrossWordBoundariesPreservesTextAndCaret() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-backspace-word")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("Alpha Beta Gamma Delta")
        editor.typeText("\u{8}") // single backspace
        assertValue(editor, equals: "Alpha Beta Gamma Delt", message: "single backspace removed the wrong text")

        editor.typeText("X") // sentinel: caret must sit right after the deleted character
        assertValue(editor, equals: "Alpha Beta Gamma DeltX", message: "caret was not immediately after backspace")

        // Five backspaces delete "DeltX" and cross the space before it.
        editor.typeText(String(repeating: "\u{8}", count: 5))
        editor.typeText("Y")
        assertValue(editor, equals: "Alpha Beta Gamma Y", message: "backspace across a word boundary left wrong text or caret")
    }

    /// Backspace across a paragraph boundary must join the two lines.
    @MainActor
    func testBackspaceAcrossParagraphBoundaryJoinsLines() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-backspace-para")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("First paragraph")
        editor.typeText("\n")
        editor.typeText("Second paragraph")
        assertValue(editor, equals: "First paragraph\nSecond paragraph", message: "setup: two-paragraph text")

        // Delete "Second paragraph" (16 characters).
        editor.typeText(String(repeating: "\u{8}", count: 16))
        assertValue(editor, equals: "First paragraph\n", message: "backspacing through the last paragraph")

        // One more backspace crosses the paragraph boundary and must join.
        editor.typeText("\u{8}")
        assertValue(editor, equals: "First paragraph", message: "backspace across the paragraph boundary did not join the lines")

        editor.typeText("!")
        assertValue(editor, equals: "First paragraph!", message: "caret was not at the joined paragraph boundary")
    }

    /// Backspace across an empty bullet continuation line: the editor stores a
    /// hidden markdown prefix ("- ") behind the visible "• ", so the join
    /// behavior is a known risk area for "backspace misbehaving".
    @MainActor
    func testBackspaceAcrossBulletContinuationJoinsLines() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-backspace-bullet")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("- Alpha item")
        editor.typeText("\n")
        editor.typeText("Beta item")
        assertValue(editor, equals: "• Alpha item\n• Beta item", message: "setup: two bullet items")

        // Delete "Beta item" (9 characters), leaving an empty continuation bullet.
        editor.typeText(String(repeating: "\u{8}", count: 9))
        assertValue(editor, equals: "• Alpha item\n• ", message: "backspacing through the second bullet item")

        // One backspace must remove the empty bullet (including its hidden
        // "- " prefix) and join onto the previous bullet line. If the newline
        // survives instead, that is the "odd newline" symptom showing up in a
        // backspace scenario ("• Alpha item\n").
        editor.typeText("\u{8}")
        assertValue(editor, equals: "• Alpha item", message: "backspace over an empty bullet did not remove the bullet line")

        editor.typeText("!")
        assertValue(editor, equals: "• Alpha item!", message: "caret was not at the joined bullet line")
    }

    // MARK: - Symptom 3: odd newlines (bullets / list exit)

    /// Bullet list lifecycle: create via "- " shortcut, Return continues the
    /// list, Return on an empty bullet exits the list onto a plain paragraph.
    @MainActor
    func testBulletContinueSecondItemAndExitListWithDoubleReturn() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-bullets")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("- ")
        assertValue(editor, equals: "• ", message: "- shortcut did not convert to a bullet")

        editor.typeText("Grocery item")
        assertValue(editor, equals: "• Grocery item", message: "typing inside the bullet")

        editor.typeText("\n") // Return must continue the list
        assertValue(editor, equals: "• Grocery item\n• ", message: "Return did not continue the bullet list")

        editor.typeText("Second item")
        assertValue(editor, equals: "• Grocery item\n• Second item", message: "typing the second bullet item")

        editor.typeText("\n") // empty continuation bullet
        assertValue(editor, equals: "• Grocery item\n• Second item\n• ", message: "empty continuation bullet")

        editor.typeText("\n") // Return on the empty bullet must exit the list
        assertValue(
            editor,
            equals: "• Grocery item\n• Second item\n",
            message: "double-Return list exit left wrong text (a stray or missing newline here is the odd-newline symptom)"
        )

        editor.typeText("After list") // sentinel: caret must be on the plain paragraph line
        assertValue(
            editor,
            equals: "• Grocery item\n• Second item\nAfter list",
            message: "caret did not land on the paragraph line after list exit"
        )
    }

    // MARK: - Newline behavior at document end / immediately after typing

    /// A Return at the very end of the document must render the newline.
    @MainActor
    func testNewlineAtEndOfDocumentRendersBlankLine() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-trailing-newline")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("Tail line")
        editor.typeText("\n")
        assertValue(editor, equals: "Tail line\n", message: "newline at end of document was swallowed or duplicated")

        editor.typeText("After newline")
        assertValue(editor, equals: "Tail line\nAfter newline", message: "caret did not move to the new final line")
    }

    /// Type a word and press Return immediately (no pause): the newline must
    /// be rendered between the two lines.
    @MainActor
    func testTypeThenImmediateReturnRendersNewline() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-instant-return")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("Instant")
        editor.typeText("\n") // immediate Return, no wait
        editor.typeText("Line")

        assertValue(editor, equals: "Instant\nLine", message: "immediate Return after typing lost or doubled the newline")
    }

    /// The reported caret jump-up: the first character typed on a new line was
    /// attributed to the previous line's incremental patch, so it landed in
    /// the source but never rendered, and the caret jumped up to the previous
    /// line's end (the next keystroke then made both letters appear).
    @MainActor
    func testFirstCharOnNewLineAppearsImmediately() throws {
        let app = launchFreshApp(uid: "wisk-ios-typing-newline-first-char")
        let editor = openNewBodyEditor(app: app)

        editor.typeText("First line")
        editor.typeText("\n")
        editor.typeText("S")

        assertValue(editor, equals: "First line\nS", message: "first character typed on a new line was dropped or the caret jumped up a line")
    }

    // MARK: - Harness helpers

    private func launchFreshApp(uid: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WISK_RESET_LOCAL_STORE"] = "1"
        app.launchEnvironment["WISK_SYNC_TEST_UID"] = uid
        app.launchEnvironment["WISK_BYPASS_AUTH"] = "1"
        app.launch()
        return app
    }

    private func openNewBodyEditor(app: XCUIApplication) -> XCUIElement {
        let newNoteButton = app.buttons["wisk.notes.newButton"]
        XCTAssertTrue(newNoteButton.waitForExistence(timeout: 10), "New-note button never appeared")
        newNoteButton.tap()

        let editor = app.textViews["wisk.note.bodyEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Body editor never appeared")
        activateEditor(editor)
        return editor
    }

    private func activateEditor(_ editor: XCUIElement) {
        if editor.isHittable {
            editor.tap()
            return
        }
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Waits up to `timeout` for the editor's visible text to become exactly
    /// `expected`, then asserts equality. Returns the observed value so the
    /// failure excerpt shows expected vs actual.
    @discardableResult
    private func assertValue(
        _ editor: XCUIElement,
        equals expected: String,
        timeout: TimeInterval = 4,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let predicate = NSPredicate(format: "value == %@", expected)
        let settled = XCTNSPredicateExpectation(predicate: predicate, object: editor)
        let result = XCTWaiter.wait(for: [settled], timeout: timeout)
        let actual = (editor.value as? String) ?? "<nil>"
        XCTAssertEqual(
            result, .completed,
            "\(message) — expected \(expected.debugDescription), observed \(actual.debugDescription)",
            file: file, line: line
        )
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "value-mismatch"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        return actual
    }
}
