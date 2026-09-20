import SwiftUI
private struct SlotFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GroupFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct MenuBarSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var groupDrag: GroupDragPreview?
    @State private var settlingGroupDrag = false
    @State private var groupFrames: [UUID: CGRect] = [:]
    private var groups: [MenuBarLayout] { store.displayConfiguration.effectiveLayouts }
    private var selected: MenuBarLayout? { groups.first { $0.id == store.selectedMenuBarGroupID } ?? groups.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Build each menu bar group from any mix of accounts and limits.")
                    .font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                    ForEach(groups) { group in
                        Button { store.selectMenuBarGroup(group.id) } label: {
                            groupLabel(group)
                        }
                        .buttonStyle(ChoiceButtonStyle(selected: selected?.id == group.id))
                        .help(group.name + (group.enabled ? "" : " · hidden"))
                        .accessibilityAddTraits(selected?.id == group.id ? .isSelected : [])
                        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("group-order"))
                            .onChanged { value in
                                guard !settlingGroupDrag else { return }
                                if groupDrag == nil {
                                    groupDrag = GroupDragPreview(source: group.id, order: groups.map(\.id), frames: groupFrames,
                                                                 location: value.location, translation: value.translation)
                                } else {
                                    groupDrag?.location = value.location
                                    groupDrag?.translation = value.translation
                                }
                            }
                            .onEnded { finishGroupDrag(at: $0.location) })
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: GroupFrames.self, value: [group.id: proxy.frame(in: .named("group-order"))])
                        })
                        .opacity(groupDrag?.source == group.id ? 0 : 1)
                        .offset(groupDrag?.offset(for: group.id) ?? .zero)
                        .animation(.snappy(duration: 0.18), value: groupDrag?.target)
                    }
                    Button {
                        let group = MenuBarLayout(name: "Group \(groups.count + 1)")
                        store.updateDisplay { $0.editLayouts { $0.append(group) } }
                        store.selectMenuBarGroup(group.id)
                    } label: { Label("Add Group", systemImage: "plus").frame(maxWidth: .infinity) }
                        .buttonStyle(ChoiceButtonStyle(selected: false))
                }
                .coordinateSpace(name: "group-order")
                .onPreferenceChange(GroupFrames.self) { groupFrames = $0 }
                .overlay(alignment: .topLeading) { groupDragOverlay.allowsHitTesting(false) }
                .zIndex(groupDrag == nil ? 0 : 1)
                if let selected { MenuBarGroupEditor(group: selected).id(selected.id) }
                else { Text("Add a group, then add a line for each usage limit you want to see.").foregroundStyle(.secondary) }
                Text("메뉴바의 뱃지나 위 그룹 버튼을 드래그해 순서를 바꿀 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.displayWidthWarning { Text("These groups use a large portion of the menu bar.").font(.caption).foregroundStyle(.orange) }

            }.padding(20)
        }
        .onDisappear { groupDrag = nil; settlingGroupDrag = false }
    }

    private func groupLabel(_ group: MenuBarLayout) -> some View {
        HStack(spacing: 4) {
            if !group.enabled { Image(systemName: "eye.slash") }
            Text(group.name.isEmpty ? "Untitled" : group.name).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var groupDragOverlay: some View {
        if let drag = groupDrag, let group = groups.first(where: { $0.id == drag.source }) {
            DragSlotPlaceholder()
                .frame(width: drag.placeholder.width, height: drag.placeholder.height)
                .offset(x: drag.placeholder.minX, y: drag.placeholder.minY)
                .animation(.snappy(duration: 0.18), value: drag.target)
            groupLabel(group)
                .padding(.horizontal, 8)
                .frame(width: drag.floatingFrame.width, height: drag.floatingFrame.height)
                .modifier(FloatingDragCard(settling: settlingGroupDrag))
                .offset(x: drag.floatingFrame.minX, y: drag.floatingFrame.minY)
                .accessibilityHidden(true)
        }
    }

    private func finishGroupDrag(at point: CGPoint) {
        guard var drag = groupDrag, !settlingGroupDrag else { return }
        drag.location = point
        let target = drag.target
        groupDrag = drag
        withAnimation(.easeOut(duration: 0.16)) {
            settlingGroupDrag = true
            groupDrag?.translation = drag.landingTranslation
        } completion: {
            guard groupDrag?.source == drag.source else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let target, groups.map(\.id) == drag.order { store.moveMenuBarGroup(drag.source, to: target) }
                groupDrag = nil
                settlingGroupDrag = false
            }
        }
    }
}

private struct MenuBarGroupEditor: View {
    @EnvironmentObject private var store: UsageStore
    let group: MenuBarLayout
    @State private var deleting = false
    @State private var lineDrag: ReorderDragPreview<Int>?
    @State private var draggedLineID: String?
    @State private var originalDragRows: [MenuBarLine] = []
    @State private var settlingLineDrag = false
    @State private var slotFrames: [Int: CGRect] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                LabeledContent("Group name") { TextField("Group name", text: binding(\.name)).labelsHidden() }
                Toggle("Show", isOn: binding(\.enabled)).toggleStyle(.switch).fixedSize()
                Button { deleting = true } label: { Image(systemName: "trash") }.help("Delete this group")
            }
            HStack(spacing: 6) {
                ForEach(MenuBarStyle.selectableCases) { style in
                    Button {
                        store.updateDisplay { $0.editLayout(group.id) {
                            $0.style = style
                            if style == .bars { $0.showBar = true }
                            if style == .text { $0.showPercent = true }
                        } }
                    } label: {
                        VStack(spacing: 6) {
                            StyleSymbol(style: style).frame(height: 24).accessibilityHidden(true)
                            Text(style.title).font(.caption).lineLimit(1)
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChoiceButtonStyle(selected: group.style.selection == style))
                    .disabled(style != .text && group.style == .text && group.rows.count > MenuBarLayout.maximumLines)
                    .help(style != .text && group.style == .text && group.rows.count > MenuBarLayout.maximumLines
                          ? "Remove values until three remain to use this style." : style.summary)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(group.style.selection == style ? .isSelected : [])
                }
            }
            HStack(spacing: 4) {
                Text("Badges").font(.caption).foregroundStyle(.secondary)
                ForEach(BadgeDisplayMode.selectableCases) { mode in
                    Button {
                        let color = group.rows.first.flatMap { store.menuBarEntry(for: $0.accountID)?.display.color } ?? .blue
                        store.updateDisplay { $0.editLayout(group.id) { value in
                            value.badgeMode = mode
                            if mode.includesCommon, value.commonBadgeText == nil { value.commonBadgeText = String(value.name.prefix(24)) }
                            if mode.includesCommon, value.commonBadgeColor == nil { value.commonBadgeColor = color }
                        } }
                    } label: { Text(mode.title).font(.caption).frame(maxWidth: .infinity) }
                    .buttonStyle(ChoiceButtonStyle(selected: group.effectiveBadgeMode == mode))
                    .accessibilityLabel("\(mode.title) badges")
                    .accessibilityAddTraits(group.effectiveBadgeMode == mode ? .isSelected : [])
                }
            }
            if group.effectiveBadgeMode.includesCommon {
                HStack(spacing: 8) {
                    Text("Common").font(.caption).foregroundStyle(.secondary)
                    BadgeColorButton(title: "Common badge color", color: Binding(get: { group.commonBadgeColor ?? .blue }, set: { color in
                        store.updateDisplay { $0.editLayout(group.id) { $0.commonBadgeColor = color } }
                    }))
                    TextField("Common badge", text: Binding(get: { group.commonBadgeLabel }, set: { text in
                        store.updateDisplay { $0.editLayout(group.id) { $0.commonBadgeText = String(text.prefix(24)) } }
                    })).textFieldStyle(.roundedBorder).frame(width: 112)
                }
            }
            HStack {
                if group.style == .text {
                    Text(group.rows.count > MenuBarLayout.maximumLines
                         ? "Shows every percentage from left to right. Remove values until three remain to switch styles."
                         : "Shows every percentage from left to right.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if group.style != .capsule {
                    Toggle(group.style == .ring ? "Percentage" : "Representative %", isOn: binding(\.showPercent))
                } else { Text("Each capsule fills with usage and shows its percentage.").font(.caption).foregroundStyle(.secondary) }
            }.toggleStyle(.checkbox)
            if !group.showsAnything { Text("All components are off. This group is hidden and its refresh is paused.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            Text(usageLinesTitle).font(.headline)
            ForEach(0..<editorSlotCount, id: \.self) { slot in
                VStack(spacing: 0) {
                if let index = lineIndex(for: slot) {
                    lineEditor(at: index)
                        .frame(minHeight: 44)
                } else {
                    Button { addLine(in: slot) } label: {
                        Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Add usage line \(slot + 1)")
                        .help("Add usage line \(slot + 1)")
                        .disabled(store.orderedAccounts.isEmpty)
                }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SlotFrames.self, value: [slot: proxy.frame(in: .named(group.id))])
                })
                .opacity(lineDrag?.source == slot ? 0 : 1)
                .offset(lineDrag?.offset(for: slot) ?? .zero)
                .animation(.snappy(duration: 0.18), value: lineDrag?.target)
            }
            if store.orderedAccounts.isEmpty { Text("Add an account in the Accounts tab first.").font(.caption).foregroundStyle(.secondary) }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .coordinateSpace(name: group.id)
        .onPreferenceChange(SlotFrames.self) { slotFrames = $0 }
        .overlay(alignment: .topLeading) { lineDragOverlay.allowsHitTesting(false) }
        .onDisappear { clearLineDrag() }
        .alert("Delete \(group.name)?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { store.updateDisplay { $0.editLayouts { $0.removeAll { $0.id == group.id } } } }
        } message: { Text("Only this display group is removed. Its accounts remain available. To keep its layout for later, switch Show off instead.") }
    }
    private var editorSlotCount: Int {
        if group.style == .ring { return 1 }
        if group.style == .text { return group.rows.count + 1 }
        return MenuBarLayout.maximumLines
    }
    private var usageLinesTitle: String {
        if group.style == .ring { return "Usage line" }
        if group.style == .text { return "Usage values · \(group.rows.count)" }
        return "Usage lines · \(group.rows.count)/\(MenuBarLayout.maximumLines)"
    }
    private func lineIndex(for slot: Int) -> Int? {
        if group.style == .ring, let line = group.displayedRows.first {
            return group.rows.firstIndex { $0.id == line.id }
        }
        return group.rows.indices.first { (group.rows[$0].slot ?? $0) == slot }
    }
    private func lineEditor(at index: Int, preview: Bool = false) -> some View {
        let line = group.rows[index]
        return MenuBarLineEditor(groupID: group.id, line: line, index: index,
            allowsDragging: group.style != .ring,
            canRepresentPercentage: group.style == .bars && group.showPercent,
            representsPercentage: group.effectivePercentageLineID == line.id,
            dragChanged: { value in
                if !preview { updateLineDrag(line.id, slot: line.slot ?? index, value: value) }
            },
            dragEnded: { point in if !preview { finishLineDrag(at: point) } })
    }

    @ViewBuilder private var lineDragOverlay: some View {
        if let drag = lineDrag, let index = group.rows.firstIndex(where: { $0.id == draggedLineID }) {
            DragSlotPlaceholder(cornerRadius: 8)
                .frame(width: drag.placeholder.width, height: drag.placeholder.height)
                .offset(x: drag.placeholder.minX, y: drag.placeholder.minY)
                .animation(.snappy(duration: 0.18), value: drag.target)
            lineEditor(at: index, preview: true)
                .frame(width: drag.floatingFrame.width, height: drag.floatingFrame.height)
                .modifier(FloatingDragCard(settling: settlingLineDrag, liftScale: 1.02))
                .offset(x: drag.floatingFrame.minX, y: drag.floatingFrame.minY)
        }
    }

    private func updateLineDrag(_ id: String, slot: Int, value: DragGesture.Value) {
        guard !settlingLineDrag else { return }
        if lineDrag == nil {
            // The trailing plus in Text Only creates a new line, not a reorder slot.
            let count = group.style == .text ? group.rows.count : editorSlotCount
            lineDrag = ReorderDragPreview(source: slot, order: Array(0..<count), frames: slotFrames,
                                          location: value.location, translation: value.translation,
                                          behavior: .swap, hitPadding: CGSize(width: 3, height: 7))
            draggedLineID = id
            originalDragRows = group.rows
        } else {
            lineDrag?.location = value.location
            lineDrag?.translation = value.translation
        }
    }

    private func finishLineDrag(at point: CGPoint) {
        guard var drag = lineDrag, let id = draggedLineID, !settlingLineDrag else { return }
        drag.location = point
        let target = drag.target
        lineDrag = drag
        withAnimation(.easeOut(duration: 0.16)) {
            settlingLineDrag = true
            lineDrag?.translation = drag.landingTranslation
        } completion: {
            guard draggedLineID == id else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                if let target, group.rows == originalDragRows {
                    store.updateDisplay { $0.editLayout(group.id) { $0.moveLine(id, offset: target - drag.source) } }
                }
                clearLineDrag()
            }
        }
    }

    private func clearLineDrag() {
        lineDrag = nil
        draggedLineID = nil
        originalDragRows = []
        settlingLineDrag = false
    }
    private func addLine(in slot: Int) {
        let preferredID = group.rows.last?.accountID
        guard let account = store.orderedAccounts.first(where: { $0.id == preferredID }) ?? store.orderedAccounts.first else { return }
        store.updateDisplay { config in
            config.setVisible(account.id, true)
            let badge = config.display(account).badge
            config.editLayout(group.id) { layout in
                guard (layout.style == .text || layout.rows.count < MenuBarLayout.maximumLines),
                      !layout.rows.contains(where: { $0.slot == slot }) else { return }
                layout.rows.append(MenuBarLine(accountID: account.id, metricID: "weekly", slot: slot, badgeText: badge))
                layout.rows.sort { ($0.slot ?? 0) < ($1.slot ?? 0) }
            }
        }
    }
    private func binding<Value>(_ key: WritableKeyPath<MenuBarLayout, Value>) -> Binding<Value> {
        Binding(get: { group[keyPath: key] }, set: { value in
            store.updateDisplay { $0.editLayout(group.id) { $0[keyPath: key] = value } }
        })
    }
}

private struct MenuBarLineEditor: View {
    @EnvironmentObject private var store: UsageStore
    let groupID: UUID
    let line: MenuBarLine
    let index: Int
    let allowsDragging: Bool
    let canRepresentPercentage: Bool
    let representsPercentage: Bool
    let dragChanged: (DragGesture.Value) -> Void
    let dragEnded: (CGPoint) -> Void
    private var account: UsageAccount? { store.accounts.first { $0.id == line.accountID } }
    private var metrics: [DisplayMetric] {
        account.map { DisplayMetric.all(store.snapshot(for: $0)) } ?? []
    }
    var body: some View {
        HStack(spacing: 6) {
            if allowsDragging {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 14, height: 22).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(groupID))
                        .onChanged(dragChanged)
                        .onEnded { dragEnded($0.location) })
                    .help("Drag to another slot")
                    .accessibilityLabel("Move usage line \((line.slot ?? index) + 1)")
                    .accessibilityAction(named: "Move up") { move(-1) }
                    .accessibilityAction(named: "Move down") { move(1) }
            }
                Picker("Account", selection: Binding(get: { line.accountID }, set: { id in
                    store.updateDisplay { config in
                        config.setVisible(id, true)
                        config.editLayout(groupID) { group in
                            guard let i = group.rows.firstIndex(where: { $0.id == line.id }) else { return }
                            group.rows[i].accountID = id
                            if let account = store.accounts.first(where: { $0.id == id }),
                               !DisplayMetric.all(store.snapshot(for: account)).contains(where: { $0.id == line.metricID }) {
                                group.rows[i].metricID = "weekly"
                            }
                        }
                    }
                })) {
                    ForEach(store.orderedAccounts) { Text(store.accountLabel(for: $0) + " · " + $0.provider.shortName).tag($0.id) }
                }.labelsHidden().frame(width: 150)
                HStack(spacing: 4) {
                    ForEach(limitChoices) { metric in
                        Button {
                            store.updateDisplay { $0.editLayout(groupID) { group in
                                guard let i = group.rows.firstIndex(where: { $0.id == line.id }) else { return }
                                group.rows[i].metricID = metric.id
                            } }
                        } label: {
                            Text(limitTitle(metric)).font(.caption).lineLimit(1).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChoiceButtonStyle(selected: line.metricID == metric.id))
                        .help(metric.title + (metric.window?.utilization == nil ? " · no data yet" : ""))
                        .accessibilityLabel(metric.title)
                        .accessibilityAddTraits(line.metricID == metric.id ? .isSelected : [])
                    }
                }.frame(maxWidth: .infinity)
            if canRepresentPercentage {
                Button {
                    store.updateDisplay { $0.editLayout(groupID) { $0.percentageLineID = line.id } }
                } label: {
                    Text("%")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(representsPercentage ? Color.accentColor : Color.secondary)
                        .frame(width: 20, height: 20)
                        .background(representsPercentage ? Color.accentColor.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(representsPercentage ? Color.accentColor : Color.primary.opacity(0.12)))
                }.buttonStyle(.plain)
                    .help(representsPercentage ? "Representative percentage" : "Use this line's percentage")
                    .accessibilityLabel("Representative percentage")
                    .accessibilityAddTraits(representsPercentage ? .isSelected : [])
            }
            if !store.displayConfiguration.isVisible(line.accountID) {
                Button { store.updateDisplay { $0.setVisible(line.accountID, true) } } label: {
                    Image(systemName: "pause.circle")
                }.buttonStyle(.plain).help("Enable this account")
            }
            Button {
                store.updateDisplay { $0.editLayout(groupID) { group in
                    group.rows.removeAll { $0.id == line.id }
                    if group.percentageLineID == line.id { group.percentageLineID = nil }
                } }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .help("Remove this usage line")
                .accessibilityLabel("Remove Line")
        }.padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))

    }
    private var limitChoices: [DisplayMetric] {
        if metrics.contains(where: { $0.id == line.metricID }) { return metrics }
        return metrics + [DisplayMetric(id: line.metricID, title: line.metricID, window: nil)]
    }
    private func limitTitle(_ metric: DisplayMetric) -> String {
        switch metric.id {
        case "5h": return "5 hours"
        case "weekly": return "Weekly"
        default: return metric.title.replacingOccurrences(of: " Weekly", with: "")
        }
    }
    private func move(_ offset: Int) {
        store.updateDisplay { $0.editLayout(groupID) { group in
            group.moveLine(line.id, offset: offset)
        } }
    }
}

struct ChoiceButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct StyleSymbol: View {
    let style: MenuBarStyle
    var body: some View {
        switch style {
        case .badge:
            HStack(spacing: 3) {
                Text("CL").font(.system(size: 8, weight: .bold)).padding(3)
                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                Capsule().fill(Color.accentColor).frame(width: 19, height: 4)
            }
        case .ring:
            HStack(spacing: 4) {
                Circle().stroke(Color.accentColor, lineWidth: 3).frame(width: 19, height: 19)
                Text("42%").font(.system(size: 9, weight: .bold, design: .rounded))
            }
        case .capsule:
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.15))
                Rectangle().fill(Color.accentColor.opacity(0.65)).frame(width: 13)
                Text("42%").font(.system(size: 8, weight: .bold)).frame(width: 32)
            }.frame(width: 32, height: 18).clipShape(Capsule())
        case .bars:
            VStack(alignment: .leading, spacing: 3) {
                ForEach([32.0, 22.0, 27.0], id: \.self) { width in
                    Capsule().fill(Color.accentColor).frame(width: width, height: 3)
                }
            }.frame(width: 40)
        case .text:
            Text("42%").font(.system(size: 12, weight: .bold, design: .rounded))
        }
    }
}

private struct BadgeColorButton: View {
    let title: String
    @Binding var color: AccountColor
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Circle().fill(color.color).frame(width: 18, height: 18)
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption)
                HStack(spacing: 6) {
                    ForEach(AccountColor.allCases) { option in
                        Button { color = option; presented = false } label: {
                            Circle().fill(option.color).frame(width: 22, height: 22)
                                .overlay { if option == color { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                    }
                }
            }.padding(12)
        }
    }
}
