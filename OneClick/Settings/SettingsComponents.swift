import SwiftUI

struct SettingsSection<Actions: View, Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        heading(title)
                        Spacer(minLength: 12)
                        actions()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        heading(title)
                        actions()
                    }
                }
            }
            OneClickPanel {
                VStack(spacing: 0) {
                    Group(subviews: content()) { rows in
                        ForEach(rows) { row in
                            row
                            if row.id != rows.last?.id {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
            if let footer {
                Text(appLocalized: footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(appLocalized: title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

extension SettingsSection where Actions == EmptyView {
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, footer: footer, actions: { EmptyView() }, content: content)
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 12, content: content)
            .frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}

struct SettingsValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            configuration.content
        }
    }
}

struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(appLocalized: title).accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(AppLocalization.localized(title), isOn: $isOn)
                .labelsHidden()
        }
    }
}

struct SettingsPicker<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: () -> Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(appLocalized: title).accessibilityHidden(true)
            Spacer(minLength: 8)
            Picker(AppLocalization.localized(title), selection: $selection, content: options)
                .labelsHidden()
        }
    }
}

struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    var prompt: Text?

    var body: some View {
        HStack(spacing: 12) {
            Text(appLocalized: title).accessibilityHidden(true)
            Spacer(minLength: 8)
            TextField(AppLocalization.localized(title), text: $text, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(AppLocalization.localized(title))
                .frame(maxWidth: 330)
        }
    }
}

struct SettingsItemLabel<Icon: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 12) {
            icon()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .help(detail ?? title)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsIconButton: View {
    let title: String
    let symbol: String
    var subject: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(AppLocalization.localized(title))
        .accessibilityLabel(AppLocalization.localized(title) + (subject.map { " · " + $0 } ?? ""))
    }
}

struct SettingsEmptyState: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(AppLocalization.localized(title), systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(24)
    }
}

struct SettingsCollection<Item: Identifiable, Actions: View, Row: View>: View where Item.ID == String {
    let title: String
    let items: [Item]
    var emptyTitle: String = "No Items"
    var emptyIcon: String = "list.bullet"
    var move: ((IndexSet, Int) -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var row: (Item, Bool) -> Row

    @State private var reordering = false
    @Namespace private var reorderSpace
    @GestureState private var dragLocation: CGPoint?
    @State private var rowFrames: [String: CGRect] = [:]
    private var canReorder: Bool { move != nil && items.count > 1 }

    var body: some View {
        SettingsSection(
            title: title,
            footer: reordering && canReorder ? "Drag rows or use the arrows to change the order." : nil
        ) {
            HStack(spacing: 8) {
                if canReorder {
                    if reordering {
                        Button(AppLocalization.localized("Done")) { reordering = false }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button(AppLocalization.localized("Reorder")) { reordering = true }
                    }
                }
                if !reordering || !canReorder { actions() }
            }
        } content: {
            if items.isEmpty {
                SettingsEmptyState(title: emptyTitle, symbol: emptyIcon)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if reordering && canReorder {
                        reorderRow(item, index: index)
                    } else {
                        SettingsRow { row(item, false) }
                    }
                }
            }
        }
        .coordinateSpace(.named(reorderSpace))
        .onChange(of: canReorder) {
            if !canReorder { reordering = false }
        }
        .onChange(of: reordering) {
            if !reordering { rowFrames.removeAll() }
        }
    }

    private func reorderRow(_ item: Item, index: Int) -> some View {
        let isTarget = dragLocation.map { rowFrames[item.id]?.contains($0) == true } ?? false

        return SettingsRow {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 28)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named(reorderSpace))
                        .updating($dragLocation) { value, location, _ in location = value.location }
                        .onEnded { value in
                            guard let target = items.firstIndex(where: { rowFrames[$0.id]?.contains(value.location) == true }),
                                  target != index else { return }
                            move?(IndexSet(integer: index), index < target ? target + 1 : target)
                        }
                )
                .accessibilityHidden(true)

            row(item, true)
            SettingsIconButton(title: "Move Up", symbol: "arrow.up") {
                move?(IndexSet(integer: index), index - 1)
            }
            .disabled(index == 0)
            SettingsIconButton(title: "Move Down", symbol: "arrow.down") {
                move?(IndexSet(integer: index), index + 2)
            }
            .disabled(index == items.count - 1)
        }
        .background(isTarget ? Color.accentColor.opacity(0.12) : .clear)
        .onGeometryChange(for: CGRect.self) { [reorderSpace] geometry in
            geometry.frame(in: .named(reorderSpace))
        } action: { frame in
            rowFrames[item.id] = frame
        }
    }
}

struct SettingsSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized: title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8, content: footer)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .buttonStyle(.bordered)
        .toggleStyle(.switch)
        .pickerStyle(.menu)
        .labeledContentStyle(SettingsValueStyle())
    }
}

struct SettingsEditor<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .padding(24)
        }
    }
}
