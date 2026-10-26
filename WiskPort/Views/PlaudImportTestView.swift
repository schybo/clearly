#if os(iOS) && DEBUG
import SwiftData
import SwiftUI

struct PlaudImportTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(WiskAuthService.self) private var authService
    @Environment(SyncService.self) private var syncService
    @Query(filter: #Predicate<NoteBucket> { $0.archivedAt == nil }, sort: \NoteBucket.sortOrder) private var buckets: [NoteBucket]

    @State private var service = PlaudDeviceImportService()
    @State private var selectedNoteType: PlaudImportNoteType = .structured
    @State private var selectedBucketID: UUID?
    @State private var deleteAfterImport = false
    @State private var statusMessage: String?

    var body: some View {
        ZStack {
            Color.wiskCanvasBackground
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    headerCard
                    controlsCard
                    devicesCard
                    recordingsCard
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.lg)
                .padding(.bottom, 120)
                .readableWidth()
            }
        }
        .navigationTitle("Plaud Import")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Label("Plaud device prototype", systemImage: "waveform.badge.magnifyingglass")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)

            Text("Connect a Plaud recorder, import a recording, and save it as a Wisk note with a bucket and note type.")
                .foregroundStyle(Color.wiskSecondaryText)

            if !service.isSDKAvailable {
                Text("Plaud SDK frameworks are not available in this build. Add the SDK package/frameworks and run on a physical iPhone to scan for devices.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Text(stateText)
                .font(.footnote)
                .foregroundStyle(Color.wiskSecondaryText)
                .accessibilityIdentifier("wisk.plaud.state")

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(Color.wiskSecondaryText)
                    .accessibilityIdentifier("wisk.plaud.statusMessage")
            }
        }
        .cardStyle()
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Picker("Region", selection: $service.region) {
                ForEach(PlaudRegion.allCases) { region in
                    Text(region.title).tag(region)
                }
            }
            .pickerStyle(.segmented)

            Picker("Note type", selection: $selectedNoteType) {
                ForEach(PlaudImportNoteType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }

            Picker("Bucket", selection: $selectedBucketID) {
                Text("No bucket").tag(Optional<UUID>.none)
                ForEach(buckets) { bucket in
                    Text(bucket.name).tag(Optional(bucket.id))
                }
            }

            Toggle("Delete recording from Plaud after import", isOn: $deleteAfterImport)
                .font(.subheadline)

            HStack {
                Button {
                    Task { await service.prepare(authService: authService) }
                } label: {
                    Label("Fetch token", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wisk.plaud.fetchTokenButton")

                Button {
                    service.startScan()
                } label: {
                    Label("Scan", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
                .disabled(service.activeToken == nil)
                .accessibilityIdentifier("wisk.plaud.scanButton")

                Button {
                    service.refreshFileList()
                } label: {
                    Label("Files", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!canRefreshFiles)
                .accessibilityIdentifier("wisk.plaud.filesButton")
            }
        }
        .cardStyle()
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Devices")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)

            if service.devices.isEmpty {
                Text("No Plaud devices discovered yet.")
                    .foregroundStyle(Color.wiskSecondaryText)
            } else {
                ForEach(service.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name)
                                .font(.headline)
                            Text("\(device.serialNumber) • RSSI \(device.rssi)")
                                .font(.caption)
                                .foregroundStyle(Color.wiskSecondaryText)
                        }
                        Spacer()
                        Button("Connect") {
                            service.connect(to: device)
                        }
                        .buttonStyle(.bordered)
                    }
                    .accessibilityIdentifier("wisk.plaud.device.\(device.serialNumber)")
                }
            }
        }
        .cardStyle()
    }

    private var recordingsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Recordings")
                .font(AppFont.sectionTitle)
                .foregroundStyle(Color.wiskPrimaryText)

            if service.recordings.isEmpty {
                Text("Connect to a Plaud device and fetch files to list recordings.")
                    .foregroundStyle(Color.wiskSecondaryText)
            } else {
                ForEach(service.recordings) { recording in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Text(recordingDetail(recording))
                                    .font(.caption)
                                    .foregroundStyle(Color.wiskSecondaryText)
                            }
                            Spacer()
                            Button("Import") {
                                Task { await importRecording(recording) }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("wisk.plaud.import.\(recording.sessionId)")
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }
        }
        .cardStyle()
    }

    private var canRefreshFiles: Bool {
        if case .connected = service.state { return true }
        return false
    }

    private var stateText: String {
        switch service.state {
        case .idle:
            "Ready"
        case .fetchingToken:
            "Fetching Plaud access token..."
        case .scanning:
            "Scanning for Plaud devices..."
        case .connecting(let device):
            "Connecting to \(device.name)..."
        case .connected:
            "Connected"
        case .loadingFiles:
            "Loading recording list..."
        case .exporting(let recording):
            "Exporting recording \(recording.sessionId)..."
        case .transcribing:
            "Uploading and transcribing..."
        case .imported:
            "Imported"
        case .failed(let message):
            "Failed: \(message)"
        }
    }

    private func recordingDetail(_ recording: PlaudRecordingFile) -> String {
        var parts = ["Session \(recording.sessionId)"]
        if recording.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(recording.sizeBytes), countStyle: .file))
        }
        if let duration = recording.duration {
            parts.append(formattedDuration(duration))
        }
        return parts.joined(separator: " • ")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m \(seconds)s"
    }

    private func importRecording(_ recording: PlaudRecordingFile) async {
        do {
            let transcript = try await service.transcribe(recording: recording, authService: authService)
            let bucket = buckets.first { $0.id == selectedBucketID }
            let note = PlaudTranscriptImportService.makeNote(from: PlaudImportedNoteContext(
                recording: recording,
                transcript: transcript,
                noteType: selectedNoteType,
                bucketID: selectedBucketID,
                bucketName: bucket?.name,
                importedAt: Date()
            ))
            modelContext.insert(note)
            try modelContext.save()
            syncService.enqueue(note: note, context: modelContext)
            Task {
                await syncService.syncNow(context: modelContext)
            }
            if deleteAfterImport {
                service.deleteRecording(recording)
            }
            statusMessage = "Imported \(note.title)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
#endif
