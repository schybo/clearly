import SwiftUI

struct NoteRouteSettingsForm: View {
    @State private var settings = NoteRouteSettings.shared
    @State private var todoistDraft = ""
    @State private var schyboDraft = ""
    @State private var isConnectingTodoist = false
    @State private var isConnectingSchybo = false
    @State private var statusMessage: String?

    private let client = NoteRouteHTTPClient()

    var body: some View {
        @Bindable var settings = settings

        Group {
            Section {
                SecureField("API token", text: $todoistDraft)
                    .accessibilityIdentifier("wisk.settings.routing.todoistToken")
                LabeledContent("Status", value: settings.isTodoistConnected ? "Connected" : "Not connected")
                if settings.todoistProjects.isEmpty == false {
                    LabeledContent("Projects", value: "\(settings.todoistProjects.count)")
                }
                HStack {
                    Button(isConnectingTodoist ? "Connecting…" : "Connect") {
                        connectTodoist()
                    }
                    .disabled(isConnectingTodoist || todoistDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("wisk.settings.routing.todoistConnect")
                    if settings.isTodoistConnected {
                        Button("Disconnect", role: .destructive) {
                            settings.disconnectTodoist()
                            statusMessage = "Todoist disconnected."
                        }
                        .accessibilityIdentifier("wisk.settings.routing.todoistDisconnect")
                    }
                }
            } header: {
                Text("Todoist")
            } footer: {
                Text("Paste the token from Todoist Settings → Integrations → Developer. Route uses this account’s projects.")
            }

            Section {
                TextField("Site address", text: $settings.schyboBaseURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .accessibilityIdentifier("wisk.settings.routing.schyboURL")
                SecureField("Learning API token", text: $schyboDraft)
                    .accessibilityIdentifier("wisk.settings.routing.schyboToken")
                LabeledContent("Status", value: settings.isSchyboConnected ? "Connected" : "Not connected")
                HStack {
                    Button(isConnectingSchybo ? "Connecting…" : "Connect") {
                        connectSchybo()
                    }
                    .disabled(isConnectingSchybo || schyboDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("wisk.settings.routing.schyboConnect")
                    if settings.isSchyboConnected {
                        Button("Disconnect", role: .destructive) {
                            settings.disconnectSchybo()
                            statusMessage = "SCHYBO disconnected."
                        }
                    }
                }
            } header: {
                Text("SCHYBO")
            } footer: {
                Text("Optional. Adages still save in Wisk when this is disconnected. A connected account also publishes a copy.")
            }

            Section {
                if settings.mappings.isEmpty {
                    Text("No prefix mappings yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.mappings) { $mapping in
                    mappingRow($mapping)
                }
                Button("Add Mapping") {
                    settings.mappings.append(NoteRouteMapping())
                }
                .accessibilityIdentifier("wisk.settings.routing.addMapping")
            } header: {
                Text("Mappings")
            } footer: {
                Text("A line matches when it starts with the prefix and a dash, such as A/G - text or Wisk - text.")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("wisk.settings.routing.status")
                }
            }
        }
        .accessibilityIdentifier("wisk.settings.routing")
    }

    @ViewBuilder
    private func mappingRow(_ mapping: Binding<NoteRouteMapping>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Prefix", text: mapping.prefix)
                    .accessibilityIdentifier("wisk.settings.routing.prefix")
                Button(role: .destructive) {
                    settings.mappings.removeAll { $0.id == mapping.wrappedValue.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Remove mapping")
            }
            .onChange(of: mapping.wrappedValue.prefix) { oldPrefix, newPrefix in
                if mapping.wrappedValue.collectionName.isEmpty || mapping.wrappedValue.collectionName == oldPrefix {
                    mapping.wrappedValue.collectionName = newPrefix
                }
                if mapping.wrappedValue.shorthand.isEmpty || mapping.wrappedValue.shorthand == oldPrefix {
                    mapping.wrappedValue.shorthand = newPrefix
                }
            }

            Picker("Destination", selection: mapping.destination) {
                Text("In Wisk").tag(NoteRouteDestination.wiskAdage)
                Text("SCHYBO and Wisk").tag(NoteRouteDestination.schyboAndWisk)
                Text("Todoist").tag(NoteRouteDestination.todoist)
            }
            .onChange(of: mapping.wrappedValue.destination) { previous, destination in
                if destination == .schyboAndWisk, settings.isSchyboConnected == false {
                    mapping.wrappedValue.destination = previous
                    statusMessage = "Connect SCHYBO to publish adages."
                } else if destination == .todoist, settings.isTodoistConnected == false {
                    mapping.wrappedValue.destination = previous
                    statusMessage = "Connect Todoist to choose a project."
                }
            }

            if mapping.wrappedValue.destination != .todoist {
                TextField("Collection", text: mapping.collectionName)
            }
            if mapping.wrappedValue.destination == .schyboAndWisk {
                TextField("SCHYBO shorthand", text: mapping.shorthand)
                if settings.isSchyboConnected == false {
                    Text("Connect SCHYBO before this mapping can publish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if mapping.wrappedValue.destination == .todoist {
                Picker("Project", selection: mapping.todoistProjectID) {
                    Text("Choose a project").tag("")
                    ForEach(settings.todoistProjects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                .onChange(of: mapping.wrappedValue.todoistProjectID) { _, projectID in
                    mapping.wrappedValue.todoistProjectName = settings.todoistProjects.first { $0.id == projectID }?.name ?? ""
                }
                if settings.isTodoistConnected == false {
                    Text("Connect Todoist to choose a project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func connectTodoist() {
        let token = todoistDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else { return }
        isConnectingTodoist = true
        statusMessage = nil
        Task {
            do {
                let projects = try await client.listProjects(token: token)
                try settings.saveTodoistConnection(token: token, projects: projects)
                todoistDraft = ""
                statusMessage = "Todoist connected."
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnectingTodoist = false
        }
    }

    private func connectSchybo() {
        let token = schyboDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty == false else { return }
        guard let lessonsURL = settings.lessonsURL() else {
            statusMessage = "Enter a valid SCHYBO address."
            return
        }
        isConnectingSchybo = true
        statusMessage = nil
        Task {
            do {
                try await client.verifyLearningToken(lessonsURL: lessonsURL, token: token)
                try settings.saveSchyboConnection(token: token)
                schyboDraft = ""
                statusMessage = "SCHYBO connected."
            } catch {
                statusMessage = error.localizedDescription
            }
            isConnectingSchybo = false
        }
    }
}
