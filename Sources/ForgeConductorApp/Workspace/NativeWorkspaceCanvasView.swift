import AppKit
import SwiftUI

struct NativeWorkspacePanelDescriptor: Identifiable {
    let id: String
    let title: String
    let defaultFrame: NativeWorkspaceFrame
    var minimumSize = CGSize(width: 280, height: 160)
    var maximumSize = CGSize(width: 2_400, height: 2_400)
    var scrollsContent = true
}

/// The layout value owns geometry. Native hosts retain each panel's controls
/// while pointer gestures change its bounds within the same parent.
@MainActor
struct NativeWorkspaceCanvasView: NSViewRepresentable {
    let layout: NativeWorkspaceLayout
    let descriptors: [NativeWorkspacePanelDescriptor]
    let content: (String, Bool) -> AnyView
    let commitFrame: (String, NativeWorkspaceFrame) -> Void
    let hidePanel: (String) -> Void
    let bringToFront: (String) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(GraphitePalette.canvas)
        scroll.documentView = NativeWorkspaceDocumentView()
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let document = view.documentView as? NativeWorkspaceDocumentView else { return }
        document.apply(layout: layout, descriptors: descriptors, content: content,
                       commitFrame: commitFrame, hidePanel: hidePanel, bringToFront: bringToFront)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: ()) {
        if let document = view.documentView as? NativeWorkspaceDocumentView {
            document.stopHorizontalWheelMonitoring()
            document.removePanels()
        }
        view.documentView = nil
    }
}

@MainActor
final class NativeWorkspaceDocumentView: NSView {
    override var isFlipped: Bool { true }
    private(set) var panelHosts: [String: NativeWorkspacePanelHost] = [:]
    private var activeLayoutIdentity: String?
    private var horizontalWheelMonitor: Any?
    var hasHorizontalWheelMonitor: Bool { horizontalWheelMonitor != nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelPanelGestures() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        stopHorizontalWheelMonitoring()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, horizontalWheelMonitor == nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose),
                                               name: NSWindow.willCloseNotification, object: window)
        horizontalWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard Thread.isMainThread else { return event }
            let forwarded = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.routeHorizontalWheel(event) == nil
            }
            return forwarded ? nil : event
        }
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        stopHorizontalWheelMonitoring()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        cancelPanelGestures()
    }

    private func cancelPanelGestures() {
        for host in panelHosts.values { host.cancelGesture() }
    }

    func stopHorizontalWheelMonitoring() {
        guard let monitor = horizontalWheelMonitor else { return }
        horizontalWheelMonitor = nil
        NSEvent.removeMonitor(monitor)
    }

    private func routeHorizontalWheel(_ event: NSEvent) -> NSEvent? {
        guard event.type == .scrollWheel, event.phase.isEmpty, event.momentumPhase.isEmpty,
              event.scrollingDeltaX.isFinite, event.scrollingDeltaX != 0,
              event.scrollingDeltaY.isFinite, event.scrollingDeltaY == 0,
              let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              let outer = enclosingScrollView, outer.documentView === self,
              superview === outer.contentView,
              outer.contentView.convert(bounds, from: self).width > outer.contentView.bounds.width,
              let contentView = window.contentView, contentView.window === window else {
            return event
        }
        let location = contentView.convert(event.locationInWindow, from: nil)
        guard contentView.bounds.contains(location),
              let hit = contentView.hitTest(contentView.convert(location, to: contentView.superview)) else {
            return event
        }
        var current: NSView? = hit
        var inner: NSScrollView?
        var owner: NativeWorkspacePanelHost?
        for _ in 0..<64 {
            guard let view = current, view !== self else { break }
            if view is NSControl || view is NSTextView { return event }
            if let scroll = view as? NSScrollView {
                guard inner == nil else { return event }
                inner = scroll
            }
            if let panel = view as? NativeWorkspacePanelHost {
                owner = panel
                break
            }
            current = view.superview
        }
        guard let owner, panelHosts[owner.panelID] === owner, owner.superview === self,
              owner.descriptor.scrollsContent, !owner.isHiddenOrHasHiddenAncestor, !owner.isManipulating,
              hit === owner.hostingView || hit.isDescendant(of: owner.hostingView),
              let inner, inner.window === window, !inner.hasHorizontalScroller,
              let innerDocument = inner.documentView, innerDocument.superview === inner.contentView,
              hit === innerDocument || hit.isDescendant(of: innerDocument),
              inner.contentView.convert(innerDocument.bounds, from: innerDocument).width
                <= inner.contentView.bounds.width + 0.5 else {
            return event
        }
        outer.scrollWheel(with: event)
        return nil
    }

    func apply(layout: NativeWorkspaceLayout, descriptors: [NativeWorkspacePanelDescriptor],
               content: (String, Bool) -> AnyView,
               commitFrame: @escaping (String, NativeWorkspaceFrame) -> Void,
               hidePanel: @escaping (String) -> Void,
               bringToFront: @escaping (String) -> Void) {
        let identity = layout.viewID + ":" + layout.id.uuidString
        if activeLayoutIdentity != identity {
            for host in panelHosts.values { host.cancelGesture() }
            activeLayoutIdentity = identity
        }
        frame.size = NSSize(width: layout.canvas.width, height: layout.canvas.height)
        let specs = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        let admitted = Set(layout.panels.map(\.id))
        for id in Array(panelHosts.keys) where !admitted.contains(id) {
            panelHosts.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, placement) in layout.panels.enumerated() {
            guard let descriptor = specs[placement.id] else { continue }
            // Never construct a panel that has not yet been shown.
            guard placement.isVisible || panelHosts[placement.id] != nil else { continue }
            let host: NativeWorkspacePanelHost
            if let existing = panelHosts[placement.id] {
                host = existing
                host.updateContent(content(placement.id, placement.isVisible))
            } else {
                host = NativeWorkspacePanelHost(descriptor: descriptor,
                                               content: content(placement.id, placement.isVisible))
                panelHosts[placement.id] = host
                addSubview(host)
            }
            if !placement.isVisible { host.cancelGesture() }
            host.canvasSize = frame.size
            host.stackingOrder = index
            host.commitFrame = { value in commitFrame(placement.id, value) }
            host.hidePanel = { hidePanel(placement.id) }
            host.bringToFront = { bringToFront(placement.id) }
            if !host.isManipulating {
                host.frame = NSRect(x: placement.frame.x, y: placement.frame.y,
                                    width: placement.frame.width, height: placement.frame.height)
            }
            host.isHidden = !placement.isVisible
        }
        sortSubviews({ lhs, rhs, _ in
            MainActor.assumeIsolated {
                guard let a = lhs as? NativeWorkspacePanelHost, let b = rhs as? NativeWorkspacePanelHost else { return .orderedSame }
                return a.stackingOrder < b.stackingOrder ? .orderedAscending : a.stackingOrder > b.stackingOrder ? .orderedDescending : .orderedSame
            }
        }, context: nil)
    }

    func removePanels() {
        for host in panelHosts.values {
            host.cancelGesture()
            host.commitFrame = nil; host.hidePanel = nil; host.bringToFront = nil
            host.removeFromSuperview()
        }
        panelHosts.removeAll()
        activeLayoutIdentity = nil
    }
}

@MainActor
final class NativeWorkspacePanelHost: NSView {
    let panelID: String
    let descriptor: NativeWorkspacePanelDescriptor
    let hostingView: NSHostingView<AnyView>
    private let title: NSTextField
    private let closeButton = NSButton()
    private let moveHandle = NativeWorkspaceGestureHandle(resizing: false)
    private let resizeHandle = NativeWorkspaceGestureHandle(resizing: true)
    var canvasSize = NSSize.zero
    var stackingOrder = 0
    var commitFrame: ((NativeWorkspaceFrame) -> Void)?
    var hidePanel: (() -> Void)?
    var bringToFront: (() -> Void)?
    private(set) var isManipulating = false
    private var gestureStart = NSPoint.zero
    private var gestureFrame = NSRect.zero
    private var gestureAnchorFrame = NSRect.zero
    private var gestureLastPoint = NSPoint.zero
    override var isFlipped: Bool { true }

    init(descriptor: NativeWorkspacePanelDescriptor, content: AnyView) {
        self.descriptor = descriptor; panelID = descriptor.id
        hostingView = NSHostingView(rootView: content)
        title = NSTextField(labelWithString: descriptor.title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(GraphitePalette.panelBottom).cgColor
        layer?.borderColor = NSColor(GraphitePalette.panelBorder).cgColor
        layer?.borderWidth = 1; layer?.cornerRadius = 8; layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(GraphitePalette.textPrimary)
        title.lineBreakMode = .byTruncatingTail
        moveHandle.owner = self; resizeHandle.owner = self
        moveHandle.toolTip = "Drag to move. Arrow keys move the panel; Option-arrow keys resize it."
        resizeHandle.toolTip = "Drag to resize. Arrow keys resize the panel."
        moveHandle.setAccessibilityIdentifier("workspace-move-" + panelID)
        moveHandle.setAccessibilityLabel("Move " + descriptor.title)
        resizeHandle.setAccessibilityIdentifier("workspace-resize-" + panelID)
        resizeHandle.setAccessibilityLabel("Resize " + descriptor.title)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Hide " + descriptor.title)
        closeButton.bezelStyle = .inline
        closeButton.target = self; closeButton.action = #selector(hide)
        closeButton.toolTip = "Hide panel. Use the Panels menu to show it again."
        closeButton.setAccessibilityIdentifier("workspace-hide-" + panelID)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityIdentifier("workspace-panel-" + panelID)
        setAccessibilityLabel(descriptor.title)
        addSubview(hostingView); addSubview(moveHandle); moveHandle.addSubview(title)
        addSubview(closeButton); addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { nil }

    func updateContent(_ content: AnyView) { hostingView.rootView = content }

    override func layout() {
        super.layout()
        moveHandle.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 34), height: 32)
        title.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - 56), height: 18)
        closeButton.frame = NSRect(x: max(0, bounds.width - 30), y: 4, width: 24, height: 24)
        hostingView.frame = NSRect(x: 1, y: 33, width: max(0, bounds.width - 2), height: max(0, bounds.height - 49))
        resizeHandle.frame = NSRect(x: max(0, bounds.width - 22), y: max(0, bounds.height - 18), width: 22, height: 18)
    }

    @objc private func hide() { hidePanel?() }

    func beginGesture(_ event: NSEvent) {
        guard let parent = superview else { return }
        isManipulating = true; gestureStart = parent.convert(event.locationInWindow, from: nil)
        gestureFrame = frame; gestureAnchorFrame = frame; gestureLastPoint = gestureStart
        bringToFront?()
    }

    func continueGesture(_ event: NSEvent, resizing: Bool) {
        guard isManipulating, let parent = superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        let dx = point.x - gestureStart.x, dy = point.y - gestureStart.y
        frame = boundedFrame(start: gestureAnchorFrame, dx: dx, dy: dy, resizing: resizing)
        gestureLastPoint = point
    }

    func endGesture() {
        guard isManipulating else { return }
        isManipulating = false; publishFrame()
    }

    func cancelGesture() {
        guard isManipulating else { return }
        frame = gestureFrame; isManipulating = false
    }

    func nudge(dx: CGFloat, dy: CGFloat, resizing: Bool) {
        frame = boundedFrame(start: frame, dx: dx, dy: dy, resizing: resizing)
        if isManipulating {
            gestureStart = gestureLastPoint; gestureAnchorFrame = frame
        } else {
            publishFrame()
        }
    }

    private func boundedFrame(start: NSRect, dx: CGFloat, dy: CGFloat, resizing: Bool) -> NSRect {
        if resizing {
            let maxWidth = max(64, min(descriptor.maximumSize.width, canvasSize.width - start.minX))
            let maxHeight = max(64, min(descriptor.maximumSize.height, canvasSize.height - start.minY))
            return NSRect(x: start.minX, y: start.minY,
                          width: min(maxWidth, max(min(descriptor.minimumSize.width, maxWidth), start.width + dx)),
                          height: min(maxHeight, max(min(descriptor.minimumSize.height, maxHeight), start.height + dy)))
        }
        return NSRect(x: min(max(0, canvasSize.width - start.width), max(0, start.minX + dx)),
                      y: min(max(0, canvasSize.height - start.height), max(0, start.minY + dy)),
                      width: start.width, height: start.height)
    }

    private func publishFrame() {
        commitFrame?(NativeWorkspaceFrame(x: frame.minX, y: frame.minY,
                                         width: frame.width, height: frame.height))
    }
}

@MainActor
private final class NativeWorkspaceGestureHandle: NSView {
    weak var owner: NativeWorkspacePanelHost?
    let resizing: Bool
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(resizing: Bool) {
        self.resizing = resizing
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard resizing else { return }
        NSColor(GraphitePalette.textSecondary).setStroke()
        let path = NSBezierPath()
        for offset in [CGFloat(4), 8, 12] {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.maxY - 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.maxY - offset))
        }
        path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); owner?.beginGesture(event)
    }
    override func mouseDragged(with event: NSEvent) { owner?.continueGesture(event, resizing: resizing) }
    override func mouseUp(with event: NSEvent) {
        owner?.continueGesture(event, resizing: resizing); owner?.endGesture()
    }
    override func keyDown(with event: NSEvent) {
        let delta: (CGFloat, CGFloat)
        switch event.keyCode {
        case 53: owner?.cancelGesture(); return
        case 123: delta = (-10, 0)
        case 124: delta = (10, 0)
        case 125: delta = (0, 10)
        case 126: delta = (0, -10)
        default: super.keyDown(with: event); return
        }
        owner?.nudge(dx: delta.0, dy: delta.1, resizing: resizing || event.modifierFlags.contains(.option))
    }
    override func cancelOperation(_ sender: Any?) { owner?.cancelGesture() }
    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
}
