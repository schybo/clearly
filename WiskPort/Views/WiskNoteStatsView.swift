import SwiftUI

struct WiskNoteStatsView: View {
    let statistics: WiskNoteStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(statistics.wordCountLabel, systemImage: "textformat")
            Label(statistics.characterCountLabel, systemImage: "character")
            Label(statistics.readTimeLabel, systemImage: "clock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wisk.note.stats")
        .accessibilityLabel(
            "\(statistics.wordCountLabel), \(statistics.characterCountLabel), \(statistics.readTimeLabel)"
        )
    }
}
