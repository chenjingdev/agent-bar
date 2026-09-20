import Foundation

/// Keeps hit testing in the original slots while the visible buttons move.
/// Moving the hit regions as well would make neighboring buttons oscillate.
typealias GroupDragPreview = ReorderDragPreview<UUID>

enum ReorderDragBehavior { case insert, swap }

struct ReorderDragPreview<ID: Hashable> {
    let source: ID
    let order: [ID]
    let frames: [ID: CGRect]
    var location: CGPoint
    var translation: CGSize
    var behavior: ReorderDragBehavior = .insert
    var hitPadding = CGSize(width: 3, height: 3)

    var target: ID? {
        order.first { frames[$0]?.insetBy(dx: -hitPadding.width, dy: -hitPadding.height).contains(location) == true }
    }
    var previewOrder: [ID] {
        guard let target, let from = order.firstIndex(of: source), let to = order.firstIndex(of: target) else { return order }
        var result = order
        switch behavior {
        case .insert: result.insert(result.remove(at: from), at: to)
        case .swap: result.swapAt(from, to)
        }
        return result
    }
    var placeholder: CGRect { frames[target ?? source] ?? .zero }
    var floatingFrame: CGRect { (frames[source] ?? .zero).offsetBy(dx: translation.width, dy: translation.height) }
    var landingTranslation: CGSize {
        let origin = frames[source] ?? .zero
        return CGSize(width: placeholder.minX - origin.minX, height: placeholder.minY - origin.minY)
    }
    func offset(for id: ID) -> CGSize {
        guard id != source, let index = previewOrder.firstIndex(of: id),
              let destination = frames[order[index]], let original = frames[id] else { return .zero }
        return CGSize(width: destination.minX - original.minX, height: destination.minY - original.minY)
    }
}
