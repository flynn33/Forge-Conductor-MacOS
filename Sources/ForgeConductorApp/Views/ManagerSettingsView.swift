// ManagerSettingsView.swift
// What: Provides native controls for the persistent manager and its configuration.
// How: Form fields bind to staged AppModel values, while commands call typed manager
// operations and render returned health/doctor information.
// Why: A single settings module replaces ad-hoc process and configuration mutations.

import SwiftUI
import ForgeConductorCore

/// Full management console parity with classic `/control` surface.
struct ManagerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var doctorJSON = ""
    @State private var doctorOK: Bool?

    var body: some View {
        Form {
            Section("Authorized project folders") {
                Text(
                    "Forge Conductor denies project filesystem access until a folder is explicitly authorized. Choose folders here, then select Save settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if model.setAllowedRoots.isEmpty {
                    Text("No project folders authorized")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-allowed-roots-empty")
                } else {
                    ForEach(Array(model.setAllowedRoots.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(path)
                                .accessibilityLabel(path)
                                .accessibilityIdentifier("settings-allowed-root-path-\(index)")
                            Spacer(minLength: 8)
                            Button {
                                model.removeAllowedRoot(path)
                            } label: {
                                Label("Remove \(path)", systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove authorized project folder \(path)")
                            .accessibilityIdentifier("settings-allowed-root-remove-\(index)")
                        }
                    }
                }

                Button {
                    model.chooseAllowedRoot()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .accessibilityLabel("Add authorized project folder")
                .accessibilityIdentifier("settings-allowed-root-add")

                if let message = model.allowedRootsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-allowed-roots-message")
                }
            }

            Section {
                LabeledContent("State", value: model.serviceState)
                LabeledContent("Active", value: model.serviceActive ? "yes" : "no")
                if let msg = model.managerMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("manager-message")
                }
                HStack(spacing: 10) {
                    Button("Start") { model.managerStart() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Stop") { model.managerStop() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    Button("Restart") { model.managerRestart() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Service")
                    .accessibilityIdentifier("detail-manager")
            }

            Section("Runtime") {
                LabeledContent("App version", value: model.version)
                LabeledContent("Manager version", value: model.managerRuntimeVersion)
                if let notice = model.managerVersionNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("manager-version-mismatch")
                }
                LabeledContent("Home", value: model.homePath)
                LabeledContent("Product", value: ForgeApp.productName)
                if let updated = model.updated {
                    LabeledContent("Host telemetry", value: model.telemetryModeLabel)
                    LabeledContent("Last host sample", value: updated.formatted())
                    LabeledContent("Dashboard HTML poll", value: "\(model.setRefresh)s (not host telemetry)")
                }
            }

            Section("Settings") {
                TextField("Dashboard host", text: $model.setHost)
                TextField("Dashboard port", value: $model.setPort, format: .number)
                TextField("UI refresh (sec)", value: $model.setRefresh, format: .number)
                TextField("Watchdog (sec)", value: $model.setWatchdog, format: .number)
                TextField("Session idle TTL (sec)", value: $model.setIdleTTL, format: .number)
                Toggle("Auto-restart HTTP if it drops", isOn: $model.setAutoRestart)
                HStack(spacing: 10) {
                    Button("Reload from disk") { model.loadSettingsFromConfig() }
                        .accessibilityIdentifier("settings-reload")
                    Button("Save settings") { model.saveSettings() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("settings-save")
                }
                .padding(.vertical, 2)
            }

            Section("Project shell") {
                Toggle("Enable project shell tools", isOn: $model.setShellEnabled)
                    .accessibilityIdentifier("settings-shell-enabled")
                TextField("Default timeout (sec)", value: $model.setShellTimeout, format: .number)
                Text(
                    model.setShellEnabled
                        ? "Authorized agent sessions may run project-root commands. Canonical path checks and the 120-second shell_exec ceiling still apply."
                        : "Project shell tools are explicitly disabled. Filesystem and other independently authorized tools are unchanged."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("shell-effective-policy")

                runtimeRow("zsh", id: "zsh", path: model.shellRuntimeCapabilities.zsh)
                runtimeRow("Bash", id: "bash", path: model.shellRuntimeCapabilities.bash)
                runtimeRow("Python", id: "python", path: model.shellRuntimeCapabilities.python)
                runtimeRow("PowerShell", id: "powershell", path: model.shellRuntimeCapabilities.powershell)

                LabeledContent("Policy origin", value: model.shellPolicyOrigin)
                LabeledContent(
                    "Migration",
                    value: model.shellMigrationReceiptValid
                        ? "\(model.shellMigrationState) · receipt verified"
                        : model.shellMigrationState
                )
                .accessibilityIdentifier("shell-policy-migration-status")
            }

            Section("Protected filesystem service") {
                LabeledContent(
                    "State",
                    value: model.secureFilesystemServiceStatusLabel
                )
                .accessibilityIdentifier("settings-filesystem-service-status")

                Text(
                    "Delete and move operations fail closed unless the separately signed service is enabled and the requested operation is qualified. Shell tools remain nonprivileged and are controlled independently above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let message = model.secureFilesystemServiceMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-filesystem-service-message")
                }

                HStack(spacing: 10) {
                    Button("Enable") { model.enableSecureFilesystemService() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.secureFilesystemServiceStatus == .enabled
                                || model.isUpdatingSecureFilesystemService
                        )
                        .accessibilityIdentifier("settings-filesystem-service-enable")
                    Button("Update / Reinstall") {
                        model.reinstallSecureFilesystemService()
                    }
                    .disabled(
                        model.secureFilesystemServiceStatus == .notFound
                            || model.isUpdatingSecureFilesystemService
                    )
                    .accessibilityIdentifier("settings-filesystem-service-reinstall")
                    Button("Disable") { model.disableSecureFilesystemService() }
                        .disabled(
                            model.secureFilesystemServiceStatus == .notRegistered
                                || model.secureFilesystemServiceStatus == .notFound
                        )
                        .accessibilityIdentifier("settings-filesystem-service-disable")
                    Button("Open System Settings") {
                        model.openSecureFilesystemApprovalSettings()
                    }
                    .accessibilityIdentifier("settings-filesystem-service-approval")
                    Button("Refresh") { model.refreshSecureFilesystemServiceStatus() }
                        .accessibilityIdentifier("settings-filesystem-service-refresh")
                    if model.isUpdatingSecureFilesystemService {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Updating protected filesystem service")
                    }
                }
                .padding(.vertical, 2)
            }

            Section("Maintenance") {
                Toggle("Auto-refresh telemetry", isOn: $model.autoRefresh)
                Button("Refresh telemetry now") { model.refresh(force: true) }
                Button("Prune stale presence") { model.prunePresence() }
                Button("Prune idle sessions") { model.pruneSessions() }
                Button("Run doctor") {
                    if let d = model.runDoctor() {
                        doctorOK = d.ok
                        let lines = d.checks.map { c in
                            "\(c.ok ? "OK" : "FAIL")  \(c.name): \(c.detail)"
                        }
                        doctorJSON = ([
                            "ok=\(d.ok)  version=\(d.version)",
                            "home=\(d.home)",
                            "binary=\(d.binaryInstalled ? "yes" : "no")  \(d.binaryPath)",
                            "telemetry=\(d.telemetry.runtime)",
                            "",
                        ] + lines).joined(separator: "\n")
                    } else {
                        doctorJSON = "doctor failed"
                        doctorOK = false
                    }
                }
            }

            if !doctorJSON.isEmpty {
                Section("Doctor \(doctorOK == true ? "OK" : "ISSUES")") {
                    ScrollView {
                        Text(doctorJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160)
                }
            }

            Section("Notes") {
                Text("Start/Stop toggles operational service_active. Restart rebinds the HTTP control plane. Product path: Deploy to LM Studio on the LM Studio MCP tab; configuration, host reload, and both connection checks are automatic. Telemetry is a continuous native stream (~30 Hz host sampling + SSE /api/stream), not multi-second snapshots. Diagnostics export is on the Diagnostics tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .onAppear {
            model.loadSettingsFromConfig()
            model.refreshSecureFilesystemServiceStatus()
        }
    }

    @ViewBuilder
    private func runtimeRow(_ label: String, id: String, path: String?) -> some View {
        LabeledContent(label, value: path ?? "Not installed")
            .foregroundStyle(path == nil ? .secondary : .primary)
            .accessibilityIdentifier("runtime-capability-\(id)")
    }
}
