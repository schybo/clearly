import SwiftUI
import UniformTypeIdentifiers

struct WiskBuiltInFontChoiceRow: View {
    let family: WiskEditorFontFamily
    let isSelected: Bool
    let accessibilityIdentifier: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family.title)
                        .font(family.font(size: 20))
                        .foregroundStyle(.primary)
                    Text(WiskBuiltInFontChooser.sample)
                        .font(family.font(size: 15))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(family.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct WiskBuiltInFontChooser: View {
    static let sample = "The quick brown fox writes in Wisk."

    var selected: WiskEditorFontFamily?
    var accessibilityIdentifier: String
    var onSelect: (WiskEditorFontFamily) -> Void

    var body: some View {
        List {
            ForEach(WiskEditorFontFamily.allCases) { family in
                WiskBuiltInFontChoiceRow(
                    family: family,
                    isSelected: selected == family,
                    accessibilityIdentifier: "\(accessibilityIdentifier).\(family.rawValue)",
                    onSelect: { onSelect(family) }
                )
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum WiskFontImportTypes {
    static var allowed: [UTType] {
        [
            UTType(filenameExtension: "ttf"),
            UTType(filenameExtension: "otf"),
            UTType(filenameExtension: "ttc"),
            UTType(filenameExtension: "woff"),
            UTType(filenameExtension: "woff2"),
        ].compactMap { $0 }
    }
}

struct WiskGoogleFontPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    let select: (WiskGoogleFont) -> Void

    private var fonts: [WiskGoogleFont] {
        WiskGoogleFontCatalog.search(query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(fonts) { font in
                        Button {
                            select(font)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(font.title)
                                    .font(.headline)
                                Text(font.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Wisk downloads Google Fonts to this device and syncs only the family and variant with your account.")
                }
            }
            .searchable(text: $query, prompt: "Search featured Google Fonts")
            .navigationTitle("Google Fonts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
