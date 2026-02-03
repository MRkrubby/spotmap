import SwiftUI

// MARK: - Brand tokens

enum SpotBrand {
    static let corner: CGFloat = 18
    static let pillCorner: CGFloat = 999
    static let shadowRadius: CGFloat = 10

    // Compact sizing (user feedback: "minder groot")
    static let circleButtonSize: CGFloat = 36
    static let fabSize: CGFloat = 50
    static let iconSize: CGFloat = 15
}

// MARK: - Buttons

/// Small circular icon button used throughout the app.
///
/// Previously this used a custom DragGesture for "press" events which could
/// interfere with taps on some devices. Using a `ButtonStyle` makes the
/// press state reliable and keeps all buttons responsive.
struct SpotCircleButton: View {
    let systemImage: String
    var accessibilityLabel: String
    var action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 15

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: SpotBrand.circleButtonSize, height: SpotBrand.circleButtonSize)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                .shadow(radius: 6)
        }
        .buttonStyle(SpotPressScaleStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SpotPressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct SpotPill: View {
    let text: String
    var icon: String? = nil
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6)
    }
}

// MARK: - Top bar

struct SpotTopBar: View {
    let backendTitle: String
    @Binding var searchText: String
    let onTapLocation: () -> Void
    let onTapList: () -> Void
    let onTapSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("SpotMap")
                            .font(.headline.weight(.bold))
                        Text(backendTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie", action: onTapLocation)
                    SpotCircleButton(systemImage: "list.bullet", accessibilityLabel: "Lijst", action: onTapList)
                    SpotCircleButton(systemImage: "gearshape", accessibilityLabel: "Instellingen", action: onTapSettings)
                }
            }

            SpotSearchBar(text: $searchText)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }
}

// MARK: - Search

struct SpotSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Zoek spot…", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}

// MARK: - Loading

struct SpotLoadingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 6)
    }
}

// MARK: - Bottom bar

struct SpotBottomBar: View {
    let count: Int
    let backend: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            SpotPill(text: "\(count) spots", icon: "mappin.and.ellipse")
            Spacer(minLength: 0)

            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }
}

// MARK: - Floating menu

struct SpotFabMenu: View {
    // Custom result builder so call sites can list items naturally (without array brackets)
    // e.g. SpotFabMenu { Item(...); Item(...); ... }
    @resultBuilder
    struct ItemBuilder {
        // Component is `[Item]` so we can easily flatten and support if/for.
        static func buildExpression(_ expression: Item) -> [Item] { [expression] }
        static func buildExpression(_ expression: [Item]) -> [Item] { expression }
        static func buildBlock(_ components: [Item]...) -> [Item] { components.flatMap { $0 } }
        static func buildOptional(_ component: [Item]?) -> [Item] { component ?? [] }
        static func buildEither(first component: [Item]) -> [Item] { component }
        static func buildEither(second component: [Item]) -> [Item] { component }
        static func buildArray(_ components: [[Item]]) -> [Item] { components.flatMap { $0 } }
    }

    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let action: () -> Void
        init(title: String, systemImage: String, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }
    }

    @Binding var isOpen: Bool
    private let items: () -> [Item]
    @ScaledMetric(relativeTo: .caption) private var menuIconSize: CGFloat = 14
    @ScaledMetric(relativeTo: .headline) private var fabIconSize: CGFloat = 17

    init(isOpen: Binding<Bool>, @ItemBuilder items: @escaping () -> [Item]) {
        self._isOpen = isOpen
        self.items = items
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isOpen {
                ForEach(items()) { item in
                    Button {
                        // Ensure the menu closes reliably even if the caller forgets.
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                            isOpen = false
                        }
                        item.action()
                    } label: {
                        HStack(spacing: 10) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            Image(systemName: item.systemImage)
                                .font(.system(size: menuIconSize, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.thinMaterial)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.10)))
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isOpen.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        .frame(width: SpotBrand.fabSize, height: SpotBrand.fabSize)
                        .shadow(radius: 8)

                    Image(systemName: isOpen ? "xmark" : "plus")
                        .font(.system(size: fabIconSize, weight: .bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Sluit menu" : "Open menu")
        }
    }
}

// MARK: - Home (clean, foreground-first)

struct HomeHeaderBar: View {
    let backendTitle: String
    let onTapLocation: () -> Void
    let onTapSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("SpotMap")
                        .font(.headline.weight(.bold))
                    Text(backendTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie", action: onTapLocation)
                SpotCircleButton(systemImage: "gearshape", accessibilityLabel: "Instellingen", action: onTapSettings)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 8)
    }
}

struct HomeBottomSheet: View {
    let backendTitle: String
    let spotCount: Int
    let isRecording: Bool

    let onNavigate: () -> Void
    let onAddSpot: () -> Void
    let onShowSpots: () -> Void
    let onDriveMode: () -> Void
    let onOpenJourneys: () -> Void
    let recentJourneys: [JourneyRecord]

    let onToggleJourney: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void

    let previewSpots: [Spot]
    let onSelectSpot: (Spot) -> Void

    @State private var expanded = true

    var body: some View {
        VStack(spacing: 10) {
            // Handle
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 44, height: 5)
                .padding(.top, 6)
                .onTapGesture {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                        expanded.toggle()
                    }
                }

            // Search destination (button-style)
            Button {
                onNavigate()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Zoek bestemming")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            // Quick actions (compact chips)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    HomeActionChip(title: "Spots", systemImage: "list.bullet") { onShowSpots() }
                    HomeActionChip(title: "Nieuwe spot", systemImage: "mappin.and.ellipse") { onAddSpot() }
                    HomeActionChip(title: "Drive", systemImage: "steeringwheel") { onDriveMode() }
                    HomeActionChip(title: "Ritten", systemImage: "car") { onOpenJourneys() }
                    HomeActionChip(title: isRecording ? "Stop rit" : "Start rit",
                                   systemImage: isRecording ? "stop.fill" : "record.circle") {
                        onToggleJourney()
                    }

                    Menu {
                        Button { onRefresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button { onOpenSettings() } label: { Label("Instellingen", systemImage: "gearshape") }
                    } label: {
                        HomeActionChipLabel(title: "Meer", systemImage: "ellipsis")
                    }
                }
                .padding(.vertical, 2)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Dichtbij")
                            .font(.subheadline.weight(.bold))
                        Spacer(minLength: 0)
                        Button {
                            onShowSpots()
                        } label: {
                            Text("Alles")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    if previewSpots.isEmpty {
                        Text("Nog geen spots. Maak er één aan of refresh je omgeving.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(previewSpots) { spot in
                                Button {
                                    onSelectSpot(spot)
                                } label: {
                                    HomeSpotRow(spot: spot)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider().opacity(0.45)

                    HStack {
                        Text("Ritten")
                            .font(.subheadline.weight(.bold))
                        Spacer(minLength: 0)
                        Button {
                            onOpenJourneys()
                        } label: {
                            Text("Alles")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    if recentJourneys.isEmpty {
                        Text("Nog geen ritten. Start een rit om te loggen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(recentJourneys.prefix(2)) { r in
                                HomeJourneyRow(record: r)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Status row
            HStack(spacing: 10) {
                Text("\(spotCount) spots")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(backendTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, height: 28)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(radius: 12)
    }
}

private struct HomeActionChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HomeActionChipLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(SpotPressScaleStyle())
    }
}

private struct HomeActionChipLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
    }
}

private struct HomeSpotRow: View {
    let spot: Spot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(spot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if !spot.note.isEmpty {
                    Text(spot.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}

private struct HomeJourneyRow: View {
    let record: JourneyRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "car")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("Duur \(JourneyFormat.duration(record.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)

            Text(JourneyFormat.km(record.distanceMeters))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}
