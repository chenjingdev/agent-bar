import AppKit

enum BadgeDragPayload {
    private static let prefix = "agentbar-group:"
    static func string(_ id: UUID) -> String { prefix + id.uuidString }
    static func groupID(_ string: String?) -> UUID? {
        guard let string, string.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(prefix.count)))
    }
}

/// Transparent child of the standard status button: plain clicks retain the
/// popover action, while normal mouse drags move AgentBar groups between slots.
@MainActor
final class BadgeDragSurface: NSView, NSDraggingSource {
    var groupID: UUID
    var badgeImage: NSImage?
    var onClick: (() -> Void)?
    var onDrag: (() -> Void)?
    var acceptsGroup: ((UUID) -> Bool)?
    var onDropGroup: ((UUID, UUID) -> Bool)?
    private var startPoint: NSPoint?
    private var dragged = false
    private var dropHighlighted = false { didSet { needsDisplay = true } }

    init(groupID: UUID, frame: NSRect) {
        self.groupID = groupID
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Leave macOS's native modifier-drag behavior to the standard button.
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let startPoint, let badgeImage else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - startPoint.x, point.y - startPoint.y) >= 4 else { return }
        dragged = true
        onDrag?()
        let payload = NSPasteboardItem()
        payload.setString(BadgeDragPayload.string(groupID), forType: .string)
        let item = NSDraggingItem(pasteboardWriter: payload)
        let padding: CGFloat = 6
        let preview = NSImage(size: NSSize(width: bounds.width + padding * 2, height: bounds.height + padding * 2), flipped: false) { rect in
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            badgeImage.draw(in: rect.insetBy(dx: padding, dy: padding), from: .zero, operation: .sourceOver, fraction: 0.82)
            return true
        }
        item.setDraggingFrame(bounds.insetBy(dx: -padding, dy: -padding)
            .offsetBy(dx: point.x - startPoint.x, dy: point.y - startPoint.y), contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil }
        if !dragged && bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func rightMouseUp(with event: NSEvent) { onClick?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        startPoint = nil
        dropHighlighted = false
        // Keep dragged=true until the next mouseDown, so the ending mouseUp
        // cannot also open the popover after a successful or cancelled drag.
    }
    private func sourceGroup(_ info: NSDraggingInfo) -> UUID? {
        guard let id = BadgeDragPayload.groupID(info.draggingPasteboard.string(forType: .string)),
              id != groupID, acceptsGroup?(id) == true else { return nil }
        return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlighted = sourceGroup(sender) != nil
        return dropHighlighted ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sourceGroup(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropHighlighted = false }
        guard let source = sourceGroup(sender) else { return false }
        return onDropGroup?(source, groupID) ?? false
    }
    override func draw(_ dirtyRect: NSRect) {
        guard dropHighlighted else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        outline.lineWidth = 2
        outline.stroke()
    }
}
