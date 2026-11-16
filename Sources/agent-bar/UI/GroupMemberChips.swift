import SwiftUI

private struct MemberChipFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// "Accounts in this group": the accounts a group holds, as chips in their order. Hovering a chip
/// shows the button that removes it, + Add offers the accounts not in the group yet, and dragging
/// a chip reorders them. A group without accounts of its own shows its lines' accounts; the first
/// change makes them its own.
struct GroupMemberSection: View {
    @EnvironmentObject private var store: UsageStore
    let group: MenuBarLayout
    @State private var drag: ReorderDragPreview<UUID>?
    @State private var settling = false
    @State private var frames: [UUID: CGRect] = [:]
    private static let space = "member-order"

    var body: some View {
        let members = members(of: group.effectiveMemberIDs)
        let order = members.map(\.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(localized: "Accounts in this group")).font(.headline)
                if members.count > 1 {
                    Text(String(localized: "\(members.count) · drag to reorder the list"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ChipFlowLayout(spacing: 6) {
                ForEach(members) { chip($0, order: order) }
                addMenu
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(MemberChipFrames.self) { frames = $0 }
            .overlay(alignment: .topLeading) { dragOverlay.allowsHitTesting(false) }
        }
        .onDisappear { drag = nil; settling = false }
        // The dragged chip floats over the settings below it.
        .zIndex(drag == nil ? 0 : 1)
    }

    /// The accounts behind `ids` that still exist, in that order.
    private func members(of ids: [UUID]) -> [UsageAccount] {
        let accounts = store.orderedAccounts
        return ids.compactMap { id in accounts.first { $0.id == id } }
    }

    private func chip(_ account: UsageAccount, order: [UUID]) -> some View {
        MemberChip(provider: account.provider, badge: store.accountLabel(for: account),
                   title: account.provider.accountChoiceTitle(store.accountLabel(for: account))) {
            store.removeGroupMember(account.id, from: group.id)
        }
        .accessibilityAction(named: Text(String(localized: "Move left"))) { move(account.id, by: -1, in: order) }
        .accessibilityAction(named: Text(String(localized: "Move right"))) { move(account.id, by: 1, in: order) }
        // Like the group tabs: a press shorter than 4 points stays a click, so the remove button works.
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !settling else { return }
                if drag == nil {
                    drag = ReorderDragPreview(source: account.id, order: order, frames: frames,
                                              location: value.location, translation: value.translation)
                } else {
                    drag?.location = value.location
                    drag?.translation = value.translation
                }
            }
            .onEnded { finishDrag(at: $0.location) })
        .background(GeometryReader { proxy in
            Color.clear.preference(key: MemberChipFrames.self, value: [account.id: proxy.frame(in: .named(Self.space))])
        })
        .opacity(drag?.source == account.id ? 0 : 1)
        .offset(drag?.offset(for: account.id) ?? .zero)
        .animation(.snappy(duration: 0.18), value: drag?.target)
    }

    private var addMenu: some View {
        let accounts = store.orderedAccounts
        let held = Set(group.effectiveMemberIDs)
        let addable = accounts.filter { !held.contains($0.id) }
        return Menu {
            ForEach(addable) { account in
                Button(account.provider.accountChoiceTitle(store.accountLabel(for: account))) {
                    store.addGroupMember(account.id, to: group.id)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                Text(String(localized: "Add")).font(.callout.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .frame(height: MemberChip.height)
            .overlay(RoundedRectangle(cornerRadius: MemberChip.cornerRadius)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(RoundedRectangle(cornerRadius: MemberChip.cornerRadius))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(addable.isEmpty)
        .help(accounts.isEmpty ? String(localized: "Add an account in the Accounts tab first.")
              : addable.isEmpty ? String(localized: "Every account is in this group.") : String(localized: "Add an account to this group"))
        .accessibilityLabel(String(localized: "Add an account to this group"))
    }

    @ViewBuilder private var dragOverlay: some View {
        if let drag, let account = store.orderedAccounts.first(where: { $0.id == drag.source }) {
            DragSlotPlaceholder(cornerRadius: MemberChip.cornerRadius)
                .frame(width: drag.placeholder.width, height: drag.placeholder.height)
                .offset(x: drag.placeholder.minX, y: drag.placeholder.minY)
                .animation(.snappy(duration: 0.18), value: drag.target)
            MemberChipLabel(provider: account.provider, badge: store.accountLabel(for: account))
                .frame(width: drag.floatingFrame.width, height: drag.floatingFrame.height)
                .modifier(FloatingDragCard(settling: settling, cornerRadius: MemberChip.cornerRadius))
                .offset(x: drag.floatingFrame.minX, y: drag.floatingFrame.minY)
        }
    }

    private func finishDrag(at point: CGPoint) {
        guard var current = drag, !settling else { return }
        current.location = point
        let target = current.target
        drag = current
        withAnimation(.easeOut(duration: 0.16)) {
            settling = true
            drag?.translation = current.landingTranslation
        } completion: {
            guard drag?.source == current.source else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Dropped on an order changed elsewhere meanwhile: the drop no longer means anything.
                let now = members(of: store.groupMembers(group.id) ?? []).map(\.id)
                if let target, now == current.order { store.moveGroupMember(current.source, to: target, in: group.id) }
                drag = nil
                settling = false
            }
        }
    }

    private func move(_ id: UUID, by offset: Int, in order: [UUID]) {
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        store.moveGroupMember(id, to: order[index + offset], in: group.id)
    }
}

/// A member as its chip and the dragged copy draw it: the provider's tile and the account's name.
struct MemberChipLabel: View {
    let provider: ProviderKind
    let badge: String
    var body: some View {
        HStack(spacing: 5) {
            ProviderMark(provider: provider, size: 16)
            Text(verbatim: badge).font(.callout.weight(.semibold)).lineLimit(1)
        }
    }
}

/// One account of a group. Hovering shows the button that removes it; the chip keeps room for that
/// button all the time, so it never changes width and the rows never shift under the pointer.
struct MemberChip: View {
    static let height: CGFloat = 24
    static let cornerRadius: CGFloat = 7
    private static let removeSize: CGFloat = 12
    private static let removeGap: CGFloat = 3
    let provider: ProviderKind
    let badge: String
    /// The account's name, as the usage line menus show it.
    let title: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Self.removeGap) {
            MemberChipLabel(provider: provider, badge: badge)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Self.removeSize))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.removeSize, height: Self.removeSize)
            }
            .buttonStyle(.plain)
            .help(removeTitle)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        // At rest the badge sits in the middle, where the hidden button's room would leave it off center.
        .offset(x: hovering ? 0 : (Self.removeSize + Self.removeGap) / 2)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius)
            .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAction(named: Text(removeTitle), remove)
    }

    private var removeTitle: String { String(localized: "Remove \(badge) from this group") }
}

/// Chips left to right at their own sizes, starting a new row before one that would pass the width
/// offered. A chip wider than a whole row gets a row of its own, cut to the width.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = Self.frames(subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? .infinity, spacing: spacing)
        let used = frames.map(\.maxX).max() ?? 0
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? used
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width, spacing: spacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each item's frame from the top left corner, centered on the height of its row.
    static func frames(_ sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        let widths = sizes.map { min($0.width, width) }
        var rows: [[Int]] = []
        var x: CGFloat = 0
        for index in sizes.indices {
            if rows.isEmpty || (x > 0 && x + widths[index] > width) { rows.append([]); x = 0 }
            rows[rows.count - 1].append(index)
            x += widths[index] + spacing
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var y: CGFloat = 0
        for row in rows {
            let height = row.map { sizes[$0].height }.max() ?? 0
            x = 0
            for index in row {
                frames[index] = CGRect(x: x, y: y + (height - sizes[index].height) / 2, width: widths[index], height: sizes[index].height)
                x += widths[index] + spacing
            }
            y += height + spacing
        }
        return frames
    }
}
