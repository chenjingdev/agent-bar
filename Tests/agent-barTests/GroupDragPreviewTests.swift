import Foundation
import Testing
@testable import agent_bar

struct GroupDragPreviewTests {
    @Test func usageLinePreviewMatchesOccupiedAndEmptySlotMoves() {
        let account = UUID()
        let first = MenuBarLine(accountID: account, metricID: "5h", slot: 0)
        let last = MenuBarLine(accountID: account, metricID: "weekly", slot: 2)
        let layout = MenuBarLayout(rows: [first, last])
        let frames = Dictionary(uniqueKeysWithValues: (0..<3).map {
            ($0, CGRect(x: 14, y: 100 + $0 * 58, width: 470, height: 44))
        })
        var drag = ReorderDragPreview(source: 0, order: [0, 1, 2], frames: frames,
                                      location: CGPoint(x: 50, y: 230), translation: CGSize(width: 0, height: 116),
                                      behavior: .swap, hitPadding: CGSize(width: 3, height: 7))
        #expect(drag.target == 2)
        #expect(drag.offset(for: 2) == CGSize(width: 0, height: -116))
        #expect(drag.offset(for: 1) == .zero)
        var moved = layout
        moved.moveLine(first.id, offset: 2)
        #expect(moved.rows.map(\.id) == [last.id, first.id])
        #expect(moved.rows.map(\.slot) == [0, 2])

        // The plus tile in a fixed slot moves into the vacated source slot.
        drag.location = CGPoint(x: 50, y: 180)
        #expect(drag.target == 1)
        #expect(drag.previewOrder == [1, 0, 2])
        #expect(drag.offset(for: 1) == CGSize(width: 0, height: -58))
        moved = layout
        moved.moveLine(first.id, offset: 1)
        #expect(moved.rows.map(\.slot) == [1, 2])
    }

    @Test func textOnlyAddTileIsNotADropSlot() {
        let frames = Dictionary(uniqueKeysWithValues: (0..<5).map {
            ($0, CGRect(x: 14, y: $0 * 58, width: 470, height: 44))
        })
        var drag = ReorderDragPreview(source: 0, order: [0, 1, 2, 3], frames: frames,
                                      location: CGPoint(x: 50, y: 196), translation: CGSize(width: 0, height: 174),
                                      behavior: .swap)
        #expect(drag.target == 3)
        #expect(drag.previewOrder == [3, 1, 2, 0])
        drag.location = CGPoint(x: 50, y: 254)
        #expect(drag.target == nil)
        #expect(drag.landingTranslation == .zero)
    }

    @Test func previewMakesRoomWithoutMovingItsHitTargets() {
        let ids = (0..<3).map { _ in UUID() }
        let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
            ($0.element, CGRect(x: $0.offset * 126, y: 0, width: 120, height: 32))
        })
        let drag = GroupDragPreview(source: ids[0], order: ids, frames: frames,
                                    location: CGPoint(x: 310, y: 16), translation: CGSize(width: 250, height: 0))
        #expect(drag.target == ids[2])
        #expect(drag.previewOrder == [ids[1], ids[2], ids[0]])
        #expect(drag.offset(for: ids[1]).width == -126)
        #expect(drag.offset(for: ids[2]).width == -126)
        #expect(drag.placeholder == frames[ids[2]])
        #expect(drag.floatingFrame.minX == 250)
        #expect(drag.landingTranslation.width == 252)
        #expect(drag.frames == frames)
        #expect(drag.order == ids)
    }

    @Test func outsideDropReturnsToSourceAndWrappedRowsRemainReachable() {
        let a = UUID(), b = UUID(), c = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 120, height: 32),
                      b: CGRect(x: 126, y: 0, width: 120, height: 32),
                      c: CGRect(x: 0, y: 38, width: 120, height: 32)]
        var drag = GroupDragPreview(source: a, order: [a, b, c], frames: frames,
                                    location: CGPoint(x: 60, y: 54), translation: CGSize(width: 0, height: 38))
        #expect(drag.target == c)
        #expect(drag.offset(for: c) == CGSize(width: 126, height: -38))
        drag.location = CGPoint(x: 60, y: 150)
        #expect(drag.target == nil)
        #expect(drag.previewOrder == [a, b, c])
        #expect(drag.placeholder == frames[a])
        #expect(drag.landingTranslation == .zero)
    }
}
