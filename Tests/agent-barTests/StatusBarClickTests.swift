import AppKit
import Testing
@testable import agent_bar

@MainActor
struct StatusBarClickTests {
    @Test("Screen clicks select the matching capsule at different window origins")
    func screenClicksSelectMatchingProvider() {
        _ = NSApplication.shared
        let size = NSSize(width: 164, height: 22)
        let render = CombinedStatusItemRender(
            image: NSImage(size: size),
            size: size,
            segments: [
                StatusItemSegment(provider: .codex, frame: NSRect(x: 0, y: 0, width: 80, height: 22)),
                StatusItemSegment(provider: .claude, frame: NSRect(x: 84, y: 0, width: 80, height: 22)),
            ]
        )
        for origin in [NSPoint(x: 900, y: 700), NSPoint(x: -1500, y: 200)] {
            let window = NSWindow(
                contentRect: NSRect(origin: origin, size: NSSize(width: 240, height: 40)),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let button = NSButton(frame: NSRect(x: 17, y: 5, width: 180, height: 26))
            button.isBordered = false
            button.image = render.image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            window.contentView?.addSubview(button)
            let imageRect = button.cell!.imageRect(forBounds: button.bounds)

            for segment in render.segments {
                // Check the badge, middle and far end of each capsule.
                for x in [segment.frame.minX + 5, segment.frame.midX, segment.frame.maxX - 5] {
                    let local = NSPoint(
                        x: imageRect.minX + x * imageRect.width / size.width,
                        y: button.bounds.midY
                    )
                    let screen = window.convertPoint(toScreen: button.convert(local, to: nil))
                    #expect(render.provider(atScreenPoint: screen, in: button) == segment.provider)
                }
            }

            let outside = window.convertPoint(toScreen: button.convert(NSPoint(x: -10, y: 10), to: nil))
            #expect(render.provider(atScreenPoint: outside, in: button) == nil)
        }
    }
}
