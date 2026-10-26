// WiskNext port shim. Upstream Wisk's Views/PlaudImportTestView.swift depends
// on the Plaud BLE SDK frameworks, which are linked in no target yet (see
// ~/clarved/Wisk/docs/PLAUD_IMPORT_QA.md — pending Plaud developer access).
// Services/PlaudDeviceImportService.swift and the real test view are excluded
// from the WiskNext targets until those frameworks land, but MainTabView.swift
// (a byte-identical port) instantiates PlaudImportTestView() in a DEBUG-only
// tab, so the port target needs the type to exist.
//
// When the upstream SDK integration lands, delete this shim and remove the
// project.yml excludes for the two files above.
import SwiftUI

struct PlaudImportTestView: View {
    var body: some View {
        ContentUnavailableView(
            "Plaud Import Unavailable",
            systemImage: "waveform.badge.magnifying.glass",
            description: Text("The Plaud SDK frameworks are not linked in WiskNext yet.")
        )
    }
}
