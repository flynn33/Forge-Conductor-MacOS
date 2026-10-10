// RigDashboardView.swift
// What: Builds the real-time host and orchestration instrument panel.
// How: AppModel telemetry changes project directly into modular demand-driven Metal
// gauges, charts, process panels, MCP cards, and event summaries.
// Why: The rig provides one coherent operational view without slowing Core sampling.

import SwiftUI
import ForgeConductorCore

struct RigProviderIndicatorState: Equatable {
    let title: String
    let state: String
    let detail: String
    let fraction: Double
    let tone: TelemetryStatusTone

    static func compose(
        runtime: RigOperationalSnapshot,
        lmStudioAlive: Bool,
        lmStudioCPU: Double
    ) -> Self {
        let provider = runtime.selectedProvider
        if provider.executionMode == .desktopHost {
            if provider.isReady {
                return Self(
                    title: provider.displayName.uppercased(),
                    state: "HOST READY",
                    detail: "Host-managed execution · model selected in host",
                    fraction: 1,
                    tone: .healthy
                )
            }
            let state: String
            let tone: TelemetryStatusTone
            switch provider.readinessState {
            case "automatically_preparing":
                state = "PREPARING"
                tone = .informational
            case "waiting_dependency", "failed":
                state = "ATTENTION"
                tone = .caution
            default:
                state = "CHECK"
                tone = .unavailable
            }
            return Self(
                title: provider.displayName.uppercased(),
                state: state,
                detail: provider.detail,
                fraction: 0,
                tone: tone
            )
        }

        if provider.executionMode == .unavailable,
           provider.integrationEvidenceAvailable {
            return Self(
                title: "PROVIDER",
                state: "NOT SELECTED",
                detail: provider.detail,
                fraction: 0,
                tone: .caution
            )
        }

        let providerReady = ["reachable", "contract_valid"].contains(runtime.providerHealth)
        if providerReady {
            return Self(
                title: "LM STUDIO",
                state: "HEADLESS",
                detail: runtime.providerModel.map { "\($0) · Chat separate" }
                    ?? "Provider API · Chat separate",
                fraction: min(max(lmStudioCPU / 100, 0), 1),
                tone: .healthy
            )
        }
        if lmStudioAlive {
            return Self(
                title: "LM STUDIO",
                state: "RUNNING",
                detail: "Process detected · API unverified",
                fraction: min(max(lmStudioCPU / 100, 0), 1),
                tone: .caution
            )
        }
        return Self(
            title: "LM STUDIO",
            state: "OFFLINE",
            detail: "Provider unavailable",
            fraction: 0,
            tone: .failure
        )
    }
}

/// Single-screen FORGE RIG board — full panel parity; **all gauges are Metal**.
/// Display updates continuously from the realtime metrics engine (not a 2s snapshot).
struct RigDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Telemetry drives measurements; Compute owns its bounded visible-only FX clock.
        NativeWorkspaceView(viewID: "rig", descriptors: NativeWorkspaceCatalog.dashboard,
                            defaultContent: { rigContent }, panelContent: workspacePanel,
                            activityChanged: { visible in
                                if visible { model.startRigOperationalMonitoring() }
                                else { model.stopRigOperationalMonitoring() }
                            })
            .onDisappear { model.stopRigOperationalMonitoring() }
    }

    private func workspacePanel(_ id: String, _ visible: Bool) -> AnyView {
        switch id {
        case "rig-header": AnyView(headerPills)
        case "rig-current-project": AnyView(currentProjectPanel)
        case "rig-system-strip": AnyView(sysStrip)
        case "rig-load-trace": AnyView(loadTracePanel)
        case "rig-operational-indicators": AnyView(operationalIndicatorsPanel)
        case "rig-compute-cores-panel": AnyView(computeCoresPanel)
        case "rig-storage-panel": AnyView(storagePanel)
        case "rig-orchestration-panel": AnyView(orchestrationPanel)
        case "rig-managed-activity-feed": AnyView(managedActivityFeedPanel)
        case "rig-mcp-servers-panel": AnyView(mcpServersPanel)
        case "rig-mcp-tools-panel": AnyView(mcpToolsPanel)
        case "rig-sub-agents-panel": AnyView(agentsPanel)
        case "rig-hot-processes-panel": AnyView(processesPanel)
        case "rig-live-stream-panel": AnyView(liveFeedPanel)
        default: AnyView(EmptyView())
        }
    }

    private var rigContent: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerPills
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            currentProjectPanel
                            sysStrip
                            loadTracePanel
                        }
                        .frame(minWidth: 580, maxWidth: .infinity)
                        operationalIndicatorsPanel.frame(width: min(560, max(300, (geometry.size.width - 40) * 0.34)))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        currentProjectPanel
                        sysStrip
                        loadTracePanel
                        operationalIndicatorsPanel
                    }
                }

                instrumentationPanels

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        mcpServersPanel
                            .fixedSize(horizontal: false, vertical: true)
                        mcpToolsPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) {
                        agentsPanel
                            .fixedSize(horizontal: false, vertical: true)
                        processesPanel
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .fixedSize(horizontal: false, vertical: true)

                liveFeedPanel
            }
            .padding(20)
        }
        .background(GraphitePalette.canvas)
        }
    }

    private var currentProjectPanel: some View {
        let runtime = model.rigOperationalSnapshot
        let progress = projectProgressCard
        return GraphitePanel(title: "Current Project") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(GraphitePalette.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(runtime.projectName ?? "No selected project")
                        .font(.system(size: 17, weight: .semibold))
                        .textSelection(.enabled)
                    Text(progress.detail)
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let package = runtime.currentPackageName {
                        Text(package).font(.system(size: 12))
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 12)
                Text(progress.state)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(progress.tone.color)
                    .padding(6)
                    .background(progress.tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }
            if runtime.projectTotalSteps + runtime.projectTotalPackages > 0 {
                MetalBarGauge(fraction: progress.fraction, tint: GraphitePalette.primaryFill)
                    .frame(height: 8)
                    .clipShape(Capsule())
                    .accessibilityLabel(progress.detail)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-current-project")
    }

    private var loadTracePanel: some View {
        GraphitePanel(title: "System Load History") {
            HStack(spacing: 16) {
                chartLegend("CPU", color: GraphitePalette.chartCPU)
                chartLegend("RAM", color: GraphitePalette.chartRAM)
                chartLegend("GPU", color: GraphitePalette.chartGPU)
                Spacer(minLength: 0)
                Text(model.telemetryModeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(GraphitePalette.textMuted)
            }
            HStack(spacing: 8) {
                VStack(alignment: .trailing) {
                    Text("100%")
                    Spacer()
                    Text("50%")
                    Spacer()
                    Text("0%")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(GraphitePalette.textMuted)
                .frame(width: 34)
                MultiSeriesLoadChart(cpu: model.historyCPU, ram: model.historyRAM, gpu: model.historyGPU)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func chartLegend(_ label: String, color: Color) -> some View {
        Label {
            Text(label).font(.system(size: 11))
        } icon: {
            Circle().fill(color).frame(width: 6, height: 6)
        }
    }

    private var operationalIndicatorsPanel: some View {
        panel("ORCHESTRATION STATUS", meta: "5 s bounded refresh") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(operationalIndicatorCards.enumerated()), id: \.offset) { _, card in
                    orchestrationCard(card, compact: true)
                }
            }
        }
        .frame(minHeight: 208)
        .accessibilityIdentifier("rig-operational-indicators")
    }

    private var operationalIndicatorCards: [OrchestrationCardState] {
        let runtime = model.rigOperationalSnapshot
        let lmStudioAlive = model.orchestration?.lmStudioAlive == true
        let lmStudioCPU = model.hotProcesses
            .filter {
                let name = $0.name.lowercased()
                return name.contains("lm studio") || name.contains("llama")
            }
            .reduce(0) { $0 + $1.cpuPercent }
        let providerIndicator = RigProviderIndicatorState.compose(
            runtime: runtime,
            lmStudioAlive: lmStudioAlive,
            lmStudioCPU: lmStudioCPU
        )

        let autonomyState: String
        let autonomyTone: TelemetryStatusTone
        if runtime.autonomyStarted == true {
            autonomyState = "RUNNING"
            autonomyTone = runtime.autonomyDeferredCount > 0 ? .caution : .healthy
        } else if runtime.autonomyStarted == false {
            autonomyState = "STOPPED"
            autonomyTone = .failure
        } else {
            autonomyState = "CHECK"
            autonomyTone = .unavailable
        }

        let continuityState: String
        let continuityTone: TelemetryStatusTone
        let continuityDetail: String
        if let interactive = runtime.interactiveContinuity,
           interactive.state == "countdown" {
            continuityState = "NEXT CHAT \(interactive.countdownSeconds)S"
            continuityTone = .informational
            continuityDetail = interactive.projectID.map {
                "Project \($0) · automatic LM Studio rollover"
            } ?? "Automatic LM Studio rollover"
        } else if let interactive = runtime.interactiveContinuity,
                  interactive.state == "creating_successor" {
            continuityState = "CREATING CHAT"
            continuityTone = .informational
            continuityDetail = interactive.detail
        } else if let interactive = runtime.interactiveContinuity,
                  interactive.state == "attention" {
            continuityState = "ATTENTION"
            continuityTone = .caution
            continuityDetail = interactive.detail
        } else if runtime.continuityBlockedCount > 0 {
            continuityState = "ATTENTION"
            continuityTone = .caution
            continuityDetail = "Continuity requires attention"
        } else if runtime.continuityAutomaticCount > 0 {
            continuityState = runtime.continuityActiveCount > 0 ? "ACTIVE" : "MONITORING"
            continuityTone = .healthy
            continuityDetail = "\(runtime.continuityAutomaticCount) monitored · \(runtime.continuityActiveCount) rollover"
        } else if runtime.autonomyStarted == true {
            continuityState = "READY"
            continuityTone = .informational
            continuityDetail = "Automatic LM Studio continuity ready"
        } else {
            continuityState = "CHECK"
            continuityTone = .unavailable
            continuityDetail = "Automatic LM Studio continuity status unavailable"
        }

        let runeState: String
        let runeTone: TelemetryStatusTone
        switch runtime.runeForgeState {
        case .running:
            runeState = runtime.runeForgeSelectedSourceCount > 0 ? "OBSERVING" : "READY"
            runeTone = .healthy
        case .degraded:
            runeState = "DEGRADED"
            runeTone = .caution
        case .starting:
            runeState = "STARTING"
            runeTone = .informational
        case .stopped, .stopping:
            runeState = "STOPPED"
            runeTone = .failure
        case nil:
            runeState = "CHECK"
            runeTone = .unavailable
        }
        let runeLoad = runtime.runeForgeActiveSourceCount > 0
            ? Double(runtime.runeForgeIndexedSourceCount) / Double(runtime.runeForgeActiveSourceCount)
            : 0

        return [
            OrchestrationCardState(
                title: providerIndicator.title,
                state: providerIndicator.state,
                detail: providerIndicator.detail,
                fraction: providerIndicator.fraction,
                tone: providerIndicator.tone
            ),
            OrchestrationCardState(
                title: "BACKGROUND SERVICES", state: autonomyState,
                detail: "Forge automation and recovery workers",
                fraction: min(Double(runtime.autonomyActiveCount) / 4, 1), tone: autonomyTone
            ),
            OrchestrationCardState(
                title: "CONTINUITY", state: continuityState,
                detail: continuityDetail,
                fraction: runtime.continuityContextLoad ?? 0, tone: continuityTone
            ),
            OrchestrationCardState(
                title: "RUNE FORGE", state: runeState,
                detail: "\(runtime.runeForgeSelectedSourceCount) selected · \(runtime.runeForgeProcessedObservationCount) observed",
                fraction: min(max(runeLoad, 0), 1), tone: runeTone
            ),
        ]
    }

    private var projectProgressCard: OrchestrationCardState {
        let runtime = model.rigOperationalSnapshot
        let completed = runtime.projectCompletedSteps + runtime.projectCompletedPackages
        let total = runtime.projectTotalSteps + runtime.projectTotalPackages
        let state = runtime.projectProgressState ?? "CHECK"
        let tone: TelemetryStatusTone = switch state {
        case "COMPLETE": .healthy
        case "RUNNING": .informational
        case "ATTENTION": .caution
        case "QUEUED", "NO PACKAGES": .unavailable
        default: .unavailable
        }
        let detail: String
        if let package = runtime.currentPackageName,
           let step = runtime.currentStep,
           let stepTotal = runtime.currentStepTotal {
            detail = "\(package) · step \(step)/\(stepTotal) · "
                + "\(runtime.projectCompletedPackages)/\(runtime.projectTotalPackages) packages"
        } else {
            detail = "\(runtime.projectCompletedSteps)/\(runtime.projectTotalSteps) steps · "
                + "\(runtime.projectCompletedPackages)/\(runtime.projectTotalPackages) packages"
        }
        return OrchestrationCardState(
            title: "PROJECT · \(runtime.projectName ?? "NO SELECTION")",
            state: state,
            detail: detail,
            fraction: total > 0 ? min(max(Double(completed) / Double(total), 0), 1) : 0,
            tone: tone
        )
    }

    // MARK: Managed run activity

    private var instrumentationPanels: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 14) {
                computeCoresPanel
                    .frame(
                        minWidth: 680,
                        maxWidth: .infinity,
                        minHeight: 164,
                        alignment: .topLeading
                    )
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        storagePanel
                        orchestrationPanel
                    }
                    .frame(width: 300)
                    managedActivityFeedPanel
                        .frame(
                            minWidth: 430,
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                computeCoresPanel.frame(minHeight: 238)
                storagePanel.frame(minHeight: 220)
                orchestrationPanel
                managedActivityFeedPanel
            }
        }
    }

    private var managedActivityFeedPanel: some View {
        let runtime = model.rigOperationalSnapshot
        return panel(
            "FORGE ACTIVITY",
            meta: "\(runtime.activityFeed.count)/\(RigOperationalSnapshot.maximumActivityEntries) · 5 s"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                managedActivityEvidenceStatus(runtime)
                currentInstructionStatus(runtime)
                Divider().overlay(GraphitePalette.separator.opacity(0.16))
                if runtime.activityFeed.isEmpty {
                    Text("Waiting for instruction, continuity, orchestration, or policy activity.")
                        .font(.system(size: 12))
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(runtime.activityFeed) { entry in
                                managedActivityRow(entry)
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-managed-activity-feed")
    }

    private func managedActivityEvidenceStatus(_ runtime: RigOperationalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOURCE STATUS")
                .foregroundStyle(GraphitePalette.textSecondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                managedActivitySourceBadge(
                    "MANAGER",
                    available: runtime.operatorEvidenceAvailable
                )
                managedActivitySourceBadge(
                    "INSTRUCTIONS",
                    available: runtime.instructionEvidenceAvailable
                )
                managedActivitySourceBadge(
                    "POLICY",
                    available: runtime.policyEvidenceAvailable
                )
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .accessibilityElement(children: .combine)
    }

    private func managedActivitySourceBadge(_ label: String, available: Bool) -> some View {
        Text("\(label) \(available ? "LIVE" : "UNAVAILABLE")")
            .foregroundStyle(available ? Color.mint : GraphitePalette.warning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().stroke(
                    (available ? Color.mint : Color.orange).opacity(0.55),
                    lineWidth: 1
                )
            )
    }

    @ViewBuilder
    private func currentInstructionStatus(_ runtime: RigOperationalSnapshot) -> some View {
        if let package = runtime.currentPackageName {
            VStack(alignment: .leading, spacing: 4) {
                Text("PROJECT · \(runtime.projectName ?? "NO SELECTION")")
                    .foregroundStyle(GraphitePalette.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("CURRENT PACKAGE")
                        .foregroundStyle(.cyan)
                    Text(package)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let position = runtime.currentPackagePosition,
                       runtime.projectTotalPackages > 0 {
                        Text("\(position)/\(runtime.projectTotalPackages)")
                            .foregroundStyle(GraphitePalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    if let state = runtime.activeRunState {
                        Text(OperatorRunStatePresentation.displayName(state).uppercased())
                            .foregroundStyle(.mint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let step = runtime.currentStep, let total = runtime.currentStepTotal {
                        let delivered = runtime.currentPackageCompletedSteps ?? max(step - 1, 0)
                        Text("CURRENT STEP \(step) OF \(total) · \(delivered) DELIVERED")
                            .foregroundStyle(GraphitePalette.warning)
                    } else {
                        Text("STEP —")
                            .foregroundStyle(GraphitePalette.textSecondary)
                    }
                    if let phase = runtime.currentPhase {
                        Text("· \(phase)").foregroundStyle(GraphitePalette.textSecondary)
                    }
                    if let workItem = runtime.currentWorkItem {
                        Text("· \(workItem)")
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let nextAction = runtime.currentNextAction {
                    Text("NEXT · \(nextAction)")
                        .foregroundStyle(GraphitePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("PROJECT · \(runtime.projectName ?? "NO SELECTION")")
                if !runtime.operatorEvidenceAvailable {
                    Text("CURRENT PACKAGE · Awaiting verified Manager snapshot")
                } else if !runtime.instructionEvidenceAvailable {
                    Text("CURRENT PACKAGE · Instruction queue unavailable")
                } else {
                    Text("CURRENT PACKAGE · No active instruction package")
                }
                if let state = runtime.activeRunState {
                    Text(
                        "BACKGROUND EXECUTION · "
                            + OperatorRunStatePresentation.displayName(state).uppercased()
                    )
                        .foregroundStyle(.mint)
                    if let phase = runtime.currentPhase {
                        Text("PHASE · \(phase)")
                    }
                    if let workItem = runtime.currentWorkItem {
                        Text("WORK · \(workItem)")
                    }
                    if let nextAction = runtime.currentNextAction {
                        Text("NEXT · \(nextAction)")
                    }
                }
                if let nextPackage = runtime.nextPackageName {
                    let position = runtime.nextPackagePosition.map(String.init) ?? "—"
                    let steps = runtime.nextPackageStepTotal.map(String.init) ?? "—"
                    Text(
                        "NEXT PACKAGE · \(nextPackage) · POSITION \(position)"
                            + " · \(steps) STEPS"
                    )
                    .foregroundStyle(GraphitePalette.warning)
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(GraphitePalette.textSecondary)
        }
    }

    private func managedActivityRow(_ entry: RigActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(activityTime(entry.occurredAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(GraphitePalette.textSecondary)
                    .frame(width: 74, alignment: .leading)
                Text(entry.category.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(activityColor(entry.severity))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().stroke(activityColor(entry.severity).opacity(0.55)))
                Text(activitySeverityTitle(entry.severity))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(activityColor(entry.severity))
                Text(entry.title)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            Text(entry.message)
                .foregroundStyle(.primary.opacity(0.88))
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(activityColor(entry.severity).opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(activityColor(entry.severity).opacity(0.24), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.category.rawValue) \(activitySeverityTitle(entry.severity)) \(entry.title): \(entry.message)"
        )
        .accessibilityIdentifier("rig-activity-row-\(entry.id)")
    }

    private func activityTime(_ date: Date) -> String {
        guard date != .distantPast else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func activityColor(_ severity: RigActivitySeverity) -> Color {
        switch severity {
        case .informational: GraphitePalette.info
        case .success: GraphitePalette.success
        case .warning: GraphitePalette.warning
        case .failure: GraphitePalette.failure
        }
    }

    private func activitySeverityTitle(_ severity: RigActivitySeverity) -> String {
        switch severity {
        case .informational: "INFO"
        case .success: "SUCCESS"
        case .warning: "WARNING"
        case .failure: "FAILURE"
        }
    }

    // MARK: Header

    private var headerPills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                dashboardTitle
                statusPills
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    dashboardTitle
                }
                statusPills
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var dashboardTitle: some View {
        let provider = model.rigOperationalSnapshot.selectedProvider
        let providerName = if provider.executionMode == .unavailable,
                              !provider.integrationEvidenceAvailable {
            "LM Studio"
        } else if provider.id == nil {
            "Provider"
        } else {
            provider.displayName
        }
        let subtitle = if provider.executionMode == .desktopHost {
            "Host-managed provider · GPU · Disk · MCP · Live Feed · Metal"
        } else if provider.executionMode == .unavailable,
                  provider.integrationEvidenceAvailable {
            "Provider selection · GPU · Disk · MCP · Live Feed · Metal"
        } else {
            "Local models · GPU · Disk · LM Studio MCP · Live Feed · Metal"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Dashboard")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(GraphitePalette.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("detail-rig")
            Text("\(providerName) · \(subtitle)")
                .font(.system(size: 13))
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var statusPills: some View {
        // Bounded status strip stays stable while telemetry updates.
        HStack(spacing: 6) {
            MetalStatusPill(
                text: "LINK",
                tone: model.lastError == nil ? .healthy : .failure,
                fraction: 1
            )
            MetalStatusPill(
                text: "ORCH \(model.orchestration?.healthLabel ?? "—")",
                tone: TelemetryHealth.tone(for: model.orchestration?.health),
                fraction: model.orchestration?.health == "ok" ? 1 : 0.25
            )
            MetalStatusPill(
                text: "MCP \(model.mcpServerCards.filter(\.live).count)/\(model.mcpServerCards.count)",
                tone: mcpHeaderTone,
                fraction: model.mcpServerCards.isEmpty ? 0 : Double(model.mcpServerCards.filter(\.live).count) / Double(model.mcpServerCards.count)
            )
            MetalStatusPill(
                text: String(format: "LOAD %.0f", model.cpuPercent),
                tone: model.cpuPercent < 90 ? .healthy : .caution,
                fraction: min(model.cpuPercent / 100, 1)
            )
        }
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(0)
    }

    // MARK: Sys strip — bounded Metal traces and meters

    private var sysStrip: some View {
        let s = model.sysStrip
        let gpuValue = s.gpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let gpuFraction = s.gpuPercent.map { $0 / 100 } ?? 0
        let gpuMetadata = s.gpuPercent == nil ? "telemetry unavailable" : "Metal IOKit"
        let gpuTint: Color = s.gpuPercent == nil ? GraphitePalette.textMuted : GraphitePalette.chartGPU
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 136), spacing: 12)], spacing: 12) {
            sysCard("CPU", value: String(format: "%.1f%%", s.cpuPercent), meta: s.cpuBrand, frac: s.cpuPercent / 100, tint: GraphitePalette.chartCPU, history: model.historyCPU.map(Optional.some))
            sysCard("FREQ", value: s.freqMHz.map { "\($0)" } ?? "—", meta: "MHz · load \(String(format: "%.2f", s.loadM1))", frac: min((Double(s.freqMHz ?? 0) / 4000), 1), tint: GraphitePalette.primaryFill)
            sysCard("RAM", value: String(format: "%.1f%%", s.ramPercent), meta: "pressure", frac: s.ramPercent / 100, tint: GraphitePalette.chartRAM, history: model.historyRAM.map(Optional.some))
            sysCard(
                "GPU",
                value: gpuValue,
                meta: gpuMetadata,
                frac: gpuFraction,
                tint: gpuTint,
                history: model.historyGPU
            )
            sysCard(
                "DISK I/O",
                value: String(format: "%.1f", s.diskTotalMBs),
                meta: String(format: "R %.1f · W %.1f MB/s", s.diskReadMBs, s.diskWriteMBs),
                frac: min(s.diskTotalMBs / 200, 1),
                tint: GraphitePalette.chartDisk,
                history: model.history.map { Float($0.diskIO) },
                maximumValue: 200
            )
        }
    }

    private func sysCard(_ title: String, value: String, meta: String, frac: Double, tint: Color,
                         history: [Float?]? = nil, maximumValue: Float = 100) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GraphitePalette.textSecondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(GraphitePalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .help(value)
            if let history {
                MetalLoadChart(optionalSamples: history, tint: tint, maximumValue: maximumValue, fraction: frac)
                    .frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("\(title) recent samples and current level")
                    .accessibilityValue(value)
            } else {
                MetalBarGauge(fraction: frac, tint: tint)
                    .frame(height: 10)
                    .clipShape(Capsule())
                    .frame(height: 40, alignment: .bottom)
                    .accessibilityLabel("\(title) current level")
                    .accessibilityValue(value)
            }
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(GraphitePanelSurface())

    }

    // MARK: CPU cores — Metal

    private var computeCoresPanel: some View {
        let projection = ComputeChipSnapshot.project(
            cpu: model.system?.cpu,
            gpu: model.system?.gpu ?? [],
            devices: ComputeChipResources.shared.devices,
            now: Date().timeIntervalSince1970
        )
        let gpuCount = projection.gpu.hardwareCoreCount.map { "GPU \($0) cores" } ?? "GPU count unavailable"
        return panel(
            "COMPUTE CORES",
            meta: "CPU \(projection.cpu.logicalCount) logical · \(gpuCount)",
            surface: GraphitePanelSurface(topColor: GraphitePalette.computePanelTop, bottomColor: GraphitePalette.computePanelBottom)
        ) {
            ComputeCoresContentView(snapshot: projection, autoRefresh: model.autoRefresh)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-compute-cores-panel")
    }

    // MARK: Storage — Metal meters

    private var storagePanel: some View {
        let disks = model.diskVolumes
        let io = model.diskIO
        return panel("STORAGE", meta: String(format: "%.1f MB/s total", io.totalMBs)) {
            HStack(spacing: 14) {
                ioStat("READ", io.readMBs, io.readIOPS, frac: min(io.readMBs / 100, 1), tint: GraphitePalette.chartCPU)
                ioStat("WRITE", io.writeMBs, io.writeIOPS, frac: min(io.writeMBs / 100, 1), tint: GraphitePalette.chartRAM)
                ioStat("TOTAL", io.totalMBs, io.totalIOPS, frac: min(io.totalMBs / 200, 1), tint: GraphitePalette.chartDisk)
            }
            .padding(.bottom, 10)
            if disks.isEmpty {
                Text("NO VOLUME DATA").font(.caption).foregroundStyle(GraphitePalette.textSecondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(disks.prefix(4).enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(d.mount).font(.system(size: 11, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(d.mount)
                                Spacer(minLength: 8)
                                Text(String(format: "%.0f/%.0f GB · %.0f%%", d.usedGB, d.totalGB, d.percent))
                                    .font(.system(size: 11).monospacedDigit())
                                    .fixedSize()
                                    .foregroundStyle(GraphitePalette.textSecondary)
                            }
                            MetalBarGauge(fraction: d.percent / 100, tint: GraphitePalette.chartCPU)
                                .frame(height: 10)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-storage-panel")
    }

    private func ioStat(_ title: String, _ mbs: Double, _ iops: Double, frac: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(GraphitePalette.textSecondary)
            Text(String(format: "%.1f MB/s", mbs)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
            MetalBarGauge(fraction: frac, tint: tint).frame(height: 8).clipShape(Capsule())
            Text(String(format: "%.0f IOPS", iops)).font(.system(size: 11).monospacedDigit()).foregroundStyle(GraphitePalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Orchestration

    private var orchestrationPanel: some View {
        let o = model.orchestration
        let mode = o?.mode ?? "—"
        let cards: [OrchestrationCardState] = {
            if mode == "swift-manager" || o?.managerAlive == true {
                let mcpN = Double(o?.mcpExternalCount ?? 0)
                let alive = o?.managerAlive == true
                return [
                    OrchestrationCardState(
                        title: "MANAGER",
                        state: alive ? "UP" : "DOWN",
                        detail: "swift",
                        fraction: alive ? 1 : 0,
                        tone: alive ? .healthy : .failure
                    ),
                    OrchestrationCardState(
                        title: "HTTP",
                        state: model.serviceActive ? "UP" : (alive ? "CHECK" : "DOWN"),
                        detail: model.serviceState,
                        fraction: model.serviceActive ? 1 : 0.35,
                        tone: model.serviceActive ? .healthy : (alive ? .caution : .failure)
                    ),
                    OrchestrationCardState(
                        title: "MCP PROCS",
                        state: mcpN > 0 ? "ACTIVE" : "IDLE",
                        detail: mcpN > 0 ? "\(Int(mcpN)) local" : "LM Studio starts on demand",
                        fraction: min(mcpN / 2, 1),
                        tone: mcpN > 0 ? .healthy : .informational
                    ),
                    OrchestrationCardState(
                        title: "SERVE",
                        state: (o?.serveCount ?? 0) > 0 ? "ACTIVE" : "IDLE",
                        detail: (o?.serveCount ?? 0) > 0
                            ? "\(o?.serveCount ?? 0) stdio role(s)"
                            : "waiting for LM Studio",
                        fraction: min(Double(o?.serveCount ?? 0) / 2, 1),
                        tone: (o?.serveCount ?? 0) > 0 ? .healthy : .informational
                    ),
                    OrchestrationCardState(
                        title: "STATUS",
                        state: o?.healthLabel ?? "—",
                        detail: mode,
                        fraction: o?.health == "ok" ? 1 : 0.2,
                        tone: TelemetryHealth.tone(for: o?.health)
                    ),
                ]
            }
            return [
                OrchestrationCardState(
                    title: "STATUS",
                    state: o?.healthLabel ?? "—",
                    detail: mode,
                    fraction: o?.health == "ok" ? 1 : 0.2,
                    tone: TelemetryHealth.tone(for: o?.health)
                ),
            ]
        }()

        return panel("ORCHESTRATION", meta: "\(o?.healthLabel ?? "—") · \(mode)") {
            LazyVGrid(columns: cards.count == 1
                      ? [GridItem(.flexible())]
                      : [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                ForEach(Array(cards.enumerated()), id: \.offset) { _, c in
                    orchestrationCard(c)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-orchestration-panel")
    }

    private func orchestrationCard(
        _ card: OrchestrationCardState,
        compact: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text(card.title).fixedSize()
                    Spacer(minLength: 4)
                    orchestrationStateLabel(card).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).fixedSize(horizontal: false, vertical: true)
                    orchestrationStateLabel(card)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            MetalBarGauge(fraction: card.fraction, tint: card.tone.color)
                .frame(height: compact ? 6 : 8)
                .clipShape(Capsule())
            Text(card.detail)
                .font(.system(size: 12))
                .foregroundStyle(GraphitePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 7 : 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(card.tone.color.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.title), \(card.state), \(card.detail)")
        .accessibilityValue(card.tone.rawValue)
    }

    private func orchestrationStateLabel(_ card: OrchestrationCardState) -> some View {
        HStack(spacing: 6) {
            Circle().fill(card.tone.color).frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(card.state).foregroundStyle(card.tone.color)
        }
    }

    // MARK: MCP servers — Metal rings

    private var mcpServersPanel: some View {
        let cards = model.mcpServerCards
        return panel("MCP SERVERS", meta: "\(cards.count) cards · Metal rings", fillsGridRow: true) {
            if cards.isEmpty {
                Text("NO MCP PRESENCE — WAITING FOR HEARTBEAT / PROCESS SCAN")
                    .font(.caption).foregroundStyle(GraphitePalette.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    ForEach(Array(cards.prefix(12).enumerated()), id: \.offset) { _, s in
                        let identity = Text(s.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        let health = Text(s.healthLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(healthColor(s.health))
                        VStack(alignment: .leading, spacing: 8) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    identity.fixedSize()
                                    Spacer(minLength: 8)
                                    health.fixedSize()
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    identity.fixedSize(horizontal: false, vertical: true)
                                    health.fixedSize()
                                }
                            }
                            .help(s.label)
                            HStack(alignment: .top, spacing: 12) {
                                MetalRingGaugeLabeled(
                                    fraction: s.activity / 100,
                                    tint: healthColor(s.health),
                                    centerText: "\(Int(s.activity))"
                                )
                                .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(s.role) · \(s.status)\(s.live ? " · LINK" : "")")
                                        .font(.system(size: 11, design: .monospaced))
                                    Text(String(format: "%.1f evt/min · %d/5m · err %.2f", s.eventsPerMin, s.eventCount5m, s.errorRate))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(GraphitePalette.textSecondary)
                                    Text("pid \(s.pid.map(String.init) ?? "—") · \(s.source)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(GraphitePalette.textSecondary)
                                    if !s.topTools.isEmpty {
                                        Text(s.topTools.joined(separator: " · "))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.cyan.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                    if !s.healthReason.isEmpty {
                                        Text(s.healthReason)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(GraphitePalette.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            MetalBarGauge(fraction: s.activity / 100, tint: healthColor(s.health))
                                .frame(height: 5)
                                .clipShape(Capsule())
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(healthColor(s.health).opacity(0.35)))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-mcp-servers-panel")
    }

    // MARK: MCP tools — Metal load tiles

    private var mcpToolsPanel: some View {
        let tools = model.toolCards
        let packs = model.toolPacks
        return panel("MCP TOOLS", meta: "\(tools.count) tools · Metal load tiers", fillsGridRow: true) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(packs.prefix(12).enumerated()), id: \.offset) { _, p in
                        let active = Double(p.activeCount)
                        let total = max(Double(p.toolCount), 1)
                        VStack(spacing: 4) {
                            Text(p.pack)
                                .font(.system(size: 11, design: .monospaced))
                            MetalBarGauge(fraction: active / total, tint: GraphitePalette.chartCPU)
                                .frame(width: 64, height: 6)
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Capsule().stroke(GraphitePalette.separator.opacity(0.35)))
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 8)], spacing: 8) {
                ForEach(Array(tools.prefix(48).enumerated()), id: \.offset) { _, t in
                    MetalToolLoadTile(
                        shortLabel: String(t.shortLabel.prefix(6)),
                        activity: t.activity,
                        health: t.health,
                        loadTier: t.loadTier
                    )
                    .help("\(t.name) · \(t.pack) · \(t.healthLabel) · \(t.events1h)/1h · load \(t.loadTier)/3")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-mcp-tools-panel")
    }

    // MARK: Agents — Metal rings

    private var agentsPanel: some View {
        let agents = model.agentCards
        return panel("SUB-AGENTS", meta: "\(agents.count) · Metal", fillsGridRow: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(Array(agents.prefix(12).enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(a.agentID)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(a.healthLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(healthColor(a.health))
                        }
                        HStack(alignment: .top, spacing: 10) {
                            MetalRingGaugeLabeled(
                                fraction: a.activity / 100,
                                tint: healthColor(a.health),
                                centerText: a.live ? "ON" : "SB"
                            )
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(a.status)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(GraphitePalette.textSecondary)
                                if let last = a.lastSessionStatus {
                                    Text("last \(last)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(GraphitePalette.textSecondary)
                                }
                                if let sum = a.summary, !sum.isEmpty {
                                    Text(sum).font(.system(size: 12))
                                        .foregroundStyle(GraphitePalette.textSecondary).lineLimit(2)
                                        .help(sum)
                                }
                            }
                        }
                        MetalBarGauge(fraction: a.activity / 100, tint: healthColor(a.health))
                            .frame(height: 6)
                            .clipShape(Capsule())
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(healthColor(a.health).opacity(0.35)))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-sub-agents-panel")
    }

    // MARK: Processes

    private var processesPanel: some View {
        panel("HOT PROCESSES", meta: "LM Studio · Forge · llama", fillsGridRow: true) {
            if model.hotProcesses.isEmpty {
                Text("NO MATCHING PROCESSES").font(.caption).foregroundStyle(GraphitePalette.textSecondary)
            } else {
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("PID").frame(width: 52, alignment: .trailing)
                        Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: 100, alignment: .leading)
                        Text("RSS").frame(width: 48, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GraphitePalette.textSecondary)
                    ForEach(Array(model.hotProcesses.prefix(12).enumerated()), id: \.offset) { _, p in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(p.pid)").frame(width: 52, alignment: .trailing)
                            Text(p.name).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                .help(p.name)
                            MetalBarGauge(fraction: min(p.cpuPercent / 100, 1), tint: p.cpuPercent > 50 ? .orange : .cyan)
                                .frame(width: 100, height: 8)
                                .clipShape(Capsule())
                            Text(String(format: "%.2fG", p.rssGB)).frame(width: 48, alignment: .trailing)
                        }
                        .font(.system(size: 12).monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-hot-processes-panel")
    }

    // MARK: Live feed

    private var liveFeedPanel: some View {
        // Column budget (pt): ts 56 + status 36 + gap×3(24) + bar 40 + ms 44 = 200 fixed.
        // Tool name takes remaining width and truncates — never pushes past the panel.
        panel("LIVE STREAM ▮ TOOLS · AGENTS · DIAGNOSTICS", meta: "\(model.liveFeedEvents.count)") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(model.liveFeedEvents.prefix(24).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 8) {
                        Text(String(e.timestamp.suffix(8)))
                            .foregroundStyle(GraphitePalette.textSecondary)
                            .frame(width: 56, alignment: .leading)
                        Text(e.status)
                            .foregroundStyle(auditStatusColor(e.status))
                            .frame(width: 36, alignment: .leading)
                        Text(e.tool)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let ms = e.durationMs {
                            MetalBarGauge(fraction: min(Double(ms) / 2000, 1), tint: GraphitePalette.primaryFill)
                                .frame(width: 40, height: 5)
                                .clipShape(Capsule())
                                .allowsHitTesting(false)
                            Text("\(ms)ms")
                                .foregroundStyle(GraphitePalette.textSecondary)
                                .frame(width: 44, alignment: .trailing)
                        } else {
                            Color.clear.frame(width: 40 + 8 + 44, height: 5)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220, alignment: .topLeading)
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rig-live-stream-panel")
    }

    // MARK: Helpers

    private struct OrchestrationCardState {
        var title: String
        var state: String
        var detail: String
        var fraction: Double
        var tone: TelemetryStatusTone
    }

    private var mcpHeaderTone: TelemetryStatusTone {
        TelemetryStatusTone.mostSevere(
            model.mcpServerCards.map { TelemetryHealth.tone(for: $0.health) }
        )
    }

    private func panel<Content: View>(
        _ title: String,
        meta: String,
        fillsGridRow: Bool = false,
        surface: GraphitePanelSurface = GraphitePanelSurface(),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 12)
                    Text(meta).font(.system(size: 11)).foregroundStyle(GraphitePalette.textMuted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(meta).font(.system(size: 11)).foregroundStyle(GraphitePalette.textMuted)
                }
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(
            maxWidth: .infinity,
            minHeight: fillsGridRow ? 200 : nil,
            maxHeight: fillsGridRow ? .infinity : nil,
            alignment: .topLeading
        )
        .background(surface)
    }

    private func healthColor(_ h: String) -> Color {
        TelemetryHealth.tone(for: h).color
    }

    private func auditStatusColor(_ status: String) -> Color {
        switch AuditOutcome(status: status) {
        case .success:
            return .green
        case .operationalError:
            return .red
        case .policyDenied:
            return .orange
        case .maintenanceWarning:
            return .yellow
        case .other:
            return .secondary
        }
    }
}
