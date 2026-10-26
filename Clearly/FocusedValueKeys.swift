import SwiftUI
import ClearlyCore

// FocusedValue keys + FocusedValues accessors, extracted from ClearlyApp.swift
// so the WiskNext port target (which excludes ClearlyApp.swift in favor of
// Wisk's app entry) still gets the focused-value contract shared with
// ContentView's keypath usage.

struct FindStateKey: FocusedValueKey {
    typealias Value = FindState
}

struct OutlineStateKey: FocusedValueKey {
    typealias Value = OutlineState
}

struct ViewModeKey: FocusedValueKey {
    typealias Value = Binding<ViewMode>
}

struct ExportPDFActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ExportRichTextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct PrintDocumentActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var findState: FindState? {
        get { self[FindStateKey.self] }
        set { self[FindStateKey.self] = newValue }
    }
    var outlineState: OutlineState? {
        get { self[OutlineStateKey.self] }
        set { self[OutlineStateKey.self] = newValue }
    }
    var viewMode: Binding<ViewMode>? {
        get { self[ViewModeKey.self] }
        set { self[ViewModeKey.self] = newValue }
    }
    var exportPDFAction: (() -> Void)? {
        get { self[ExportPDFActionKey.self] }
        set { self[ExportPDFActionKey.self] = newValue }
    }
    var exportRichTextAction: (() -> Void)? {
        get { self[ExportRichTextActionKey.self] }
        set { self[ExportRichTextActionKey.self] = newValue }
    }
    var printDocumentAction: (() -> Void)? {
        get { self[PrintDocumentActionKey.self] }
        set { self[PrintDocumentActionKey.self] = newValue }
    }
}
