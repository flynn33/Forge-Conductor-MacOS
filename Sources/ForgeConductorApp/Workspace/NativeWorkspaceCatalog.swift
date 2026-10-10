import SwiftUI

enum NativeWorkspaceCatalog {
    static let panelsByView: [String: [NativeWorkspacePanelDescriptor]] = [
        "rig": dashboard, "tools": tools, "feed": feed, "projects": projects,
        "mcp": mcp, "agents": agents, "diagnostics": diagnostics,
        "continuity": continuity, "evidence": evidence,
        "runtimes": runtimes, "provider": provider,
        "rune-forge.overview": runePanels(for: "overview"), "rune-forge.feed": runePanels(for: "feed"),
        "rune-forge.source": runePanels(for: "source"), "rune-forge.violation": runePanels(for: "violation"),
        "manager.workbench": managerPanels(for: "workbench"), "manager.folders": managerPanels(for: "folders"),
        "manager.service": managerPanels(for: "service"), "manager.runtime": managerPanels(for: "runtime"),
        "manager.settings": managerPanels(for: "settings"), "manager.shell": managerPanels(for: "shell"),
        "manager.filesystem": managerPanels(for: "filesystem"), "manager.maintenance": managerPanels(for: "maintenance"),
        "manager.doctor": managerPanels(for: "doctor"),
    ]

    static var knownPanelIDsByView: [String: Set<String>] {
        panelsByView.mapValues { Set($0.map(\.id)) }
    }

    static var sizeBoundsByView: [String: [String: NativeWorkspacePanelSizeBounds]] {
        panelsByView.mapValues { panels in
            Dictionary(uniqueKeysWithValues: panels.map { panel in
                (panel.id, NativeWorkspacePanelSizeBounds(
                    minimumWidth: panel.minimumSize.width, minimumHeight: panel.minimumSize.height,
                    maximumWidth: panel.maximumSize.width, maximumHeight: panel.maximumSize.height))
            })
        }
    }

    static let dashboard: [NativeWorkspacePanelDescriptor] = [
        panel("rig-header", "Dashboard and Status", 20, 20, 1340, 160, minimumWidth: 700),
        panel("rig-current-project", "Current Project", 20, 200, 760, 230, minimumWidth: 420),
        panel("rig-system-strip", "System Metrics", 20, 450, 760, 220, minimumWidth: 700),
        panel("rig-load-trace", "Load Trace", 20, 690, 760, 290, minimumWidth: 420, minimumHeight: 260),
        panel("rig-operational-indicators", "Operational Indicators", 800, 200, 560, 780, minimumWidth: 420),
        panel("rig-compute-cores-panel", "Compute Cores", 20, 1000, 940, 480, minimumWidth: 540, minimumHeight: 300),
        panel("rig-storage-panel", "Storage", 980, 1000, 380, 480),
        panel("rig-orchestration-panel", "Orchestration", 20, 1500, 650, 420),
        panel("rig-managed-activity-feed", "Managed Activity", 690, 1500, 670, 420),
        panel("rig-mcp-servers-panel", "MCP Servers", 20, 1940, 650, 460),
        panel("rig-mcp-tools-panel", "MCP Tools", 690, 1940, 670, 460),
        panel("rig-sub-agents-panel", "Agents", 20, 2420, 650, 440),
        panel("rig-hot-processes-panel", "Hot Processes", 690, 2420, 670, 440, minimumWidth: 500),
        panel("rig-live-stream-panel", "Live Feed", 20, 2880, 1340, 340, minimumWidth: 540),
    ]

    static let tools: [NativeWorkspacePanelDescriptor] = [
        panel("tools-controls", "Tools and Filter", 20, 20, 900, 160, minimumWidth: 360),
        panel("tools-outcome-legend", "Outcome Guide", 20, 200, 900, 200),
        panel("tools-catalog", "Registered Tools", 20, 420, 1100, 640, minimumWidth: 440, scrollsContent: false),
    ]

    static let feed: [NativeWorkspacePanelDescriptor] = [
        panel("feed-summary", "Activity Summary", 20, 20, 900, 180, minimumWidth: 440),
        panel("feed-events", "Audited Events", 20, 220, 1100, 680, minimumWidth: 500, scrollsContent: false),
    ]

    static let mcp: [NativeWorkspacePanelDescriptor] = [
        panel("mcp-controls", "Connection and Actions", 20, 20, 900, 180, minimumWidth: 420),
        panel("mcp-plugin-status", "Deployment Status", 20, 220, 900, 420),
        panel("mcp-servers", "MCP Servers", 20, 660, 900, 520),
        panel("mcp-guidance", "Deployment Workflow", 20, 1200, 900, 260),
    ]

    static let agents: [NativeWorkspacePanelDescriptor] = [
        panel("agents-controls", "Agents and Maintenance", 20, 20, 900, 180),
        panel("agents-catalog", "Agent Playbooks", 20, 220, 1000, 640, scrollsContent: false),
    ]

    static let diagnostics: [NativeWorkspacePanelDescriptor] = [
        panel("diagnostics-controls", "Diagnostics and Export", 20, 20, 1000, 180, minimumWidth: 420),
        panel("diagnostics-status", "Export Status", 20, 220, 1000, 300),
        panel("diagnostics-runtime", "Runtime Counters", 20, 540, 1000, 200),
        panel("diagnostics-records", "Diagnostic Records", 20, 760, 1100, 680, scrollsContent: false),
    ]

    static let continuity: [NativeWorkspacePanelDescriptor] = [
        panel("continuity-controls", "Continuity and Actions", 20, 20, 1100, 240, minimumWidth: 420),
        panel("continuity-status", "Request Status", 20, 280, 1100, 200),
        panel("continuity-projects", "Project IDs", 20, 500, 340, 580, scrollsContent: false),
        panel("continuity-packets", "Continuity Packets", 380, 500, 740, 580, minimumWidth: 440, scrollsContent: false),
    ]

    static let evidence: [NativeWorkspacePanelDescriptor] = [
        panel("evidence-controls", "Events, Search and Export", 20, 20, 1100, 240, minimumWidth: 420),
        panel("evidence-events", "Manager Events", 20, 280, 1100, 600, minimumWidth: 440, scrollsContent: false),
        panel("evidence-paging", "Event Paging", 20, 900, 1100, 160, minimumWidth: 420),
    ]

    static let runtimes: [NativeWorkspacePanelDescriptor] = [
        panel("runtimes-controls", "Runtimes and Actions", 20, 20, 1120, 220, minimumWidth: 420),
        panel("runtimes-jobs", "Active and Recent Jobs", 20, 260, 340, 620, scrollsContent: false),
        panel("runtimes-requirements", "Task Requirements", 380, 260, 760, 260),
        panel("runtimes-selected-job", "Selected Job", 380, 540, 760, 340),
        panel("runtimes-shell", "Shell Policy", 20, 900, 540, 340),
        panel("runtimes-capabilities", "Runtime Capabilities", 580, 900, 560, 340),
        panel("runtimes-limits", "Runtime Limits", 20, 1260, 1120, 300),
    ]

    static let provider: [NativeWorkspacePanelDescriptor] = [
        panel("provider-controls", "Provider and Actions", 20, 20, 1120, 260, minimumWidth: 420),
        panel("provider-browser", "Execution Providers", 20, 300, 340, 640, scrollsContent: false),
        panel("provider-operation", "Setup Operation", 380, 300, 760, 260),
        panel("provider-integration", "Provider Integration", 380, 580, 760, 360),
        panel("provider-readiness", "Model Readiness", 20, 960, 1120, 340),
        panel("provider-settings", "Provider Settings", 20, 1320, 1120, 760, minimumWidth: 420),
        panel("provider-connection", "Connection", 20, 2100, 540, 300),
        panel("provider-authentication", "Authentication Status", 580, 2100, 560, 300),
        panel("provider-model", "Loaded Model", 20, 2420, 540, 300),
        panel("provider-contract", "Lifecycle and Contract", 580, 2420, 560, 300),
    ]

    static func runePanels(for mode: String) -> [NativeWorkspacePanelDescriptor] {
        var panels = [
            panel("rune-controls", "Rune Forge and Actions", 20, 20, 1120, 220, minimumWidth: 440),
            panel("rune-navigation", "Policy Sources and Violations", 20, 260, 340, 700, scrollsContent: false),
        ]
        let detail: [(String, String)]
        switch mode {
        case "feed": detail = [("rune-events", "Policy Events"), ("rune-evaluations", "Evaluation Activity")]
        case "source": detail = [("rune-source-actions", "Selected Source and Actions"), ("rune-source-identity", "Source Identity"), ("rune-source-path", "Path and Interpretation")]
        case "violation": detail = [("rune-violation-identity", "Violation Identity"), ("rune-violation-evidence", "Evidence and Interpretation"), ("rune-violation-history", "Occurrence History")]
        default: detail = [("rune-authority", "Governing Policy"), ("rune-health", "Policy Health"), ("rune-limitations", "Current Limitations")]
        }
        for (index, item) in detail.enumerated() {
            panels.append(panel(item.0, item.1, 380, 260 + Double(index) * 400, 760, 380))
        }
        return panels
    }

    static let projects: [NativeWorkspacePanelDescriptor] = [
        panel("projects-sidebar", "Registered Projects", 20, 20, 300, 780, minimumWidth: 280, minimumHeight: 320, scrollsContent: false),
        panel("projects-status", "Project Status", 340, 20, 1100, 160, minimumWidth: 420, minimumHeight: 140),
        panel("projects-registration-reconciliation", "Registration Reconciliation", 340, 200, 1100, 320, minimumWidth: 420, minimumHeight: 180),
        panel("projects-summary", "Selected Project", 340, 540, 1100, 180, minimumWidth: 420, minimumHeight: 160),
        panel("projects-workflow", "Project Workflow", 340, 740, 1100, 240, minimumWidth: 260, minimumHeight: 180),
        panel("projects-instructions", "Instruction Packages", 20, 1000, 1420, 640, minimumWidth: 560, minimumHeight: 260),
        panel("projects-identity", "Project Identity", 20, 1660, 420, 160, minimumWidth: 280, minimumHeight: 140),
        panel("projects-repository", "GitHub Repository", 460, 1660, 980, 300, minimumWidth: 520, minimumHeight: 200),
        panel("projects-bindings", "Active Bindings", 20, 1980, 700, 300, minimumWidth: 300, minimumHeight: 160),
        panel("projects-memory", "Project Memory", 740, 1980, 700, 300, minimumWidth: 300, minimumHeight: 180),
        panel("projects-continuity", "Project Continuity", 20, 2300, 700, 260, minimumWidth: 300, minimumHeight: 180),
        panel("projects-migration-warnings", "Migration Warnings", 740, 2300, 700, 260, minimumWidth: 300, minimumHeight: 160),
        panel("projects-reset-receipt", "Latest Reset Receipt", 20, 2580, 700, 240, minimumWidth: 300, minimumHeight: 180),
        panel("projects-relink-reconciliation", "Relink Reconciliation", 740, 2580, 700, 360, minimumWidth: 340, minimumHeight: 220),
        panel("projects-clear-content", "Clear Project Content", 20, 2960, 700, 400, minimumWidth: 480, minimumHeight: 260),
        panel("projects-lifecycle", "Project Registration Actions", 740, 2960, 700, 180, minimumWidth: 480, minimumHeight: 160),
    ]

    static func managerPanels(for section: String) -> [NativeWorkspacePanelDescriptor] {
        var panels = [
            panel("manager-navigation", "Manager Sections", 20, 20, 300, 740, scrollsContent: false),
            panel("manager-header", "Section Heading", 340, 20, 920, 180, minimumWidth: 420),
            panel("manager-status", "Manager Status", 340, 220, 920, 220, minimumWidth: 420),
        ]
        let detail: [(String, String)]
        switch section {
        case "workbench": detail = [("manager-workbench-navigation", "Appearance and Navigation"), ("manager-workbench-guidance", "Guided Workflow"), ("manager-workbench-controls", "Optional Controls")]
        case "folders": detail = [("manager-folder-context", "Project Folder Context"), ("manager-folders", "Authorized Folders")]
        case "service": detail = [("manager-service", "Service Controls"), ("manager-service-notes", "Service Behavior")]
        case "runtime": detail = [("manager-runtime-identity", "Runtime Identity"), ("manager-runtime-telemetry", "Runtime Telemetry")]
        case "settings": detail = [("manager-dashboard-settings", "Dashboard Settings"), ("manager-service-settings", "Service Settings"), ("manager-continuity-settings", "Continuity Rollover")]
        case "shell": detail = [("manager-shell-policy", "Project Shell Policy"), ("manager-shell-runtimes", "Shell Runtimes"), ("manager-shell-migration", "Shell Migration")]
        case "filesystem": detail = [("manager-filesystem-status", "Protected Filesystem Status"), ("manager-filesystem-policy", "Protected Filesystem Policy"), ("manager-filesystem-actions", "Protected Filesystem Actions")]
        case "maintenance": detail = [("manager-telemetry-actions", "Telemetry Controls"), ("manager-maintenance", "Session Maintenance")]
        default: detail = [("manager-doctor-actions", "Doctor Actions"), ("manager-doctor-report", "Doctor Report")]
        }
        for (index, item) in detail.enumerated() {
            panels.append(panel(item.0, item.1, 340, 460 + Double(index) * 440, 920, 420, minimumWidth: 440))
        }
        if ["folders", "settings", "shell"].contains(section) {
            panels.append(panel("manager-settings-actions", "Save or Reload Settings", 340, 460 + Double(detail.count) * 440, 920, 180, minimumWidth: 680))
        }
        return panels
    }

    private static func panel(_ id: String, _ title: String, _ x: Double, _ y: Double,
                              _ width: Double, _ height: Double,
                              minimumWidth: Double = 280, minimumHeight: Double = 160,
                              scrollsContent: Bool = true) -> NativeWorkspacePanelDescriptor {
        NativeWorkspacePanelDescriptor(id: id, title: title,
            defaultFrame: .init(x: x, y: y, width: width, height: height),
            minimumSize: CGSize(width: minimumWidth, height: minimumHeight), scrollsContent: scrollsContent)
    }
}
