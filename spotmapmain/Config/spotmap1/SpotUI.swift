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

// MARK: - Design tokens

enum SpotDesign {
    enum Spacing {
        static let none: CGFloat = 0
        static let xxxs: CGFloat = 1
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
    }

    enum CornerRadius {
        static let control: CGFloat = 14
        static let card: CGFloat = 16
        static let pill: CGFloat = 18
        static let input: CGFloat = 20
        static let panel: CGFloat = 22
        static let sheet: CGFloat = 24
        static let overlay: CGFloat = 26
    }

    enum Elevation {
        static let surfaceMaterial: Material = .ultraThinMaterial
        static let controlMaterial: Material = .thinMaterial
        static let outlineStrongOpacity: Double = 0.12
        static let outlineSoftOpacity: Double = 0.10

        static let shadowLow: CGFloat = 6
        static let shadowMedium: CGFloat = 8
        static let shadowPanel: CGFloat = 10
        static let shadowHigh: CGFloat = 12
    }
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

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: SpotBrand.iconSize, weight: .semibold))
                .frame(width: SpotBrand.circleButtonSize, height: SpotBrand.circleButtonSize)
                .background(SpotDesign.Elevation.surfaceMaterial)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
                .shadow(radius: SpotDesign.Elevation.shadowLow)
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

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.md) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, SpotDesign.Spacing.sm)
        .padding(.horizontal, SpotDesign.Spacing.lg)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowLow)
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
        VStack(spacing: SpotDesign.Spacing.lg) {
            HStack(spacing: SpotDesign.Spacing.xl) {
                HStack(spacing: SpotDesign.Spacing.lg) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                        Text("SpotMap")
                            .font(.system(size: 17, weight: .bold))
                        Text(backendTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)

                HStack(spacing: SpotDesign.Spacing.lg) {
                    SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie", action: onTapLocation)
                    SpotCircleButton(systemImage: "list.bullet", accessibilityLabel: "Lijst", action: onTapList)
                    SpotCircleButton(systemImage: "gearshape", accessibilityLabel: "Instellingen", action: onTapSettings)
                }
            }

            SpotSearchBar(text: $searchText)
        }
        .padding(SpotDesign.Spacing.lg)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowMedium)
    }
}

// MARK: - Search

struct SpotSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
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
        .padding(.vertical, SpotDesign.Spacing.md)
        .padding(.horizontal, SpotDesign.Spacing.lg)
        .background(SpotDesign.Elevation.controlMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.control, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
    }
}

// MARK: - Loading

struct SpotLoadingPill: View {
    let text: String

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
            ProgressView()
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.vertical, SpotDesign.Spacing.md)
        .padding(.horizontal, SpotDesign.Spacing.xl)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowLow)
    }
}

// MARK: - Bottom bar

struct SpotBottomBar: View {
    let count: Int
    let backend: String
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
            SpotPill(text: "\(count) spots", icon: "mappin.and.ellipse")
            Spacer(minLength: 0)

            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .padding(.vertical, SpotDesign.Spacing.md)
                    .padding(.horizontal, SpotDesign.Spacing.lg)
                    .background(SpotDesign.Elevation.surfaceMaterial)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
        .padding(SpotDesign.Spacing.lg)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowMedium)
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

    init(isOpen: Binding<Bool>, @ItemBuilder items: @escaping () -> [Item]) {
        self._isOpen = isOpen
        self.items = items
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: SpotDesign.Spacing.xl) {
            if isOpen {
                ForEach(items()) { item in
                    Button {
                        // Ensure the menu closes reliably even if the caller forgets.
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                            isOpen = false
                        }
                        item.action()
                    } label: {
                        HStack(spacing: SpotDesign.Spacing.lg) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            Image(systemName: item.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(SpotDesign.Elevation.controlMaterial)
                                .clipShape(Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
                        }
                        .padding(.vertical, SpotDesign.Spacing.md)
                        .padding(.horizontal, SpotDesign.Spacing.lg)
                        .background(SpotDesign.Elevation.surfaceMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
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
                        .fill(SpotDesign.Elevation.surfaceMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
                        .frame(width: SpotBrand.fabSize, height: SpotBrand.fabSize)
                        .shadow(radius: SpotDesign.Elevation.shadowMedium)

                    Image(systemName: isOpen ? "xmark" : "plus")
                        .font(.system(size: 17, weight: .bold))
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
        HStack(spacing: SpotDesign.Spacing.xl) {
            HStack(spacing: SpotDesign.Spacing.lg) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxxs) {
                    Text("SpotMap")
                        .font(.system(size: 16, weight: .bold))
                    Text(backendTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: SpotDesign.Spacing.lg) {
                SpotCircleButton(systemImage: "location.fill", accessibilityLabel: "Naar mijn locatie", action: onTapLocation)
                SpotCircleButton(systemImage: "gearshape", accessibilityLabel: "Instellingen", action: onTapSettings)
            }
        }
        .padding(SpotDesign.Spacing.lg)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotBrand.corner, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowMedium)
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
        VStack(spacing: SpotDesign.Spacing.lg) {
            // Handle
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 44, height: 5)
                .padding(.top, SpotDesign.Spacing.sm)
                .onTapGesture {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                        expanded.toggle()
                    }
                }

            // Search destination (button-style)
            Button {
                onNavigate()
            } label: {
                HStack(spacing: SpotDesign.Spacing.lg) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    Text("Zoek bestemming")
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, SpotDesign.Spacing.lg)
                .padding(.horizontal, SpotDesign.Spacing.xl)
                .background(SpotDesign.Elevation.controlMaterial, in: RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
            }
            .buttonStyle(.plain)

            // Quick actions (compact chips)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SpotDesign.Spacing.md) {
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
                .padding(.vertical, SpotDesign.Spacing.xxs)
            }

            if expanded {
                VStack(alignment: .leading, spacing: SpotDesign.Spacing.md) {
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
                            .padding(.vertical, SpotDesign.Spacing.sm)
                    } else {
                        VStack(spacing: SpotDesign.Spacing.sm) {
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
                            .padding(.vertical, SpotDesign.Spacing.xxs)
                    } else {
                        VStack(spacing: SpotDesign.Spacing.sm) {
                            ForEach(recentJourneys.prefix(2)) { r in
                                HomeJourneyRow(record: r)
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Status row
            HStack(spacing: SpotDesign.Spacing.lg) {
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
        .padding(SpotDesign.Spacing.xl)
        .background(SpotDesign.Elevation.surfaceMaterial)
        .clipShape(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.sheet, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.sheet, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineStrongOpacity)))
        .shadow(radius: SpotDesign.Elevation.shadowHigh)
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
            .padding(.vertical, SpotDesign.Spacing.md)
            .padding(.horizontal, SpotDesign.Spacing.lg)
            .background(SpotDesign.Elevation.controlMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
    }
}

private struct HomeSpotRow: View {
    let spot: Spot

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
            Image(systemName: "mappin.and.ellipse")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                Text(spot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                if !spot.note.isEmpty {
                    Text(spot.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, SpotDesign.Spacing.lg)
        .padding(.horizontal, SpotDesign.Spacing.xl)
        .background(SpotDesign.Elevation.controlMaterial, in: RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
    }
}

private struct HomeJourneyRow: View {
    let record: JourneyRecord

    var body: some View {
        HStack(spacing: SpotDesign.Spacing.lg) {
            Image(systemName: "car")
                .font(.subheadline.weight(.semibold))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: SpotDesign.Spacing.xxs) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Duur \(JourneyFormat.duration(record.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(JourneyFormat.km(record.distanceMeters))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, SpotDesign.Spacing.lg)
        .padding(.horizontal, SpotDesign.Spacing.xl)
        .background(SpotDesign.Elevation.controlMaterial, in: RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SpotDesign.CornerRadius.card, style: .continuous).strokeBorder(.white.opacity(SpotDesign.Elevation.outlineSoftOpacity)))
    }
}
