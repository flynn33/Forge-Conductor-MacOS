// ManagerSettingsView.swift
// What: Provides native controls for the persistent manager and its configuration.
// How: Form fields bind to staged AppModel values, while commands call typed manager
// operations and render returned health/doctor information.
// Why: A single settings module replaces ad-hoc process and configuration mutations.

import ForgeConductorCore
import SwiftUI

/// Full management console parity with classic `/control` surface.
struct ManagerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var doctorJSON = ""
    @State private var doctorOK: Bool?
    @State private var doctorNeedsPluginRepair = false
    @State private var selectedSection: ManagementSection

    init(initialSection: ManagementSection = .folders) {
        _selectedSection = State(initialValue: initialSection)
    }

    enum ManagementSection: String, CaseIterable, Identifiable {
        case workbench, folders, service, runtime, settings, shell, filesystem, maintenance, doctor
        var id: String { rawValue }
        var title: String {
            switch self {
            case .workbench: return "Workbench"
            case .folders: return "Authorized Folders"
            case .service: return "Service"
            case .runtime: return "Runtime"
            case .settings: return "Settings"
            case .shell: return "Project Shell"
            case .filesystem: return "Protected Filesystem"
            case .maintenance: return "Maintenance"
            case .doctor: return "Doctor"
            }
        }
        var symbol: String {
            switch self {
            case .workbench: return "sidebar.left"
            case .folders: return "folder.badge.gearshape"
            case .service: return "power"
            case .runtime: return "cpu"
            case .settings: return "slider.horizontal.3"
            case .shell: return "terminal"
            case .filesystem: return "lock.shield"
            case .maintenance: return "wrench.and.screwdriver"
            case .doctor: return "stethoscope"
            }
        }
        var editsSettings: Bool { self == .folders || self == .settings || self == .shell }
    }

    var body: some View {
        HStack(spacing: 0) {
            sectionNavigation
            Rectangle().fill(GraphitePalette.separator).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                GraphitePageHeader(
                    title: selectedSection.title,
                    subtitle: selectedSection == .workbench
                        ? "Appearance and interface preferences" : "Manager configuration and native services"
                )
                    .accessibilityIdentifier("detail-manager")
                    .padding(20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !model.hasLoadedInitialSettings {
                            GraphitePanel(title: "Startup") { startupContent }
                        }
                        if let notice = model.managerVersionNotice, selectedSection != .runtime {
                            Label(notice, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(GraphitePalette.warning)
                                .accessibilityIdentifier("manager-version-mismatch")
                        }
                        if model.secureFilesystemServiceLifecycleState.blocksLifecycleMutation,
                            selectedSection != .filesystem
                        {
                            Button {
                                selectedSection = .filesystem
                            } label: {
                                Label(
                                    "Protected filesystem has a pending lifecycle action",
                                    systemImage: "lock.trianglebadge.exclamationmark"
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(GraphiteButtonStyle(kind: .secondary))
                            .accessibilityIdentifier("manager-filesystem-attention")
                        }
                        selectedContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                if selectedSection.editsSettings {
                    settingsActions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(GraphitePalette.canvas)
        .textFieldStyle(GraphiteFieldStyle())
        .buttonStyle(GraphiteButtonStyle(kind: .secondary))
        .onAppear {
            if !model.hasLoadedInitialSettings {
                model.loadSettingsFromConfig()
            }
            model.refreshSecureFilesystemServiceStatus()
        }
    }

    private var sectionNavigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MANAGER")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(GraphitePalette.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 20)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(ManagementSection.allCases) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                                .foregroundStyle(
                                    selectedSection == section
                                        ? GraphitePalette.textPrimary : GraphitePalette.textSecondary
                                )
                                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background {
                                    if selectedSection == section {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        GraphitePalette.selectionTop, GraphitePalette.selectionBottom,
                                                    ], startPoint: .top, endPoint: .bottom))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                        .accessibilityIdentifier("manager-section-\(section.rawValue)")
                    }
                }
                .padding(.horizontal, 8)
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(model.serviceActive ? "Service active" : "Service inactive", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.serviceActive ? GraphitePalette.success : GraphitePalette.textSecondary)
                Text(model.serviceState)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textMuted)
                Text("v\(model.version)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(GraphitePalette.textMuted)
                Text(model.telemetryModeLabel)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textMuted)
                if let updated = model.updated {
                    Text("Host sample \(updated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(GraphitePalette.textMuted)
                }
            }
            .padding(14)
        }
        .frame(width: 184)
        .background(GraphitePalette.sidebar)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .workbench: WorkbenchSettingsView()
        case .folders: GraphitePanel { foldersContent }
        case .service:
            GraphitePanel { serviceContent }
            GraphitePanel(title: "Service behavior") { notesContent }
        case .runtime: GraphitePanel { runtimeContent }
        case .settings: GraphitePanel { settingsContent }.disabled(!model.hasLoadedInitialSettings)
        case .shell: GraphitePanel { shellContent }
        case .filesystem: GraphitePanel { filesystemContent }
        case .maintenance: GraphitePanel { maintenanceContent }
        case .doctor:
            GraphitePanel(title: doctorJSON.isEmpty ? "Health checks" : "Doctor \(doctorOK == true ? "OK" : "ISSUES")")
            {
                Button("Run doctor") { runDoctor() }
                    .buttonStyle(GraphiteButtonStyle(kind: .primary))
                if doctorJSON.isEmpty {
                    Text("Run doctor to inspect the current native service, runtime and LM Studio integration health.")
                        .font(.callout)
                        .foregroundStyle(GraphitePalette.textSecondary)
                } else {
                    doctorContent
                }
            }
        }
    }

    private var settingsActions: some View {
        HStack(spacing: 10) {
            Text("Changes are staged until saved.")
                .font(.callout)
                .foregroundStyle(GraphitePalette.textSecondary)
            Spacer(minLength: 8)
            Button("Reload from disk") { model.loadSettingsFromConfig() }
                .accessibilityIdentifier("settings-reload")
            Button("Save settings") { model.saveSettings() }
                .buttonStyle(GraphiteButtonStyle(kind: .primary))
                .accessibilityIdentifier("settings-save")
        }
        .padding(16)
        .background(GraphitePalette.panelRaised)
        .overlay(alignment: .top) { Rectangle().fill(GraphitePalette.separator).frame(height: 1) }
        .disabled(!model.hasLoadedInitialSettings)
    }

    @ViewBuilder
    private var startupContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            if model.isBootstrapping {
                ProgressView("Loading saved settings…")
            } else {
                Text(model.lastError ?? "Settings have not loaded.")
                    .foregroundStyle(GraphitePalette.textSecondary)
                Button("Retry startup") { model.bootstrap() }
                    .accessibilityIdentifier("settings-retry-startup")
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var foldersContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(
                "These folders establish registered project identities and the default working context. They do not restrict native filesystem, Git, or shell access. Choose folders here, then select Save settings."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)

            if model.setAllowedRoots.isEmpty {
                Text("No project folders selected")
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("settings-allowed-roots-empty")
            } else {
                ForEach(Array(model.setAllowedRoots.enumerated()), id: \.element) { index, path in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .accessibilityHidden(true)
                        Text(path)
                            .font(.system(.body, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(path)
                            .accessibilityIdentifier("settings-allowed-root-path-\(index)")
                        Spacer(minLength: 8)
                        Button {
                            model.removeAllowedRoot(path)
                        } label: {
                            Label("Remove \(path)", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.hasLoadedInitialSettings)
                        .accessibilityLabel("Remove selected project folder \(path)")
                        .accessibilityIdentifier("settings-allowed-root-remove-\(index)")
                    }
                }
            }

            Button {
                model.chooseAllowedRoot()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .accessibilityLabel("Add selected project folder")
            .accessibilityIdentifier("settings-allowed-root-add")
            .disabled(!model.hasLoadedInitialSettings)

            if let message = model.allowedRootsMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("settings-allowed-roots-message")
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var serviceContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            LabeledContent("State", value: model.serviceState)
                .labeledContentStyle(ManagerValueRowStyle())
            LabeledContent("Active", value: model.serviceActive ? "yes" : "no")
                .labeledContentStyle(ManagerValueRowStyle())
            if let msg = model.managerMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("manager-message")
            }
            HStack(spacing: 10) {
                Button("Start") { model.managerStart() }
                    .buttonStyle(GraphiteButtonStyle(kind: .primary))

                Button("Stop") { model.managerStop() }
                    .buttonStyle(GraphiteButtonStyle(kind: .destructive))

                Button("Restart") { model.managerRestart() }
                    .buttonStyle(GraphiteButtonStyle(kind: .secondary))
            }
            .padding(.vertical, 2)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runtimeContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            LabeledContent("App version", value: model.version)
                .labeledContentStyle(ManagerValueRowStyle())
            LabeledContent("Manager version", value: model.managerRuntimeVersion)
                .labeledContentStyle(ManagerValueRowStyle())
            if let notice = model.managerVersionNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.warning)
                    .accessibilityIdentifier("manager-version-mismatch")
            }
            LabeledContent("Home", value: model.homePath)
                .labeledContentStyle(ManagerValueRowStyle())
            LabeledContent("Product", value: ForgeApp.productName)
                .labeledContentStyle(ManagerValueRowStyle())
            if let updated = model.updated {
                LabeledContent("Host telemetry", value: model.telemetryModeLabel)
                    .labeledContentStyle(ManagerValueRowStyle())
                LabeledContent("Last host sample", value: updated.formatted())
                    .labeledContentStyle(ManagerValueRowStyle())
                LabeledContent("Dashboard HTML poll", value: "\(model.setRefresh)s (not host telemetry)")
                    .labeledContentStyle(ManagerValueRowStyle())
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard host").font(.callout.weight(.medium))
                TextField("Dashboard host", text: $model.setHost)
            }
            .frame(maxWidth: 480, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard port").font(.callout.weight(.medium))
                TextField("Dashboard port", value: $model.setPort, format: .number.grouping(.never))
            }
            .frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("UI refresh (sec)").font(.callout.weight(.medium))
                TextField("UI refresh (sec)", value: $model.setRefresh, format: .number.grouping(.never))
            }
            .frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Watchdog (sec)").font(.callout.weight(.medium))
                TextField("Watchdog (sec)", value: $model.setWatchdog, format: .number.grouping(.never))
            }
            .frame(width: 200, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Session idle TTL (sec)").font(.callout.weight(.medium))
                TextField("Session idle TTL (sec)", value: $model.setIdleTTL, format: .number.grouping(.never))
            }
            .frame(width: 200, alignment: .leading)
            Toggle("Auto-restart HTTP if it drops", isOn: $model.setAutoRestart)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var shellContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            Toggle("Enable project shell tools", isOn: $model.setShellEnabled)
                .accessibilityIdentifier("settings-shell-enabled")
                .disabled(!model.hasLoadedInitialSettings)
            VStack(alignment: .leading, spacing: 6) {
                Text("Default timeout (sec)").font(.callout.weight(.medium))
                TextField("Default timeout (sec)", value: $model.setShellTimeout, format: .number.grouping(.never))
                    .disabled(!model.hasLoadedInitialSettings)
            }
            .frame(width: 200, alignment: .leading)
            Text(
                model.setShellEnabled
                    ? "Authorized agent sessions may run native host commands. Project context supplies the default working directory; macOS permissions, canonicalization, and the 120-second shell_exec ceiling still apply."
                    : "Project shell tools are explicitly disabled. Filesystem and other independently authorized tools are unchanged."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)
            .accessibilityIdentifier("shell-effective-policy")

            runtimeRow("zsh", id: "zsh", path: model.shellRuntimeCapabilities.zsh)
            runtimeRow("Bash", id: "bash", path: model.shellRuntimeCapabilities.bash)
            runtimeRow("Python", id: "python", path: model.shellRuntimeCapabilities.python)
            runtimeRow("PowerShell", id: "powershell", path: model.shellRuntimeCapabilities.powershell)

            LabeledContent("Policy origin", value: model.shellPolicyOrigin)
                .labeledContentStyle(ManagerValueRowStyle())
            LabeledContent(
                "Migration",
                value: model.shellMigrationReceiptValid
                    ? "\(model.shellMigrationState) · receipt verified"
                    : model.shellMigrationState
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("shell-policy-migration-status")

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var filesystemContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            LabeledContent(
                "Registration",
                value: model.secureFilesystemServiceStatusLabel
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("settings-filesystem-service-status")

            LabeledContent(
                "Operational health",
                value: model.secureFilesystemOperationalStatusLabel
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("settings-filesystem-service-operational-health")

            LabeledContent(
                "Unresolved recovery debt",
                value: model.secureFilesystemRecoveryDebtLabel
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("settings-filesystem-recovery-debt")

            LabeledContent(
                "Operation",
                value: model.secureFilesystemServiceOperationStatusLabel
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("settings-filesystem-operation-status")

            LabeledContent(
                "Lifecycle fence",
                value: model.secureFilesystemServiceLifecycleStatusLabel
            )
            .labeledContentStyle(ManagerValueRowStyle())
            .accessibilityIdentifier("settings-filesystem-lifecycle-fence-status")

            if model.secureFilesystemServiceLifecycleState.blocksLifecycleMutation {
                Label(
                    "Service lifecycle changes are blocked until the pending macOS lifecycle action is resolved.",
                    systemImage: "lock.trianglebadge.exclamationmark"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(GraphitePalette.warning)
                .accessibilityIdentifier("settings-filesystem-lifecycle-fence-warning")
            }

            Text(
                "Protected regular-file, symbolic-link, empty-directory, move, and bounded recursive-delete operations inside a registered project may use the separately signed service. Native paths outside it use the bounded local implementation. Move refuses replacement; recursive delete commits one recoverable leaf or empty-directory transaction at a time. Shell tools remain nonprivileged and are controlled independently above."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)

            Text(
                "Reconcile verifies fixed-slot receipts and releases only terminal or exact-identity restored entries. Restoring retained quarantine entries to their original path is not supported."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)
            .accessibilityIdentifier("settings-filesystem-recovery-policy")

            if model.secureFilesystemOperationalHealth.hasExhaustedLedger {
                Label(
                    "A recovery ledger is full. New protected mutations remain blocked until verified debt is released.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(GraphitePalette.warning)
                .accessibilityIdentifier("settings-filesystem-recovery-exhausted")
            }

            if let message = model.secureFilesystemServiceMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .accessibilityIdentifier("settings-filesystem-service-message")
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                alignment: .leading,
                spacing: 8
            ) {
                Button("Enable") { model.enableSecureFilesystemService() }
                    .buttonStyle(GraphiteButtonStyle(kind: .primary))
                    .frame(maxWidth: .infinity)
                    .disabled(!model.secureFilesystemSettingsControlAvailability.enable)
                    .accessibilityIdentifier("settings-filesystem-service-enable")
                Button("Update / Reinstall") {
                    model.reinstallSecureFilesystemService()
                }
                .frame(maxWidth: .infinity)
                .disabled(!model.secureFilesystemSettingsControlAvailability.update)
                .accessibilityIdentifier("settings-filesystem-service-reinstall")
                Button("Disable") { model.disableSecureFilesystemService() }
                    .frame(maxWidth: .infinity)
                    .disabled(!model.secureFilesystemSettingsControlAvailability.disable)
                    .accessibilityIdentifier("settings-filesystem-service-disable")
                Button("Open System Settings") {
                    model.openSecureFilesystemApprovalSettings()
                }
                .frame(maxWidth: .infinity)
                .disabled(!model.secureFilesystemSettingsControlAvailability.approval)
                .accessibilityIdentifier("settings-filesystem-service-approval")
                Button("Refresh") { model.refreshSecureFilesystemServiceStatus() }
                    .frame(maxWidth: .infinity)
                    .disabled(!model.secureFilesystemSettingsControlAvailability.refresh)
                    .accessibilityIdentifier("settings-filesystem-service-refresh")
                Button("Reconcile recovery") {
                    model.reconcileSecureFilesystemRecovery()
                }
                .frame(maxWidth: .infinity)
                .disabled(!model.secureFilesystemSettingsControlAvailability.reconcile)
                .accessibilityIdentifier("settings-filesystem-recovery-reconcile")
                if model.secureFilesystemServiceLifecycleState.canRetryResolution {
                    Button(model.secureFilesystemServiceLifecycleRecoveryActionLabel) {
                        model.recoverSecureFilesystemServiceLifecycle()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(
                        !model.secureFilesystemSettingsControlAvailability.lifecycleRecovery
                    )
                    .accessibilityIdentifier(
                        "settings-filesystem-lifecycle-recovery"
                    )
                }
                if model.isSecureFilesystemServiceOperationActive {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(model.secureFilesystemServiceOperationStatusLabel)
                        .accessibilityIdentifier("settings-filesystem-operation-progress")
                }
            }
            .padding(.vertical, 2)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var maintenanceContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            Toggle("Auto-refresh telemetry", isOn: $model.autoRefresh)
            Button("Refresh telemetry now") { model.refresh(force: true) }
            Button("Prune stale presence") { model.prunePresence() }
            Button("Prune idle sessions") { model.pruneSessions() }
            Button("Run doctor") {
                runDoctor()
                selectedSection = .doctor
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var doctorContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(doctorJSON)
                .font(.system(.caption, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            if doctorNeedsPluginRepair {
                Button("Deploy current build to LM Studio") {
                    model.deployToLMStudio()
                }
                .disabled(model.isInstallingPlugin)
                .accessibilityIdentifier("doctor-deploy-current-build")
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(
                "Start/Stop toggles operational service_active. Restart rebinds the HTTP control plane. Product path: Deploy to LM Studio on the LM Studio MCP tab; configuration, host reload, and both connection checks are automatic. Telemetry is a continuous native stream (~30 Hz host sampling + SSE /api/stream), not multi-second snapshots. Diagnostics export is on the Diagnostics tab."
            )
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(GraphitePalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runDoctor() {

        if let d = model.runDoctor() {
            let healthy = d.ok && d.checks.allSatisfy(\.ok)
            doctorOK = healthy
            doctorNeedsPluginRepair = d.checks.contains {
                $0.name.hasPrefix("lm_studio_") && !$0.ok
            }
            let lines = d.checks.map { c in
                "\(c.ok ? "OK" : "FAIL")  \(c.name): \(c.detail)"
            }
            doctorJSON =
                ([
                    "state=\(healthy ? "healthy" : "attention")  version=\(d.version)  build=\(d.buildVersion)",
                    "home=\(d.home)",
                    "binary=\(d.binaryInstalled ? "yes" : "no")  \(d.binaryPath)",
                    "telemetry=\(d.telemetry.runtime)",
                    "",
                ] + lines).joined(separator: "\n")
        } else {
            doctorJSON = "doctor failed"
            doctorOK = false
            doctorNeedsPluginRepair = false
        }

    }
    @ViewBuilder
    private func runtimeRow(_ label: String, id: String, path: String?) -> some View {
        LabeledContent(label, value: path ?? "Not installed")
            .labeledContentStyle(ManagerValueRowStyle())
            .foregroundStyle(path == nil ? GraphitePalette.textSecondary : GraphitePalette.textPrimary)
            .accessibilityIdentifier("runtime-capability-\(id)")
    }
}

@MainActor
private struct ManagerValueRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .foregroundStyle(GraphitePalette.textSecondary)
                .frame(width: 168, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
