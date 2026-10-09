// AgentCatalog.swift
// What: Loads built-in and user-supplied agent playbooks into a typed catalog.
// How: It resolves resource/disk sources, parses Markdown front matter, validates
// specifications, and deterministically lets custom definitions override built-ins.
// Why: New agent modules can be added as data without changing framework control flow.

import Foundation

/// Loads agent playbooks from bundled Resources/Agents and ~/.forge-conductor/agents.
public final class AgentCatalog: AgentCatalogProviding, @unchecked Sendable {
    public static let maximumEntries = 256
    private let paths: AppPaths
    private var cache: [String: AgentSpec] = [:]
    private let lock = NSLock()

    public init(paths: AppPaths) {
        self.paths = paths
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: AgentSpec] = [:]
        // Built-ins from bundle (multiple layout variants for SPM vs Xcode resource copy)
        let bundleDirs = ["Agents", "Resources/Agents", nil as String?]
        for sub in bundleDirs {
            let urls: [URL]
            if let sub {
                urls = ResourceBundle.bundle.urls(forResourcesWithExtension: "md", subdirectory: sub) ?? []
            } else {
                urls = ResourceBundle.bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
            }
            for url in urls {
                // Prefer only agent playbooks (frontmatter with id) — ignore unrelated .md
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.hasPrefix("---"),
                      let spec = try? AgentMarkdownParser.parse(text: text, source: "builtin") else { continue }
                map[spec.id] = spec
            }
        }
        // Also try on-disk path next to sources when resources not yet in bundle
        let diskAgents = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Application
            .deletingLastPathComponent() // ForgeConductorCore
            .appendingPathComponent("Resources/Agents", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: diskAgents, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "md" {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let spec = try? AgentMarkdownParser.parse(text: text, source: "builtin") {
                    map[spec.id] = spec
                }
            }
        }
        // Compile-time defaults fill any missing ids
        let fallback = bundledAgentsFallback()
        for spec in fallback where map[spec.id] == nil { map[spec.id] = spec }

        // Custom home agents fully replace same id
        let homeAgents = paths.agentsDir
        if let files = try? FileManager.default.contentsOfDirectory(at: homeAgents, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "md" {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let spec = try? AgentMarkdownParser.parse(text: text, source: "custom") {
                    map[spec.id] = spec
                }
            }
        }
        // Ensure minimal defaults always exist
        for spec in AgentCatalog.builtinDefaults() {
            if map[spec.id] == nil { map[spec.id] = spec }
        }
        cache = Dictionary(uniqueKeysWithValues: map.sorted { $0.key < $1.key }
            .prefix(Self.maximumEntries)
            .map { ($0.key, $0.value) })
    }

    public func all() -> [AgentSpec] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.sorted { $0.id < $1.id }
    }

    public func get(_ id: String) -> AgentSpec? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    public func recommend(task: String) -> AgentSpec {
        let t = task.lowercased()
        let rules: [(String, [String])] = [
            ("precommit-audit", ["commit", "precommit", "pull request", "pr ", "ok_to_commit"]),
            ("security", ["security", "auth", "secret", "injection"]),
            ("debug", ["debug", "crash", "traceback", "exception", "failing"]),
            ("test", ["test", "pytest", "coverage"]),
            ("docs", ["docs", "readme", "pdf", "manual", "handbook", "runbook", "documentation"]),
            ("research", ["research", "web search", "http"]),
            ("review", ["review", "critique"]),
            ("plan", ["plan", "design", "architecture"]),
            ("explore", ["explore", "map", "codebase", "structure", "overview", "unfamiliar"]),
            ("implement", ["implement", "feature", "bugfix", "write code", "edit"]),
        ]
        for (id, keys) in rules {
            if keys.contains(where: { t.contains($0) }), let spec = get(id) {
                return spec
            }
        }
        return get("explore") ?? AgentCatalog.builtinDefaults()[0]
    }

    private func bundledAgentsFallback() -> [AgentSpec] {
        // Compile-time defaults if resources not yet copied
        AgentCatalog.builtinDefaults()
    }

    public static func builtinDefaults() -> [AgentSpec] {
        [
            AgentSpec(
                id: "explore",
                displayName: "Explore",
                description: "Map a codebase and report structure, entry points, build/test, risks, and next specialist.",
                tools: ["fs_list", "fs_read", "fs_glob", "search_text", "git_status", "git_log", "git_diff", "shell_exec"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "fs_move", "git_commit", "git_push", "git_add"],
                whenToUse: ["Unfamiliar repository", "Need structure map before plan/implement"],
                firstMoves: ["fs_list root", "locate Package.swift/xcodeproj", "git_status", "read entry points", "agent_run_complete"],
                doneDefinition: ["Layout + entry points with real paths", "build_test_run identified", "agent_run_complete"],
                outputSchema: ["layout", "entry_points", "build_test_run", "dependencies_config", "risks", "next_agent"],
                handoff: ["plan", "implement", "debug"],
                qualityBar: ["Paths verified via tools", "Never invent file names", "Always agent_run_complete"],
                body: """
                You are Explore (read-only). Map the codebase with tool-verified paths.
                Never mutate files. Always call agent_run_complete with layout, entry_points,
                build_test_run, dependencies_config, risks, next_agent.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "implement",
                displayName: "Implement",
                description: "Implement features and bugfixes with focused, verified code changes.",
                tools: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "git_status", "git_diff", "git_add", "git_commit", "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator", "job.status", "job.read_output", "job.cancel", "job.list"],
                toolsForbidden: ["git_push"],
                whenToUse: ["Feature or bugfix with known scope"],
                firstMoves: ["fs_read surrounding code", "minimal edit", "xcode.run relevant Xcode tests or build, or shell_exec for other runners", "poll job.status to terminal and read job.read_output; xcode.result test_summary verifies actual test counts", "agent_run_complete"],
                doneDefinition: ["Change on disk", "how_to_verify concrete", "agent_run_complete"],
                outputSchema: ["what_changed", "files_touched", "how_to_verify", "residual_risks"],
                handoff: ["test", "review", "precommit-audit"],
                qualityBar: ["Smallest correct change", "Match modularity", "Always agent_run_complete"],
                body: """
                You are Implement. Read before write. Prefer fs_edit for surgical patches.
                Use xcode.discover and xcode.run for Xcode; poll job.status to a terminal result
                and read job.read_output. For tests inspect xcode.result test_summary and actual
                test counts. build-for-testing compiles tests but does not execute them; zero
                selected tests, skips, a timeout, or a job receipt is not a pass. shell_exec
                remains available for direct native commands and other runners.
                Do not git_push. Always agent_run_complete with what_changed, files_touched,
                how_to_verify, residual_risks.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "docs",
                displayName: "Docs",
                description: "Write Markdown documentation and export PDF manuals, plain-text DOCX, text-only XLSX/ODS, text-slide PPTX or PNG/TIFF/JPEG/GIF/WebP/BMP/ICO pixel artifacts and supplied-entry ZIP/TAR/tar.gz archives and supplied PCM16 WAV/FLAC audio via native tools.",
                tools: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "pdf_write", "pdf_from_file", "docx_write", "xlsx_write", "pptx_write", "ods_write", "image_write", "archive_write", "audio_write", "git_status", "git_diff", "git_log", "runtime.capabilities", "python.run", "job.status", "job.read_output", "job.cancel", "job.list"],
                toolsForbidden: ["git_push", "git_commit"],
                whenToUse: ["README", "PDF manual", "plain-text DOCX", "text-only XLSX", "text-only ODS", "text-slide PPTX", "PNG pixel artifact", "TIFF pixel artifact", "WebP pixel artifact", "BMP pixel artifact", "ICO pixel artifact", "supplied-entry ZIP/TAR/tar.gz", "PCM16 WAV audio", "PCM16 FLAC audio", "runbook", "API docs"],
                firstMoves: ["fs_glob docs/README", "fs_read sources", "fs_write markdown", "pdf_from_file if needed", "agent_run_complete"],
                doneDefinition: ["Artifacts on disk", "files_touched filled", "agent_run_complete"],
                outputSchema: ["files_touched", "summary", "formats", "how_to_open"],
                handoff: ["review"],
                qualityBar: ["No aspirational docs", "Prefer pdf_write over inventing pandoc", "Always agent_run_complete"],
                body: """
                You are Docs. Write accurate documentation with tools.
                For plain-text DOCX use docx_write(path="<project>/docs/PROJECT_MANUAL.docx",
                content="..."). Content is limited to 65536 UTF-8 bytes and encoded output
                to 1048576 bytes. CRLF, CR and U+2029 normalize to LF; native paragraph
                terminators can add a final LF on import. XML 1.0-disallowed scalars are
                rejected. This tool does not interpret Markdown or promise layout,
                images or Office-suite fidelity. Report exact tool errors when blocked.
                For a text-only worksheet use xlsx_write(path="<project>/docs/TABLE.xlsx",
                rows=[["Heading", "Value"], ["Item", "text"]]). Use at most 256 rows,
                64 columns per row, 4096 cells, 4096 UTF-8 bytes per cell and 65536 total
                cell UTF-8 bytes; encoded output is limited to 1048576 bytes. Empty rows
                and cells are accepted. Literal cell text is preserved without line
                normalization; formula-like strings remain text. XML 1.0-disallowed
                scalars are rejected. Do not promise formulas, formatting, images or
                Office-suite fidelity.
                For a text-only ODF worksheet use ods_write(path="<project>/docs/TABLE.ods",
                rows=[["Heading", "Value"], ["Item", "text"]]). The same input dimensions
                and text byte limits apply, with at most 32768 XML elements and 1048576
                encoded bytes. CRLF and CR normalize to LF; explicit space, tab and line
                break markers preserve whitespace. Literal _x0041_ and formula-like
                strings remain text. Empty rows/cells use required structural padding.
                Do not promise formulas, formatting, images or Office-suite fidelity.
                For text slides use pptx_write(path="<project>/docs/DECK.pptx",
                slides=[{"title":"Heading","paragraphs":["Body"]}]). Use 1 to 32 slides,
                at most 1024 paragraphs including nonempty titles, 4096 UTF-8 bytes per
                title or paragraph and 65536 total text bytes; encoded output is limited
                to 1048576 bytes. CRLF and CR normalize to LF; embedded LF is a soft
                break. Literal _x0041_ text is preserved. Do not promise images,
                visual fit or Office-suite fidelity.
                For PCM16 WAV use audio_write(path="<project>/docs/AUDIO.wav", content="AAA=",
                sample_rate=8000, channels=1). Supply signed little-endian PCM16 samples,
                frame-major with left/right interleaving for stereo. Rates are 8000,
                44100 or 48000; channels are 1 or 2. Nonempty complete frames are required.
                The writer admits at most 1048576 decoded PCM bytes. WAV remains the
                absent-format default and emits exactly 44 + PCM bytes. For lossless
                verbatim FLAC use format="flac" and an explicit .flac path; format="wav"
                is also accepted. FLAC output is at most 2097152 bytes, with exact PCM
                MD5 and frame CRCs. No format is inferred from the extension. Managed
                calls retain their 65536-byte canonical JSON argument bound.
                Use its own audio_write grant. No codec conversion,
                source-file reads, synthesis or playback is provided.
                For supplied files use archive_write(path="<project>/docs/FILES.zip",
                entries=[{"name":"notes.txt","content":"SGVsbG8="}]). Use 0 to 32
                virtual file entries with exact NFC relative UTF-8 names, at most 1024
                bytes/name and 255 bytes/component; no host source paths are read.
                Preserve entry order and bytes. Each content is canonical padded
                base64, with at most 1048576 aggregate decoded bytes and 2097152
                complete output bytes. These writer ceilings do not raise managed
                calls' existing 65536-byte canonical JSON argument bound. Duplicate,
                case-insensitive and ancestor-file conflicts are rejected. Output
                defaults to stored method 0 ZIP with fixed timestamps. Use format="tar"
                with an explicit .tar path for deterministic PAX TAR, or format="tar.gz"
                with an explicit .tar.gz path for one GZIP-wrapped PAX TAR. No format
                is inferred from the extension. No standalone raw-file GZIP, extraction
                or portable filesystem collision guarantee. Use its own grant.
                For PNG pixels use image_write(path="<project>/docs/IMAGE.png", width=1,
                height=1, content="/wAA/w=="). Supply canonical padded base64 straight
                RGBA8 sRGB bytes, tightly packed in top-to-bottom row-major order:
                width/height 1 to 1024, at most 262144 pixels and 1048576 decoded bytes.
                Base64 is limited to 1398104 characters; encoded output to 2097152 bytes.
                pixel_format accepts only "rgba8"; absent format defaults to "png".
                For TIFF use format="tiff" and an explicit .tif or .tiff path; pixels
                retain the same straight RGBA8 sRGB contract. For JPEG use format="jpeg"
                and an explicit .jpg or .jpeg path; every alpha byte must be 255.
                JPEG uses fixed quality 1.0 with lossy output; decoded RGB may differ.
                Its output_contract is jpeg-opaque-lossy-srgb-v1, while pixel_contract
                describes the supplied bytes. For GIF use format="gif" and an explicit
                .gif path; every alpha byte must be 0 or 255. Partial alpha is rejected.
                GIF palette encoding may change RGB; hidden transparent RGB is not
                preserved. Its output_contract is gif-binary-alpha-palettized-srgb-v1.
                GIF is one image, with no animation or embedded ICC guarantee.
                For WebP use exact lowercase format="webp" with an explicit .webp
                destination. The native Swift lossless VP8L writer preserves every
                supplied RGBA byte, including alpha 0...255 and hidden RGB, in the
                encoded stream. Native premultiplied rendering is separate. Its
                output_contract is webp-lossless-rgba8-srgb-v1 and engine is
                swift-webp-vp8l. One sRGB-interpreted image; no animation or embedded
                ICC guarantee. For BMP use exact lowercase format="bmp" with an
                explicit .bmp destination. The ImageIO writer produces one 32-bit
                top-down V5/BITFIELDS image, preserving supplied straight RGBA8
                channels with an sRGB marker. Native premultiplied rendering is
                separate; no embedded ICC or Windows interoperability guarantee.
                For ICO use exact lowercase format="ico" with an explicit .ico path.
                Width and height must be equal and one of 16, 32, 48 or 256. The
                swift-ico-dib32 writer produces one bottom-up 32-bit BI_RGB DIB and
                DWORD-padded AND rows, with bits 1 exactly at source alpha zero.
                Encoded pixels retain every supplied RGBA byte, including alpha
                0...255 and hidden RGB. Native premultiplied rendering is separate.
                Its output_contract is ico-dib32-rgba8-srgb-v1; no embedded ICC or
                Windows interoperability guarantee.
                Destination extensions are case-insensitive.
                Report the actual destination and result;
                this tool encodes supplied pixels.
                For PDF use pdf_write / pdf_from_file (no pandoc). Always fill files_touched
                and call agent_run_complete. Never claim PDF done without a file on disk.
                Find filenames with fs_glob(pattern="*.md", path="<project>/docs");
                patterns match filenames, not relative paths. For test or analysis scripts,
                check runtime.capabilities before optional python.run(script="...",
                replay_class="read_only"); choose the replay class that matches the effects.
                Poll job.status to terminal, read job.read_output, and cancel abandoned work.
                An unavailable interpreter or a job receipt does not prove completion.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "debug",
                displayName: "Debug",
                description: "Diagnose failures from logs, stack traces, and failing tests with evidence.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "shell_exec", "git_status", "git_diff", "git_log", "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator", "job.status", "job.read_output", "job.cancel", "job.list", "runtime.capabilities", "python.run"],
                toolsForbidden: ["git_push"],
                whenToUse: ["Failing tests", "crashes", "unexpected behavior"],
                firstMoves: ["Capture exact error", "trace path with fs_read/search_text", "xcode.run reproducer; poll job.status to terminal and read job.read_output", "xcode.result test_summary verifies actual test counts; build-for-testing only compiles", "agent_run_complete"],
                doneDefinition: ["Root cause with evidence", "agent_run_complete"],
                outputSchema: ["symptom", "repro", "root_cause", "fix", "verify"],
                handoff: ["test", "implement", "review"],
                qualityBar: ["Evidence before large rewrites", "Always agent_run_complete"],
                body: """
                You are Debug. Find root causes with evidence (log lines, exit codes, paths).
                Use xcode.discover, xcode.run, and owner-authorized batch LLDB via xcode.debug.
                Poll job.status to terminal and read job.read_output; inspect xcode.result
                test_summary for actual test counts. build-for-testing does not execute XCTest.
                A receipt, zero selected tests, skips, or timeout is not a pass. shell_exec
                remains available for direct native commands and other runners.
                Find filenames with fs_glob(pattern="*.swift", path="<project>").
                For test or analysis scripts, check runtime.capabilities before optional
                python.run(script="...", replay_class="read_only"); choose the replay class
                that matches the effects. Interpreter unavailability is not a successful run.
                Fill symptom, repro, root_cause, fix, verify. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "precommit-audit",
                displayName: "Pre-commit Audit",
                description: "Mandatory audit before git commit or PR — gate on OK_TO_COMMIT.",
                tools: ["git_status", "git_diff", "git_log", "fs_read", "search_text", "fs_glob", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push"],
                whenToUse: ["Before every commit", "Before PR"],
                firstMoves: ["git_status", "git_diff staged+unstaged", "scan secrets", "agent_run_complete"],
                doneDefinition: ["OK_TO_COMMIT yes/no", "blockers listed", "agent_run_complete"],
                outputSchema: ["diff_summary", "risks", "OK_TO_COMMIT", "blockers"],
                handoff: ["implement"],
                qualityBar: ["Block on secrets", "Always agent_run_complete"],
                body: """
                You are Pre-commit Audit. Never commit. Always agent_run_complete with
                diff_summary, risks, OK_TO_COMMIT (yes|no), blockers.
                Find filenames with fs_glob(pattern="*.swift", path="<project>");
                patterns match filenames. Use search_text for file contents.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "plan",
                displayName: "Plan",
                description: "Design multi-step implementation plans with files, risks, and verification.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "git_status", "git_log", "shell_exec"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "git_commit", "git_push", "git_add"],
                whenToUse: ["Architecture or multi-file feature design"],
                firstMoves: ["Map modules", "read key interfaces", "agent_run_complete"],
                doneDefinition: ["Ordered steps + files + verify", "agent_run_complete"],
                outputSchema: ["goal", "steps", "files", "risks", "verify", "next_agent"],
                handoff: ["implement", "explore"],
                qualityBar: ["Actionable ordered steps", "Always agent_run_complete"],
                body: """
                You are Plan (no production code writes). Produce goal, steps, files, risks,
                verify, next_agent. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "review",
                displayName: "Review",
                description: "Review diffs for correctness, security, tests, and maintainability.",
                tools: ["git_status", "git_diff", "git_log", "fs_read", "search_text", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push", "fs_write", "fs_edit", "fs_delete"],
                whenToUse: ["After implementation before merge"],
                firstMoves: ["git_diff", "fs_read high-risk hunks", "agent_run_complete"],
                doneDefinition: ["Verdict approve|request_changes", "agent_run_complete"],
                outputSchema: ["summary", "blockers", "nits", "test_gaps", "security", "verdict"],
                handoff: ["implement", "test", "precommit-audit"],
                qualityBar: ["Path-specific blockers", "Always agent_run_complete"],
                body: """
                You are Review (read-only). Separate blockers from nits. Cover security and
                test_gaps. Verdict: approve or request_changes. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "test",
                displayName: "Test",
                description: "Discover, run, and report verification; identify coverage gaps.",
                tools: ["shell_exec", "fs_read", "fs_list", "fs_glob", "search_text", "git_status", "xcode.discover", "xcode.run", "xcode.result", "xcode.debug", "xcode.simulator", "job.status", "job.read_output", "job.cancel", "job.list"],
                toolsForbidden: ["git_push", "git_commit"],
                whenToUse: ["Need evidence tests pass/fail", "Improve verification"],
                firstMoves: ["Discover test runner with xcode.discover or shell_exec", "xcode.run action test for a targeted Xcode suite", "poll job.status to terminal and read job.read_output; xcode.result test_summary verifies actual test counts", "agent_run_complete"],
                doneDefinition: ["Commands and results recorded", "agent_run_complete"],
                outputSchema: ["commands", "results", "gaps", "follow_ups"],
                handoff: ["implement", "debug"],
                qualityBar: ["Never invent pass/fail", "Always agent_run_complete"],
                body: """
                You are Test. Use xcode.discover and xcode.run action test for Xcode. Poll
                job.status to a terminal result and read job.read_output. Inspect xcode.result
                test_summary for actual test counts and failures. build-for-testing compiles
                tests but does not execute them. A job receipt, zero selected tests, skips, or
                timeout is not a pass. shell_exec remains available for direct native commands
                and swift test / npm test / pytest. Always agent_run_complete
                with commands, results, gaps, follow_ups.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "security",
                displayName: "Security",
                description: "Threat-model changes; scan for secrets, injection, and unsafe patterns.",
                tools: ["git_status", "git_diff", "fs_read", "fs_glob", "search_text", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push", "fs_write", "fs_edit", "fs_delete"],
                whenToUse: ["Auth/secrets/network/shell changes", "Pre-release security pass"],
                firstMoves: ["git_diff for attack surface", "search_text for secrets/injection", "agent_run_complete"],
                doneDefinition: ["Findings ranked", "Remediations listed", "agent_run_complete"],
                outputSchema: ["scope", "findings", "severity_summary", "remediations", "residual_risk"],
                handoff: ["implement", "precommit-audit", "review"],
                qualityBar: ["Concrete exploit paths", "Never print live secrets", "Always agent_run_complete"],
                body: """
                You are Security. Read-only analysis. Rank findings critical/high/medium/low/info.
                Check secrets, injection, path traversal, SSRF, authz gaps. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "research",
                displayName: "Research",
                description: "Gather facts from the local codebase with path citations.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "git_log", "git_status", "shell_exec", "web.search", "web.fetch", "web.render"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "git_commit", "git_push"],
                whenToUse: ["Factual question about how the system works"],
                firstMoves: ["search_text / fs_glob", "fs_read sources", "agent_run_complete"],
                doneDefinition: ["Answer with citations", "Uncertainties listed", "agent_run_complete"],
                outputSchema: ["question", "findings", "citations", "uncertainties", "next_agent"],
                handoff: ["plan", "implement", "docs"],
                qualityBar: ["Every claim needs path evidence", "Always agent_run_complete"],
                body: """
                You are Research. Prefer repository evidence over general knowledge.
                Cite paths. Separate fact from inference. Always agent_run_complete.
                """,
                source: "builtin"
            ),
        ]
    }
}

// MARK: - Markdown frontmatter parser

public enum AgentMarkdownParser {
    public static func parse(text: String, source: String) throws -> AgentSpec {
        guard text.hasPrefix("---") else {
            throw NSError(domain: "AgentMarkdown", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Agent markdown must start with YAML frontmatter",
            ])
        }
        let parts = text.components(separatedBy: "---")
        // ["", frontmatter, body...]
        guard parts.count >= 3 else {
            throw NSError(domain: "AgentMarkdown", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid frontmatter fences",
            ])
        }
        let fm = parts[1]
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = SimpleYAML.map(from: fm)
        guard let id = meta["id"], !id.isEmpty else {
            throw NSError(domain: "AgentMarkdown", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "frontmatter requires id",
            ])
        }
        return AgentSpec(
            id: id,
            displayName: meta["display_name"] ?? id,
            description: meta["description"] ?? "",
            tools: list(meta["tools"]),
            toolsForbidden: list(meta["tools_forbidden"]),
            whenToUse: list(meta["when_to_use"]),
            firstMoves: list(meta["first_moves"]),
            doneDefinition: list(meta["done_definition"]),
            outputSchema: list(meta["output_schema"]),
            handoff: list(meta["handoff"]),
            qualityBar: list(meta["quality_bar"]),
            body: body,
            source: source
        )
    }

    private static func list(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        // bracket list or comma list
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") && s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
    }
}

/// Tiny subset YAML: key: value lines only (no nested structures beyond lists as strings).
enum SimpleYAML {
    static func map(from text: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""
        func flush() {
            if let k = currentKey {
                out[k] = currentVal.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            currentVal = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            if let r = line.range(of: ":"), !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") {
                flush()
                let k = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix(">") || v.hasPrefix("|") { v = "" }
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                currentKey = k
                currentVal = v
            } else if currentKey != nil {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") {
                    let item = String(t.dropFirst(2))
                    if currentVal.isEmpty { currentVal = item }
                    else if currentVal.hasPrefix("[") {
                        // already bracket form
                        currentVal = String(currentVal.dropLast()) + ", " + item + "]"
                    } else {
                        currentVal += ", " + item
                    }
                } else if !t.isEmpty {
                    currentVal += " " + t
                }
            }
        }
        flush()
        return out
    }
}
