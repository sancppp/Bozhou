import AppKit
import SwiftUI
import BozhouCore

enum SessionSplitEdge: CaseIterable {
    case left, right, top, bottom
    var vertical: Bool { self == .top || self == .bottom }
    var insertsFirst: Bool { self == .left || self == .top }

    static func nearest(to point: CGPoint, in size: CGSize) -> Self? {
        guard size.width > 0, size.height > 0,
              CGRect(origin: .zero, size: size).contains(point) else { return nil }
        let x = point.x / size.width, y = point.y / size.height
        return [(Self.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)].min { $0.1 < $1.1 }?.0
    }
    func preview(in size: CGSize) -> CGRect {
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}

/// App-local payloads cannot paste text into the remote terminal or move sessions between workspaces.
enum SessionDrag {
    static let type = NSPasteboard.PasteboardType("app.bozhou.session")
    @MainActor static func session(from pasteboard: NSPasteboard, model: AppModel) -> UUID? {
        guard let value = pasteboard.string(forType: type),
              value == model.sessionDragScope.uuidString + "/" + (model.draggedSession?.uuidString ?? ""),
              let id = model.draggedSession, model.sessions.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

/// A native source provides an explicit end/cancel callback, including Esc and drops outside the app.
struct SessionTabDragHandle: NSViewRepresentable {
    let model: AppModel
    let session: TerminalSession
    let onRename: (TerminalSession) -> Void
    @Binding var insertionAfter: Bool?
    func makeNSView(context: Context) -> Source { Source() }
    func updateNSView(_ view: Source, context: Context) {
        view.model = model; view.sessionID = session.id; view.title = session.tabDisplayName.full
        let rename = onRename, insertion = $insertionAfter
        view.onRename = { [weak session] in if let session { rename(session) } }
        view.onInsertion = { insertion.wrappedValue = $0 }
    }
    final class Source: NSView, NSDraggingSource {
        weak var model: AppModel?
        var sessionID: UUID?
        var title = ""
        var onRename: (() -> Void)?
        var onInsertion: ((Bool?) -> Void)?
        private var mouseDownEvent: NSEvent?
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([SessionDrag.type])
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
        override func mouseUp(with event: NSEvent) {
            guard mouseDownEvent != nil, let sessionID else { return }
            mouseDownEvent = nil; model?.selectSession(sessionID)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, let model, let id = sessionID,
                  hypot(event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y) >= 4 else { return }
            mouseDownEvent = nil
            model.draggedSession = id
            let item = NSPasteboardItem()
            item.setString(model.sessionDragScope.uuidString + "/" + id.uuidString, forType: SessionDrag.type)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            (title as NSString).draw(in: bounds.insetBy(dx: 8, dy: 8),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            let dragging = NSDraggingItem(pasteboardWriter: item)
            dragging.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            model?.draggedSession = nil; onInsertion?(nil)
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let model, let id = sessionID else { return nil }
            let menu = NSMenu()
            HostMenuAction.add(L10n.tr("Rename Tab…"), to: menu) { [weak self] in self?.onRename?() }
            if let session = model.sessions.first(where: { $0.id == id }), session.customTabName != nil {
                HostMenuAction.add(L10n.tr("Reset Tab Name"), to: menu) { [weak session] in session?.renameTab("") }
            }
            menu.addItem(.separator())
            HostMenuAction.add(L10n.tr("Close Current Session"), to: menu) { [weak model] in model?.closeSession(id) }
            return menu
        }
        private func insertion(_ sender: NSDraggingInfo) -> (UUID, Bool)? {
            guard let model, let id = SessionDrag.session(from: sender.draggingPasteboard, model: model),
                  id != sessionID else { return nil }
            let point = convert(sender.draggingLocation, from: nil)
            return (id, model.settings.tabPlacement == .horizontal ? point.x >= bounds.midX : point.y >= bounds.midY)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let result = insertion(sender); onInsertion?(result?.1)
            return result == nil ? [] : .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { onInsertion?(nil) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { insertion(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { onInsertion?(nil) }
            guard let (id, after) = insertion(sender), let target = sessionID else { return false }
            model?.moveSession(id, relativeTo: target, after: after)
            return true
        }
    }
}

struct SessionSplitDropTarget: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let target: UUID
    @State private var edge: SessionSplitEdge?
    var body: some View {
        GeometryReader { geometry in
            if model.draggedSession != nil && model.draggedSession != target {
                Destination(model: model, target: target, onHover: { edge = $0 })
                if let edge {
                    let rect = edge.preview(in: geometry.size)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(sea.opacity(0.2))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(sea, lineWidth: 2) }
                        .overlay {
                            Label(L10n.tr("Release to split here"),
                                  systemImage: edge.vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                                .font(.callout.weight(.medium)).padding(12).background(.regularMaterial, in: Capsule())
                        }
                        .padding(6).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                        .accessibilityIdentifier("session-split-preview")
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: edge)
        .allowsHitTesting(model.draggedSession != nil && model.draggedSession != target)
        .onChange(of: model.draggedSession) { _, _ in edge = nil }
    }
    struct Destination: NSViewRepresentable {
        let model: AppModel
        let target: UUID
        let onHover: (SessionSplitEdge?) -> Void
        func makeNSView(context: Context) -> DropView { DropView() }
        func updateNSView(_ view: DropView, context: Context) {
            view.model = model; view.target = target; view.onHover = onHover
        }
    }
    final class DropView: NSView {
        weak var model: AppModel?
        var target: UUID?
        var onHover: ((SessionSplitEdge?) -> Void)?
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame); registerForDraggedTypes([SessionDrag.type])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func proposal(_ sender: NSDraggingInfo) -> (UUID, SessionSplitEdge)? {
            guard let model, let id = SessionDrag.session(from: sender.draggingPasteboard, model: model),
                  let target, model.canSplitSession(id, beside: target),
                  let edge = SessionSplitEdge.nearest(to: convert(sender.draggingLocation, from: nil), in: bounds.size)
            else { return nil }
            return (id, edge)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let value = proposal(sender); onHover?(value?.1)
            return value == nil ? [] : .move
        }
        override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(nil) }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { proposal(sender) != nil }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { onHover?(nil) }
            guard let (id, edge) = proposal(sender), let target else { return false }
            model?.splitSession(id, beside: target, edge: edge)
            return true
        }
    }
}
