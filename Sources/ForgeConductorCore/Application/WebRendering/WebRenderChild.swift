import AppKit
import Darwin
import Foundation
import Synchronization
import WebKit

/// A fixed mode of the existing signed CLI/app, recognized before their normal bootstraps.
public enum WebRenderChildEntry {
    public nonisolated static func runIfRequested(arguments: [String] = CommandLine.arguments,
                                      expectedRole: WebRenderProductRole) -> Bool {
        guard arguments.dropFirst().first == WebRenderProtocol.internalArgument else { return false }
        // Matching malformed calls are consumed here; they must never fall through to GUI.
        guard arguments.count == 2, Thread.isMainThread else { exit(2) }
        guard #available(macOS 27.0, *) else { exit(3) }
        let entry = DispatchTime.now().uptimeNanoseconds
        let upperEnd = entry + 30_000_000_000
        let inputEnd = entry + 2_000_000_000
        let input = Mutex<InputState>(.pending)
        let output = Mutex<OutputState>(.pending)
        let cancellation = ToolCallCancellation(timeoutSeconds: 30)
        DispatchQueue.global(qos: .utility).async {
            do {
                try validateSelf(expectedRole)
                let data = try readInput(end: inputEnd, cancellation: cancellation)
                let request = try WebRenderProtocol.decodeRequestFrame(data)
                let now = DispatchTime.now().uptimeNanoseconds
                guard request.deadlineUptimeNanoseconds > now,
                      request.deadlineUptimeNanoseconds <= upperEnd else { throw WebRenderError.deadline }
                input.withLock { $0 = .ready(request) }
            } catch { input.withLock { $0 = .failed } }
        }
        var request: WebRenderProtocol.Request?
        while request == nil, DispatchTime.now().uptimeNanoseconds < inputEnd, !cancellation.isCancelled {
            switch input.withLock({ $0 }) {
            case .pending: break
            case .failed: exit(2)
            case .ready(let ready): request = ready
            }
            if request == nil { autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) } }
        }
        guard let request, !cancellation.isCancelled else { exit(2) }
        let end = min(upperEnd, request.deadlineUptimeNanoseconds)
        let owner = MainActor.assumeIsolated { WebRenderChildOwner(cancellation: cancellation) }
        MainActor.assumeIsolated {
            autoreleasepool {
                owner.start(request) { reply in
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let frame = try boundedFrame(reply, matching: request)
                            let success = try writeOutput(frame, end: end > 1_500_000_000 ? end - 1_500_000_000 : 0)
                            output.withLock { $0 = .complete(success) }
                        } catch { output.withLock { $0 = .complete(false) } }
                    }
                }
            }
        }
        while DispatchTime.now().uptimeNanoseconds < end {
            if case .complete(let success) = output.withLock({ $0 }) {
                MainActor.assumeIsolated { owner.stop() }
                exit(success ? 0 : 2)
            }
            autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        }
        MainActor.assumeIsolated { owner.stop() }
        exit(2)
    }

    private enum InputState: Sendable { case pending, ready(WebRenderProtocol.Request), failed }
    private enum OutputState: Sendable { case pending, complete(Bool) }

    private static func validateSelf(_ role: WebRenderProductRole) throws {
        let expected: OwnedNativeExecutableRole = role == .cli ? .cli : .app
        _ = try OwnedCurrentSelfAdmission.current(expectedRole: expected)
        // Exact owned-child/current-parent-main admission belongs to ProcessRunner.
        // No whole-product or mapped-Core attestation is inferred from this role check.
    }

    private static func readInput(end: UInt64, cancellation: ToolCallCancellation) throws -> Data {
        defer { Darwin.close(STDIN_FILENO) }
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw WebRenderError.transportFailed
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
        while DispatchTime.now().uptimeNanoseconds < end {
            try cancellation.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count == 0 {
                _ = try WebRenderProtocol.body(result, maximumBodyBytes: WebRenderProtocol.maximumRequestBodyBytes)
                return result // Actual EOF, not an expected-length approximation.
            }
            if count > 0 {
                guard result.count + count <= WebRenderProtocol.maximumRequestBodyBytes + 4 else {
                    throw WebRenderProtocolError.invalidFrame
                }
                result.append(contentsOf: buffer.prefix(count))
                if result.count >= 4 {
                    let header = Array(result.prefix(4))
                    let size = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
                    guard size > 0, size <= WebRenderProtocol.maximumRequestBodyBytes,
                          result.count <= size + 4 else { throw WebRenderProtocolError.invalidFrame }
                }
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw WebRenderError.transportFailed
            } else {
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 20)
            }
        }
        throw WebRenderError.deadline
    }

    private static func writeOutput(_ data: Data, end: UInt64) throws -> Bool {
        defer { Darwin.close(STDOUT_FILENO); Darwin.close(STDERR_FILENO) }
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else { throw WebRenderError.transportFailed }
        var sent = 0
        while sent < data.count, DispatchTime.now().uptimeNanoseconds < end {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: sent), min(16_384, data.count - sent))
            }
            if count > 0 { sent += count }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 20)
            } else { return false }
        }
        return sent == data.count
    }

    private static func boundedFrame(_ reply: WebRenderProtocol.Reply,
                                     matching request: WebRenderProtocol.Request) throws -> Data {
        var candidate = reply
        for _ in 0...14 {
            if let frame = try? WebRenderProtocol.encodeReply(candidate, matching: request) { return frame }
            guard !candidate.text.isEmpty else { throw WebRenderError.invalidResponse }
            candidate = candidate.replacingText(WebRenderProtocol.prefixUTF8(candidate.text, bytes: candidate.text.utf8.count / 2))
        }
        throw WebRenderError.invalidResponse
    }
}

@available(macOS 27.0, *)
@MainActor
private final class WebRenderChildOwner {
    private let cancellation: ToolCallCancellation
    private var signalSource: DispatchSourceSignal?
    private var session: WebRenderSession?

    init(cancellation: ToolCallCancellation) {
        self.cancellation = cancellation
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        signal(SIGTERM, SIG_IGN) // This fixed child only; never the serving parent.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.cancellation.cancel()
                self?.session?.finish(.cancelled)
            }
        }
        signalSource = source
        source.resume()
    }

    func start(_ request: WebRenderProtocol.Request,
               completion: @escaping @Sendable (WebRenderProtocol.Reply) -> Void) {
        session = WebRenderSession(request: request, completion: completion)
        if cancellation.isCancelled { session?.finish(.cancelled) }
    }
    func stop() { signalSource?.cancel(); signalSource = nil; session?.discard(); session = nil }
}

@available(macOS 27.0, *)
@MainActor
private final class WebRenderSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let request: WebRenderProtocol.Request
    private let completion: @Sendable (WebRenderProtocol.Reply) -> Void
    private var view: WKWebView?
    private var store: WKWebsiteDataStore?
    private weak var weakView: WKWebView?
    private weak var weakStore: WKWebsiteDataStore?
    private var deadline: DispatchWorkItem?
    private var pollWork: DispatchWorkItem?
    private var completing = false
    private var inFlight = false
    private var lockdownReadback = false
    private var navigationGeneration = 0
    private var currentNavigation: WKNavigation?
    private var navigationCount = 0
    private var redirects = 0
    private var admissionNavigations: [ObjectIdentifier: WKNavigation] = [:]
    private var admittedURLs: [ObjectIdentifier: Set<String>] = [:]
    private var committedNavigations: Set<ObjectIdentifier> = []
    private var followUpAdmissions = 0
    private var loadedAt: UInt64?
    private var previousSample: String?
    private var stableSamples = 0
    private var releaseEnd: UInt64 = 0
    private var finalReply: WebRenderProtocol.Reply?

    init(request: WebRenderProtocol.Request, completion: @escaping @Sendable (WebRenderProtocol.Reply) -> Void) {
        self.request = request
        self.completion = completion
        super.init()
        let now = DispatchTime.now().uptimeNanoseconds
        guard request.deadlineUptimeNanoseconds > now + 2_500_000_000 else { finish(.deadline); return }
        let configuration = WKWebViewConfiguration()
        let freshStore = WKWebsiteDataStore.nonPersistent()
        store = freshStore; weakStore = freshStore
        configuration.websiteDataStore = freshStore
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
        configuration.defaultWebpagePreferences.securityRestrictionMode = .lockdown
        lockdownReadback = configuration.defaultWebpagePreferences.isLockdownModeEnabled
            && configuration.defaultWebpagePreferences.securityRestrictionMode == .lockdown
        guard lockdownReadback else { finish(.unsupported); return }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        view = webView; weakView = webView
        webView.navigationDelegate = self; webView.uiDelegate = self
        let work = DispatchWorkItem { [weak self] in self?.finish(.deadline) }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: request.deadlineUptimeNanoseconds - 2_500_000_000), execute: work)
        guard let url = try? WebRenderProtocol.validatedURL(request.url) else { finish(.protocolError); return }
        currentNavigation = webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Double(request.deadlineUptimeNanoseconds - now) / 1_000_000_000))
    }

    func discard() {
        deadline?.cancel(); deadline = nil; pollWork?.cancel(); pollWork = nil
        currentNavigation = nil
        admissionNavigations.removeAll(); admittedURLs.removeAll(); committedNavigations.removeAll()
        view?.stopLoading(); view?.navigationDelegate = nil; view?.uiDelegate = nil
        view?.removeFromSuperview(); view = nil; store = nil
    }

    func finish(_ outcome: WebRenderProtocol.Outcome, snapshot: DOMSnapshot? = nil,
                readiness: WebRenderProtocol.Readiness = .unavailable) {
        guard !completing else { return }
        completing = true
        let hadView = view != nil, hadStore = store != nil
        let observedURL = view?.url?.absoluteString
        let finalURL = observedURL.flatMap { try? WebRenderProtocol.validatedURL($0).absoluteString } ?? ""
        finalReply = WebRenderProtocol.Reply(requestID: request.requestID, nonce: request.nonce,
            projectID: request.projectID, projectGeneration: request.projectGeneration, outcome: outcome,
            finalURL: finalURL, title: snapshot?.title ?? "", text: snapshot?.text ?? "",
            nodesVisited: snapshot?.nodes ?? 0, textTruncated: snapshot?.truncated ?? false,
            titleTruncated: snapshot?.titleTruncated ?? false, readiness: readiness,
            snapshotExtracted: snapshot != nil, lockdownEnabled: lockdownReadback,
            viewLifetime: hadView ? .notObserved : .notCreated,
            storeLifetime: hadStore ? .notObserved : .notCreated)
        discard()
        releaseEnd = min(DispatchTime.now().uptimeNanoseconds + 500_000_000,
            request.deadlineUptimeNanoseconds > 1_750_000_000 ? request.deadlineUptimeNanoseconds - 1_750_000_000 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.completeRelease() }
    }

    private func completeRelease() {
        guard let reply = finalReply else { return }
        if (weakView != nil || weakStore != nil), DispatchTime.now().uptimeNanoseconds < releaseEnd {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.completeRelease() }
            return
        }
        finalReply = nil // One terminal completion; stale extraction callbacks are ignored.
        completion(reply.replacingLifetime(
            view: reply.viewLifetime == .notCreated ? .notCreated : (weakView == nil ? .released : .unreleasedAtDeadline),
            store: reply.storeLifetime == .notCreated ? .notCreated : (weakStore == nil ? .released : .unreleasedAtDeadline)))
    }

    private func pollDOM() {
        guard !completing, !inFlight, let view, let loadedAt else { return }
        inFlight = true
        let generation = navigationGeneration
        view.evaluateJavaScript(Self.extractor, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            guard !self.completing else { return }
            guard generation == self.navigationGeneration else { self.pollDOM(); return }
            guard case .success(let value) = result, let raw = value as? String,
                  raw.utf8.count <= 16_384, let data = raw.data(using: .utf8),
                  let snapshot = try? DOMSnapshot(data) else { self.finish(.navigationFailed); return }
            self.stableSamples = self.previousSample == raw ? min(2, self.stableSamples + 1) : 1
            self.previousSample = raw
            let elapsed = DispatchTime.now().uptimeNanoseconds - loadedAt
            if elapsed >= 500_000_000 && self.stableSamples >= 2 || elapsed >= 2_000_000_000 {
                self.finish(.rendered, snapshot: snapshot,
                            readiness: elapsed >= 2_000_000_000 ? .maximumSettle : .boundedStability)
            } else {
                let work = DispatchWorkItem { [weak self] in self?.pollDOM() }
                self.pollWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
            }
        }
    }

    struct DOMSnapshot {
        let title: String, text: String
        let nodes: Int
        let truncated: Bool, titleTruncated: Bool
        init(_ data: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["title", "text", "nodes", "truncated", "title_truncated"],
                  let title = object["title"] as? String, title.utf8.count <= 512,
                  let text = object["text"] as? String, text.utf8.count <= 8_192,
                  let nodes = object["nodes"] as? NSNumber, CFGetTypeID(nodes) != CFBooleanGetTypeID(),
                  let nodeCount = Int(exactly: nodes.doubleValue), (0...4_096).contains(nodeCount),
                  let truncated = object["truncated"] as? NSNumber, CFGetTypeID(truncated) == CFBooleanGetTypeID(),
                  let titleTruncated = object["title_truncated"] as? NSNumber, CFGetTypeID(titleTruncated) == CFBooleanGetTypeID() else {
                throw WebRenderError.invalidResponse
            }
            self.title = title; self.text = text; self.nodes = nodeCount
            self.truncated = truncated.boolValue; self.titleTruncated = titleTruncated.boolValue
        }
    }

    private static let extractor = """
    (()=>{const enc=new TextEncoder(),dec=new TextDecoder('utf-8'),cap=8192;
      function take(raw,max){let s=dec.decode(enc.encode(raw.slice(0,Math.max(0,max))));let lo=0,hi=s.length;
        while(lo<hi){let mid=Math.floor((lo+hi+1)/2),p=s.slice(0,mid);if(/[\\uD800-\\uDBFF]$/.test(p))p=p.slice(0,-1);
          if(enc.encode(p).length<=max)lo=mid;else hi=mid-1;}let p=s.slice(0,lo);if(/[\\uD800-\\uDBFF]$/.test(p))p=p.slice(0,-1);return p;}
      let text='',bytes=0,nodes=0,truncated=false;const root=document.body||document.documentElement||document;
      let node=root;while(node){if(nodes===4096){truncated=true;break;}nodes++;
        const excluded=node.nodeType===1&&['script','style','noscript','template'].includes(node.localName);
        if(node.nodeType===3){const raw=node.data,part=take(raw,Math.min(cap-bytes,4096));text+=part;bytes+=enc.encode(part).length;
          if(part.length<raw.length||bytes>=cap){truncated=true;break;}}
        if(!excluded&&node.firstChild){node=node.firstChild;continue;}
        let climbs=0;while(node!==root&&!node.nextSibling){if(climbs++===4096){truncated=true;break;}node=node.parentNode;if(!node)break;}
        if(climbs>4096||!node){truncated=true;break;}node=node===root?null:node.nextSibling;}
      const title=take(document.title,512),titleTruncated=title.length<document.title.length;
      function pack(t,cut){return JSON.stringify({title,text:t,nodes,truncated:truncated||cut,title_truncated:titleTruncated});}
      let out=pack(text,false);if(enc.encode(out).length>16384){let lo=0,hi=bytes;
        while(lo<hi){let mid=Math.floor((lo+hi+1)/2);if(enc.encode(pack(take(text,mid),true)).length<=16384)lo=mid;else hi=mid-1;}
        out=pack(take(text,lo),true);}return out;})()
    """

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard !completing, preferences.isLockdownModeEnabled, preferences.securityRestrictionMode == .lockdown,
              preferences.allowsContentJavaScript else {
            decisionHandler(.cancel, preferences); if !completing { finish(.unsupported) }; return
        }
        guard let url = action.request.url, (try? WebRenderProtocol.validatedURL(url.absoluteString)) != nil,
              action.targetFrame != nil, !action.shouldPerformDownload else {
            decisionHandler(.cancel, preferences); return
        }
        if action.targetFrame?.isMainFrame == true {
            guard let navigation = action.mainFrameNavigation else {
                decisionHandler(.cancel, preferences); finish(.navigationFailed); return
            }
            let key = ObjectIdentifier(navigation)
            guard admissionNavigations[key] != nil || admissionNavigations.count < 16 else {
                decisionHandler(.cancel, preferences); finish(.navigationFailed); return
            }
            if !committedNavigations.contains(key) {
                let previous = admittedURLs[key, default: []]
                // Repeated provisional URLs can bypass later WebKit policy callbacks.
                // This also denies finite cookie/state redirects to the same URL.
                guard !previous.contains(url.absoluteString), previous.isEmpty || followUpAdmissions < 5 else {
                    decisionHandler(.cancel, preferences); finish(.redirectLimit); return
                }
                if !previous.isEmpty { followUpAdmissions += 1 }
                admittedURLs[key, default: []].insert(url.absoluteString)
            }
            admissionNavigations[key] = navigation
        }
        decisionHandler(.allow, preferences)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard !completing else { decisionHandler(.cancel); return }
        let attachment = WebRenderProtocol.isAttachmentDisposition(
            (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition"))
        if !response.canShowMIMEType || attachment {
            decisionHandler(.cancel); if response.isForMainFrame { finish(.downloadDenied) }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !completing else { return }
        guard let navigation else { finish(.navigationFailed); return }
        currentNavigation = navigation
        navigationCount += 1; navigationGeneration += 1
        loadedAt = nil; previousSample = nil; stableSamples = 0
        pollWork?.cancel(); pollWork = nil
        if navigationCount > 16 { finish(.navigationFailed) }
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard owns(navigation) else { return }
        redirects += 1; if redirects > 5 { finish(.redirectLimit) }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard owns(navigation), let navigation else { return }
        let key = ObjectIdentifier(navigation)
        guard admissionNavigations[key] != nil else { finish(.navigationFailed); return }
        committedNavigations.insert(key)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard owns(navigation) else { return }
        loadedAt = DispatchTime.now().uptimeNanoseconds; previousSample = nil; stableSamples = 0; pollDOM()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if owns(navigation) { finish(.navigationFailed) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if owns(navigation) { finish(.navigationFailed) }
    }
    private func owns(_ navigation: WKNavigation?) -> Bool {
        !completing && navigation != nil && navigation === currentNavigation
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.contentProcessTerminated) }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !completing else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
