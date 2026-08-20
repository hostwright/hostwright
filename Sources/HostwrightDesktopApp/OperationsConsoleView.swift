import SwiftUI
import HostwrightDesktopModel

struct MenuBarLabel: View {
    @EnvironmentObject private var model: DesktopOperationsModel

    var body: some View {
        Label(model.connectionState.label, systemImage: connectionImage)
            .foregroundStyle(connectionColor)
            .accessibilityLabel("Hostwright connection: \(model.connectionState.label)")
    }

    private var connectionImage: String {
        switch model.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .unavailable: return .red
        case .disconnected: return .secondary
        }
    }
}

struct OperationsConsoleView: View {
    @EnvironmentObject private var model: DesktopOperationsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage(DesktopSceneStorageKey.selection) private var storedSelection = "overview"
    @SceneStorage(DesktopSceneStorageKey.selectedProject) private var storedProjectID = ""
    @SceneStorage(DesktopSceneStorageKey.selectedService) private var storedServiceID = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $storedSelection) {
                Section("Workspace") {
                    Label("Overview", systemImage: "rectangle.3.group")
                        .tag("overview")
                    Label("Events", systemImage: "list.bullet.rectangle")
                        .tag("events")
                    Label("Logs", systemImage: "text.alignleft")
                        .tag("logs")
                }

                Section("Connection") {
                    Label(model.connectionState.label, systemImage: connectionImage)
                        .foregroundStyle(connectionColor)
                        .accessibilityLabel("Connection: \(model.connectionState.label)")
                        .accessibilityIdentifier(DesktopAccessibilityIdentifier.connectionState)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Hostwright")
        } detail: {
            Group {
                switch storedSelection {
                case "events": EventsView()
                case "logs": LogsView(selectedServiceID: selectedServiceBinding)
                default: OverviewView(
                    selectedProjectID: selectedProjectBinding,
                    selectedServiceID: selectedServiceBinding
                )
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.reconnect()
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier(DesktopAccessibilityIdentifier.reconnect)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .disabled(model.connectionState == .disconnected)
                    .accessibilityIdentifier(DesktopAccessibilityIdentifier.disconnect)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: storedSelection)
        .task {
            updateSelectionValidity(for: model.projects)
            if case .disconnected = model.connectionState {
                model.connect()
            }
        }
        .onChange(of: model.projects) { _, projects in
            updateSelectionValidity(for: projects)
        }
        .onChange(of: model.connectionState) { _, _ in
            updateSelectionValidity(for: model.projects)
        }
    }

    private var selectedProjectBinding: Binding<String?> {
        Binding(
            get: { storedProjectID.isEmpty ? nil : storedProjectID },
            set: { storedProjectID = $0 ?? "" }
        )
    }

    private var selectedServiceBinding: Binding<String?> {
        Binding(
            get: { storedServiceID.isEmpty ? nil : storedServiceID },
            set: { storedServiceID = $0 ?? "" }
        )
    }

    private func updateSelectionValidity(for projects: [DesktopProjectStatus]) {
        if projects.isEmpty {
            if case .unavailable = model.connectionState {
                storedProjectID = ""
                storedServiceID = ""
            }
            return
        }

        if !storedProjectID.isEmpty, !projects.contains(where: { $0.id == storedProjectID }) {
            storedProjectID = ""
        }

        guard let project = projects.first else {
            storedServiceID = ""
            return
        }
        if !storedServiceID.isEmpty, !project.services.contains(where: { $0.id == storedServiceID }) {
            storedServiceID = ""
        }
    }

    private var connectionImage: String {
        switch model.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        }
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .unavailable: return .red
        case .disconnected: return .secondary
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: DesktopOperationsModel
    @Binding var selectedProjectID: String?
    @Binding var selectedServiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Operations overview")
                        .font(.title2.weight(.semibold))
                    Text(model.daemonHealth?.statusLabel ?? "Health has not been observed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh status", systemImage: "arrow.clockwise") {
                    model.refreshStatus()
                }
                .accessibilityIdentifier(DesktopAccessibilityIdentifier.statusRefresh)
            }
            .padding(.horizontal)

            if let failure = model.lastFailure {
                FailureBanner(failure: failure)
            }

            if DesktopCollectionState(count: model.projects.count) == .populated {
                Table(model.projects, selection: $selectedProjectID) {
                    TableColumn("Project") { project in
                        Label(project.name, systemImage: project.availability.systemImage)
                            .foregroundStyle(projectColor(project.availability))
                            .accessibilityLabel("Project \(project.name), \(project.availability.label)")
                    }
                    TableColumn("Manifest") { project in
                        Text(project.manifestPath)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    TableColumn("Services") { project in
                        Text("\(project.services.count)")
                            .monospacedDigit()
                    }
                    TableColumn("Status") { project in
                        Text(project.availability.label)
                            .foregroundStyle(projectColor(project.availability))
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 120)
            }

            if let project = model.projects.first {
                ServiceTable(project: project, selectedServiceID: $selectedServiceID)
            } else {
                EmptyStateView(
                    title: "No project status yet",
                    message: "Connect to the local daemon to observe its configured project."
                )
            }
        }
        .padding(.vertical)
        .navigationTitle("Overview")
        .accessibilityIdentifier(DesktopAccessibilityIdentifier.overview)
    }
}

private struct ServiceTable: View {
    @EnvironmentObject private var model: DesktopOperationsModel
    let project: DesktopProjectStatus
    @Binding var selectedServiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Services")
                .font(.headline)
                .padding(.horizontal)
            if DesktopCollectionState(count: project.services.count) == .populated {
                Table(project.services, selection: $selectedServiceID) {
                    TableColumn("Service") { service in
                        Label(service.id, systemImage: service.availability.systemImage)
                            .foregroundStyle(projectColor(service.availability))
                            .accessibilityLabel("Service \(service.id), \(service.detailLabel)")
                    }
                    TableColumn("Lifecycle") { service in
                        Text(service.detailLabel)
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Resource") { service in
                        Text(service.resourceIdentifier ?? "Not observed")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    TableColumn("Logs") { service in
                        Button("Open", systemImage: "text.alignleft") {
                            selectedServiceID = service.id
                            model.openLogStream(for: service.id)
                        }
                        .labelStyle(.iconOnly)
                        .help("Open finite logs for \(service.id)")
                        .accessibilityLabel("Open logs for \(service.id)")
                        .accessibilityIdentifier("desktop.logs.open.\(service.id)")
                    }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 120)
            } else {
                EmptyStateView(
                    title: "No service status yet",
                    message: "The daemon has not reported any configured services."
                )
            }
        }
    }
}

private struct EventsView: View {
    @EnvironmentObject private var model: DesktopOperationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Events")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.startEventStream()
                }
                .accessibilityIdentifier(DesktopAccessibilityIdentifier.eventsRefresh)
                if model.isEventStreamRunning {
                    Button("Cancel", systemImage: "xmark") {
                        model.cancelStreams()
                    }
                    .accessibilityIdentifier(DesktopAccessibilityIdentifier.eventsCancel)
                }
            }
            .padding()
            if let failure = model.lastFailure {
                FailureBanner(failure: failure)
                    .padding(.bottom, 8)
            }
            Divider()
            if model.events.isEmpty {
                EmptyStateView(
                    title: "No events loaded",
                    message: "Refresh to read the daemon's bounded local event snapshot."
                )
            } else {
                List(model.events) { event in
                    EventRow(event: event)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Events")
        .accessibilityIdentifier(DesktopAccessibilityIdentifier.events)
    }
}

private struct EventRow: View {
    let event: DesktopEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: eventImage)
                .foregroundStyle(eventColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.type)
                        .font(.headline)
                    Text(event.timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.message)
                Text(event.serviceName ?? event.projectID ?? event.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.severity.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(eventColor)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.severity) event \(event.type): \(event.message)")
    }

    private var eventImage: String {
        switch event.severity {
        case "error": return "xmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private var eventColor: Color {
        switch event.severity {
        case "error": return .red
        case "warning": return .orange
        default: return .secondary
        }
    }
}

private struct LogsView: View {
    @EnvironmentObject private var model: DesktopOperationsModel
    @Binding var selectedServiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Logs")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let selectedServiceID {
                    Button("Open", systemImage: "text.alignleft") {
                        model.openLogStream(for: selectedServiceID)
                    }
                    .accessibilityIdentifier(DesktopAccessibilityIdentifier.selectedLogsOpen)
                }
                if model.isLogStreamRunning {
                    Button("Cancel", systemImage: "xmark") {
                        model.cancelStreams()
                    }
                    .accessibilityIdentifier(DesktopAccessibilityIdentifier.logsCancel)
                }
            }
            .padding()
            if let failure = model.lastFailure {
                FailureBanner(failure: failure)
                    .padding(.bottom, 8)
            }
            Divider()
            if model.logChunks.isEmpty {
                EmptyStateView(
                    title: "No logs loaded",
                    message: "Select a service with an observed resource to read its bounded logs."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.logChunks) { chunk in
                            Text(chunk.text)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(.quaternary.opacity(0.35))
            }
        }
        .navigationTitle("Logs")
        .accessibilityIdentifier(DesktopAccessibilityIdentifier.logs)
    }
}

struct MenuBarHealthView: View {
    @EnvironmentObject private var model: DesktopOperationsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.connectionState.label, systemImage: connectionImage)
                .accessibilityLabel("Hostwright connection: \(model.connectionState.label)")
                .accessibilityIdentifier(DesktopAccessibilityIdentifier.menuConnectionState)
            if let health = model.daemonHealth {
                Text("Daemon: \(health.statusLabel)")
                    .font(.caption)
            }
            Divider()
            Button("Reconnect", systemImage: "arrow.clockwise") {
                model.reconnect()
            }
            .accessibilityIdentifier(DesktopAccessibilityIdentifier.menuReconnect)
            Button("Open Hostwright", systemImage: "macwindow") {
                openWindow(id: "operations")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier(DesktopAccessibilityIdentifier.menuOpenWindow)
            Button("Quit Hostwright", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }

    private var connectionImage: String {
        switch model.connectionState {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        }
    }
}

private struct FailureBanner: View {
    let failure: DesktopControlFailure

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Control request unavailable")
                    .font(.headline)
                Text(failure.message)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Control request unavailable: \(failure.message)")
    }
}

private struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(message)")
    }
}

private func projectColor(_ availability: DesktopServiceAvailability) -> Color {
    switch availability {
    case .healthy: return .green
    case .transitional: return .orange
    case .failed: return .red
    case .absent, .unknown: return .secondary
    }
}
