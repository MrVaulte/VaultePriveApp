//
//  VaultePremiumSettingsViews.swift
//  Vaulté Privé
//

import StoreKit
import SwiftUI

struct PremiumHubView: View {
    let store: OTPStore
    let userId: UUID

    @Bindable private var subscription = VaulteSubscriptionManager.shared
    @State private var restoreNote: String?
    @State private var purchaseBusy = false
    @State private var selectedTier: PremiumPlanTier = .premier
    @State private var flippedTiers: Set<PremiumPlanTier> = []

    @State private var cardAppeared = false
    @State private var shimmerPhase: CGFloat = -1
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var checkoutTier: PremiumPlanTier?

    private let tierOrder: [PremiumPlanTier] = [.free, .premier, .elite]
    private let previewPeriodCycle: TimeInterval = 2.8

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 22) {
                    tierStrip
                        .padding(.top, 4)

                    spotlightCardContainer

                    tierDots
                        .padding(.top, 2)

                    footerBar
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 100)
            }

            subscribeButton
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
        .navigationTitle(VaulteL.t("premium.hub_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(VaulteL.t("premium.hub_title"))
                    .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .task(id: "premium-hub-load") {
            if subscription.products.isEmpty {
                await subscription.loadProducts()
            }
            await subscription.refreshPurchasedEntitlements()
            if subscription.hasEliteAccess {
                selectedTier = .elite
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.82).delay(0.08)) {
                cardAppeared = true
            }
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) {
                shimmerPhase = 2
            }
        }
        .sheet(item: $checkoutTier) { tier in
            PremiumCheckoutSheet(
                tier: tier,
                yearlyProduct: product(for: tier, period: .yearly),
                monthlyProduct: product(for: tier, period: .monthly),
                state: state(for: tier),
                onNote: { restoreNote = $0 }
            )
            .presentationDetents([.fraction(0.58), .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.black)
        }
    }

    private var tierStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(subscription.hasPremiumAccess ? 0.92 : 0.32))
                .frame(width: 6, height: 6)
            Text(VaulteL.t("premium.current_plan").uppercased())
                .font(VaulteTypography.swiftUIFont(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.48))
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 10)
            Text(tierLine)
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.94))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.6)
                )
                .overlay(
                    Group {
                        let l0 = max(0, min(1, shimmerPhase - 0.25))
                        let l1 = max(0, min(1, shimmerPhase))
                        let l2 = max(0, min(1, shimmerPhase + 0.25))
                        let ordered = [l0, l1, l2].sorted()
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: ordered[0]),
                                        .init(color: .white.opacity(0.08), location: ordered[1]),
                                        .init(color: .clear, location: ordered[2]),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
                )
        }
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                Button {
                    Task { await restore() }
                } label: {
                    Text(VaulteL.t("premium.restore"))
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .disabled(purchaseBusy)

                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 3, height: 3)

                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    Link(destination: url) {
                        Text(VaulteL.t("premium.manage_apple"))
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 0)
            }
            if let restoreNote {
                Text(restoreNote)
                    .font(VaulteTypography.swiftUIFont(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            if let err = subscription.lastError, !err.isEmpty {
                Text(err)
                    .font(VaulteTypography.swiftUIFont(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var subscribeButton: some View {
        let isFree   = selectedTier == .free
        let isActive = !isFree && state(for: selectedTier) != .available

        return Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            checkoutTier = selectedTier
        } label: {
            Text("Subscribe")
                .font(VaulteTypography.swiftUIFont(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.8)
                )
        }
        .buttonStyle(.plain)
        .disabled(isActive || isFree)
        .opacity(isFree ? 0 : (isActive ? 0.45 : 1))
        .allowsHitTesting(!isFree && !isActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedTier)
    }

    private var tierLine: String {
        if subscription.hasEliteAccess {
            return VaulteL.t("premium.tier_elite")
        }
        if subscription.hasPremiumAccess {
            return VaulteL.t("premium.tier_premier")
        }
        return VaulteL.t("premium.tier_none")
    }

    @ViewBuilder
    private var spotlightCardContainer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Group {
                if subscription.isLoading && subscription.products.isEmpty {
                    loadingView
                } else {
                    cardsPager(containerWidth: width)
                }
            }
        }
        .aspectRatio(1.9 / 0.82, contentMode: .fit)
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular).tint(.white.opacity(0.78))
            Text(VaulteL.t("common.loading"))
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
    }

    private func cardsPager(containerWidth: CGFloat) -> some View {
        let cardWidth = containerWidth * 0.82
        let cardHeight = cardWidth / 1.9
        let spacing: CGFloat = 22
        let step = cardWidth + spacing
        let sideInset = (containerWidth - cardWidth) / 2
        let selectedIndex = tierOrder.firstIndex(of: selectedTier) ?? 0
        let baseOffset = sideInset - CGFloat(selectedIndex) * step

        let stack = HStack(spacing: spacing) {
            ForEach(Array(tierOrder.enumerated()), id: \.element) { index, tier in
                pagerCard(
                    tier: tier,
                    index: index,
                    selectedIndex: selectedIndex,
                    step: step,
                    cardWidth: cardWidth,
                    cardHeight: cardHeight
                )
            }
        }

        return stack
            .frame(width: containerWidth, height: cardHeight, alignment: .leading)
            .offset(x: baseOffset + dragTranslation)
            .contentShape(Rectangle())
            .highPriorityGesture(pagerDragGesture(selectedIndex: selectedIndex, step: step))
    }

    private func pagerCard(
        tier: PremiumPlanTier,
        index: Int,
        selectedIndex: Int,
        step: CGFloat,
        cardWidth: CGFloat,
        cardHeight: CGFloat
    ) -> some View {
        let rawDistance = CGFloat(index - selectedIndex) - dragTranslation / step
        let distance = abs(rawDistance)
        let alpha = max(0.78, 1 - distance * 0.18)
        let tilt = Double(rawDistance) * 10
        return spotlightCard(for: tier, width: cardWidth)
            .frame(width: cardWidth, height: cardHeight)
            .scaleEffect(1.0)
            .opacity(alpha)
            .rotation3DEffect(
                .degrees(tilt),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.7
            )
    }

    private func pagerDragGesture(selectedIndex: Int, step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if !isDragging { isDragging = true }
                var dx = value.translation.width
                if (selectedIndex == 0 && dx > 0) ||
                    (selectedIndex == tierOrder.count - 1 && dx < 0) {
                    dx *= 0.35
                }
                dragTranslation = dx
            }
            .onEnded { value in
                let predictedX = value.predictedEndTranslation.width
                let threshold = step * 0.18
                var targetIndex = selectedIndex
                if predictedX < -threshold {
                    targetIndex = min(selectedIndex + 1, tierOrder.count - 1)
                } else if predictedX > threshold {
                    targetIndex = max(selectedIndex - 1, 0)
                }
                let newTier = tierOrder[targetIndex]
                #if os(iOS)
                if newTier != selectedTier {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                #endif
                isDragging = false
                withAnimation(.interpolatingSpring(stiffness: 240, damping: 26)) {
                    selectedTier = newTier
                    dragTranslation = 0
                }
            }
    }

    private func spotlightCard(for tier: PremiumPlanTier, width: CGFloat) -> some View {
        let isElite = tier == .elite
        let isFree  = tier == .free
        let state = state(for: tier)
        let flipped = flippedTiers.contains(tier)
        let chamfer = width * 0.12
        let shape = ChamferedCardShape(corner: 24, chamfer: chamfer)

        return ZStack {
            cardFront(tier: tier, isElite: isElite, isFree: isFree, chamfer: chamfer)
                .opacity(flipped ? 0 : 1)
            cardBack(tier: tier, isElite: isElite, isFree: isFree, chamfer: chamfer)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(flipped ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotation3DEffect(
            .degrees(flipped ? 180 : 0),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.65
        )
        .clipShape(shape)
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [
                        .white.opacity(0.55),
                        .white.opacity(0.18),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.2
            )
        )
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 16)
        .scaleEffect(cardAppeared ? 1 : 0.94)
        .opacity(cardAppeared ? 1 : 0)
        .contentShape(shape)
        .onTapGesture {
            guard tier == selectedTier else {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                #endif
                withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                    selectedTier = tier
                }
                return
            }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
            withAnimation(.spring(response: 0.6, dampingFraction: 0.78)) {
                if flippedTiers.contains(tier) {
                    flippedTiers.remove(tier)
                } else {
                    flippedTiers.insert(tier)
                }
            }
        }
    }

    private func cardFront(
        tier: PremiumPlanTier,
        isElite: Bool,
        isFree: Bool = false,
        chamfer: CGFloat
    ) -> some View {
        let tierName: String
        switch tier {
        case .free:    tierName = VaulteL.t("premium.tier_none")
        case .premier: tierName = VaulteL.t("premium.tier_premier")
        case .elite:   tierName = VaulteL.t("premium.tier_elite")
        }
        return ZStack {
            cardFaceBackground(isElite: isElite, isFree: isFree)
            cardSheenOverlay

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    Image("Absolute Cinema")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.white.opacity(0.96))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VAULTÉ PRIVÉ")
                            .font(VaulteTypography.swiftUIFont(size: 10, weight: .bold))
                            .tracking(1.6)
                            .foregroundStyle(.white.opacity(0.82))
                        Text(tierName)
                            .font(VaulteTypography.swiftUIFont(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
                Spacer(minLength: 0)
                if tier == .free {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Free")
                            .font(VaulteTypography.swiftUIFont(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                        Text("forever")
                            .font(VaulteTypography.swiftUIFont(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                } else {
                    animatedPriceBlock(tier: tier)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fallbackPrice(tier: PremiumPlanTier, period: BillingPeriod) -> String {
        switch (tier, period) {
        case (.free, _):           return "Free"
        case (.premier, .monthly): return "$15"
        case (.premier, .yearly):  return "$150"
        case (.elite,   .monthly): return "$50"
        case (.elite,   .yearly):  return "$450"
        }
    }

    private func animatedPriceBlock(tier: PremiumPlanTier) -> some View {
        TimelineView(.periodic(from: .now, by: previewPeriodCycle)) { context in
            let ticks = Int(context.date.timeIntervalSinceReferenceDate / previewPeriodCycle)
            let previewPeriod: BillingPeriod = (ticks % 2 == 0) ? .monthly : .yearly
            let previewProduct = product(for: tier, period: previewPeriod)
            let price = previewProduct?.displayPrice ?? fallbackPrice(tier: tier, period: previewPeriod)
            let label = previewPeriod == .yearly
                ? VaulteL.t("premium.per_year")
                : VaulteL.t("premium.per_month")
            VStack(alignment: .leading, spacing: 2) {
                Text(price)
                    .font(VaulteTypography.swiftUIFont(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(price.hashValue)))
                    .id("price-\(previewPeriod)")
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                Text(label)
                    .font(VaulteTypography.swiftUIFont(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                    .id("label-\(previewPeriod)")
                    .transition(.opacity)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: previewPeriod)
        }
    }

    private func cardBack(
        tier: PremiumPlanTier,
        isElite: Bool,
        isFree: Bool = false,
        chamfer: CGFloat
    ) -> some View {
        let tierName: String
        switch tier {
        case .free:    tierName = VaulteL.t("premium.tier_none")
        case .premier: tierName = VaulteL.t("premium.tier_premier")
        case .elite:   tierName = VaulteL.t("premium.tier_elite")
        }
        return ZStack {
            cardFaceBackground(isElite: isElite, isFree: isFree)
            cardSheenOverlay

            VStack(alignment: .leading, spacing: 0) {
                Text(tierName)
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer(minLength: 12)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(features(for: tier), id: \.self) { feature in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: 4, height: 4)
                            Text(feature)
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.88))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tierDots: some View {
        HStack(spacing: 6) {
            ForEach(PremiumPlanTier.allCases, id: \.self) { tier in
                Capsule()
                    .fill(Color.white.opacity(selectedTier == tier ? 0.88 : 0.22))
                    .frame(width: selectedTier == tier ? 18 : 6, height: 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.82), value: selectedTier)
            }
        }
    }

    private func product(for tier: PremiumPlanTier, period: BillingPeriod) -> Product? {
        let id: String
        switch (tier, period) {
        case (.free, _):
            return nil
        case (.premier, .yearly):
            id = VaulteSubscriptionManager.premierAnnualProductId
        case (.premier, .monthly):
            id = VaulteSubscriptionManager.premierMonthlyProductId
        case (.elite, .yearly):
            id = VaulteSubscriptionManager.eliteAnnualProductId
        case (.elite, .monthly):
            id = VaulteSubscriptionManager.eliteMonthlyProductId
        }
        return subscription.product(id: id)
    }

    private func state(for tier: PremiumPlanTier) -> PremiumOfferState {
        switch tier {
        case .free:
            return .active
        case .elite:
            return subscription.hasEliteAccess ? .active : .available
        case .premier:
            if subscription.hasEliteAccess { return .included }
            if subscription.hasPremiumAccess { return .active }
            return .available
        }
    }

    private func cardFaceBackground(isElite: Bool, isFree: Bool = false) -> some View {
        ZStack {
            LinearGradient(
                colors: isFree
                    ? [Color.white.opacity(0.06), Color.black.opacity(0.72), Color.white.opacity(0.02)]
                    : [Color.white.opacity(0.18), Color.black.opacity(0.55), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.05), location: 0.48),
                    .init(color: .white.opacity(0.09), location: 0.5),
                    .init(color: .white.opacity(0.05), location: 0.52),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
        }
    }

    private var cardSheenOverlay: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let l0 = max(0, min(1, shimmerPhase - 0.18))
            let l1 = max(0, min(1, shimmerPhase))
            let l2 = max(0, min(1, shimmerPhase + 0.18))
            let ordered = [l0, l1, l2].sorted()
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: ordered[0]),
                            .init(color: .white.opacity(0.10), location: ordered[1]),
                            .init(color: .clear, location: ordered[2]),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: W)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }

    private func buttonTitle(for tier: PremiumPlanTier, state: PremiumOfferState) -> String {
        switch state {
        case .active:
            return VaulteL.t("premium.state_active")
        case .included:
            return VaulteL.t("premium.state_included")
        case .available:
            return tier == .elite
                ? VaulteL.t("premium.buy_elite")
                : VaulteL.t("premium.buy_premier")
        }
    }

    private func features(for tier: PremiumPlanTier) -> [String] {
        switch tier {
        case .free:
            return [
                VaulteL.t("premium.feature_free_messages"),
                VaulteL.t("premium.feature_free_e2e"),
                VaulteL.t("premium.feature_free_groups"),
            ]
        case .premier:
            return [
                VaulteL.t("premium.backup_title"),
                VaulteL.t("premium.search_title"),
            ]
        case .elite:
            return [
                VaulteL.t("premium.feature_otp"),
                VaulteL.t("premium.feature_vanish"),
                VaulteL.t("premium.feature_copy"),
                VaulteL.t("premium.devices_title"),
            ]
        }
    }

    private func restore() async {
        purchaseBusy = true
        defer { purchaseBusy = false }
        do {
            try await subscription.restorePurchases()
            restoreNote = VaulteL.t("common.done")
        } catch {
            restoreNote = error.localizedDescription
        }
    }

}

struct ChamferedCardShape: Shape {
    let corner: CGFloat
    let chamfer: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY

        p.move(to: CGPoint(x: minX + corner, y: minY))
        p.addLine(to: CGPoint(x: maxX - chamfer, y: minY))
        p.addLine(to: CGPoint(x: maxX, y: minY + chamfer))
        p.addLine(to: CGPoint(x: maxX, y: maxY - corner))
        p.addArc(
            center: CGPoint(x: maxX - corner, y: maxY - corner),
            radius: corner,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        p.addLine(to: CGPoint(x: minX + corner, y: maxY))
        p.addArc(
            center: CGPoint(x: minX + corner, y: maxY - corner),
            radius: corner,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.addLine(to: CGPoint(x: minX, y: minY + corner))
        p.addArc(
            center: CGPoint(x: minX + corner, y: minY + corner),
            radius: corner,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

private enum PremiumPlanTier: String, CaseIterable, Identifiable {
    case free
    case premier
    case elite
    var id: String { rawValue }
}

private enum BillingPeriod: CaseIterable {
    case yearly
    case monthly
}

private enum PremiumOfferState: Equatable {
    case available
    case active
    case included
}

private struct PremiumCheckoutSheet: View {
    let tier: PremiumPlanTier
    let yearlyProduct: Product?
    let monthlyProduct: Product?
    let state: PremiumOfferState
    let onNote: (String?) -> Void

    @State private var period: BillingPeriod = .monthly
    @State private var busy = false
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss
    @Bindable private var subscription = VaulteSubscriptionManager.shared

    private var tierName: String {
        tier == .elite
            ? VaulteL.t("premium.tier_elite")
            : VaulteL.t("premium.tier_premier")
    }

    private var currentProduct: Product? {
        let id: String
        switch (tier, period) {
        case (.free, _):           return nil
        case (.premier, .yearly):  id = VaulteSubscriptionManager.premierAnnualProductId
        case (.premier, .monthly): id = VaulteSubscriptionManager.premierMonthlyProductId
        case (.elite,   .yearly):  id = VaulteSubscriptionManager.eliteAnnualProductId
        case (.elite,   .monthly): id = VaulteSubscriptionManager.eliteMonthlyProductId
        }
        return subscription.product(id: id)
    }

    private func fallbackPrice(_ p: BillingPeriod) -> String {
        switch (tier, p) {
        case (.free, _):           return "Free"
        case (.premier, .monthly): return "$15"
        case (.premier, .yearly):  return "$150"
        case (.elite,   .monthly): return "$50"
        case (.elite,   .yearly):  return "$450"
        }
    }

    private var priceText: String {
        currentProduct?.displayPrice ?? fallbackPrice(period)
    }

    private var periodLabel: String {
        period == .yearly
            ? VaulteL.t("premium.per_year")
            : VaulteL.t("premium.per_month")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                        .padding(.horizontal, 20)
                    periodChoice
                        .padding(.horizontal, 20)
                    featureList
                        .padding(.horizontal, 20)
                }
                .padding(.top, 22)
                .padding(.bottom, 140)
            }

            floatingCheckout
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            if subscription.products.isEmpty {
                await subscription.loadProducts()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("Absolute Cinema")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(.white.opacity(0.96))
            VStack(alignment: .leading, spacing: 3) {
                Text("VAULTÉ PRIVÉ")
                    .font(VaulteTypography.swiftUIFont(size: 10, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.55))
                Text(tierName)
                    .font(VaulteTypography.swiftUIFont(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
        }
    }

    private var periodChoice: some View {
        HStack(spacing: 10) {
            periodCard(.monthly, label: VaulteL.t("premium.period_monthly"), product: monthlyProduct)
            periodCard(.yearly, label: VaulteL.t("premium.period_yearly"), product: yearlyProduct)
        }
    }

    private func periodCard(_ value: BillingPeriod, label: String, product: Product?) -> some View {
        let selected = period == value
        let price = product?.displayPrice ?? fallbackPrice(value)
        let sub = value == .yearly
            ? VaulteL.t("premium.per_year")
            : VaulteL.t("premium.per_month")
        return Button {
            guard period != value else { return }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            #endif
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                period = value
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(price)
                    .font(VaulteTypography.swiftUIFont(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(sub)
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.08 : 0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(selected ? 0.55 : 0.12),
                                lineWidth: selected ? 1.2 : 0.6
                            )
                    )
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selected)
            }
        }
        .buttonStyle(.plain)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(VaulteL.t("premium.section_features_included"))
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 4, height: 4)
                    Text(feature)
                        .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var features: [String] {
        switch tier {
        case .premier:
            return [
                VaulteL.t("premium.backup_title"),
                VaulteL.t("premium.search_title"),
            ]
        case .elite:
            return [
                VaulteL.t("premium.feature_otp"),
                VaulteL.t("premium.feature_vanish"),
                VaulteL.t("premium.feature_copy"),
                VaulteL.t("premium.devices_title"),
            ]
        case .free:
            return [
                VaulteL.t("premium.feature_free_messages"),
                VaulteL.t("premium.feature_free_e2e"),
                VaulteL.t("premium.feature_free_groups"),
            ]
        }
    }

    private var ctaTitle: String {
        switch state {
        case .active:
            return VaulteL.t("premium.state_active")
        case .included:
            return VaulteL.t("premium.state_included")
        case .available:
            return VaulteL.t("premium.subscribe_cta")
        }
    }

    @ViewBuilder
    private var floatingCheckout: some View {
        VStack(spacing: 10) {
            if let errorText {
                Text(errorText)
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                Task { await purchase() }
            } label: {
                HStack(spacing: 10) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(ctaTitle)
                        .font(VaulteTypography.swiftUIFont(size: 15, weight: .semibold))
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 3, height: 3)
                    HStack(spacing: 6) {
                        Text(priceText)
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .semibold))
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: priceText)
                        Text("/")
                            .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(periodLabel)
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.45),
                                            .white.opacity(0.12),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.8
                                )
                        )
                }
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .disabled(state != .available || busy)
            .opacity(state == .available ? 1 : 0.55)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: errorText)
    }

    private func purchase() async {
        guard let product = currentProduct else {
            errorText = "Products not loaded yet. Try again."
            return
        }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            try await subscription.purchase(product)
            onNote(nil)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            onNote(error.localizedDescription)
        }
    }
}

struct SecurityPolicyMarkdownView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(VaulteSecurityPolicyCopy.intro)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(VaulteSecurityPolicyCopy.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(section.body)
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(VaultePalette.ink.ignoresSafeArea())
        .navigationTitle(VaulteSecurityPolicyCopy.documentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WhitepaperView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(VaulteWhitepaperCopy.documentSubtitle.uppercased())
                        .font(VaulteTypography.swiftUIFont(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.42))
                    Text("Version \(VaulteWhitepaperCopy.version)")
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.52))
                }

                Text(VaulteWhitepaperCopy.abstract)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(VaulteWhitepaperCopy.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(section.body)
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .trailing, spacing: 6) {
                    Image("Signature")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 204)
                        .opacity(0.82)
                    Text("Last updated \(VaulteWhitepaperCopy.lastUpdated)")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Technical supplements")
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.8)

                    ForEach(VaulteImplementationDocsCopy.documents) { document in
                        NavigationLink {
                            ImplementationDocDetailView(document: document)
                        } label: {
                            ImplementationDocFileRow(document: document)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(VaultePalette.ink.ignoresSafeArea())
        .navigationTitle(VaulteWhitepaperCopy.documentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ImplementationDocDetailView: View {
    let document: VaulteImplementationDocsCopy.Document

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(document.intro)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(section.body)
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(VaultePalette.ink.ignoresSafeArea())
        .navigationTitle(document.fileName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ImplementationDocFileRow: View {
    let document: VaulteImplementationDocsCopy.Document

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(document.title)
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        }
    }
}

struct PrivacyPolicyMarkdownView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(VaultePrivacyPolicyCopy.intro)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(VaultePrivacyPolicyCopy.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                        Text(section.body)
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .trailing, spacing: 6) {
                    Image("Signature")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 204)
                        .opacity(0.82)
                    Text("Last updated \(VaultePrivacyPolicyCopy.lastUpdated)")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Implementation")
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .tracking(0.8)

                    ForEach(VaulteImplementationDocsCopy.documents) { document in
                        NavigationLink {
                            ImplementationDocDetailView(document: document)
                        } label: {
                            ImplementationDocFileRow(document: document)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(VaultePalette.ink.ignoresSafeArea())
        .navigationTitle(VaultePrivacyPolicyCopy.documentTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PremiumBackupExportView: View {
    let store: OTPStore
    @Bindable private var subscription = VaulteSubscriptionManager.shared
    @State private var passphrase = ""
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        Form {
            if !subscription.hasPremiumAccess {
                Text(VaulteL.t("premium.backup_need_sub"))
                    .foregroundStyle(.secondary)
            }
            SecureField(VaulteL.t("premium.backup_passphrase"), text: $passphrase)
                .disabled(!subscription.hasPremiumAccess)
            Button(VaulteL.t("premium.backup_export")) {
                Task { await runExport() }
            }
            .disabled(!subscription.hasPremiumAccess || passphrase.count < 8)
            Text(VaulteL.t("premium.backup_footer"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let exportError {
                Text(exportError).foregroundStyle(.red.opacity(0.85))
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label(VaulteL.t("common.save"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(VaulteL.t("premium.backup_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runExport() async {
        exportError = nil
        exportURL = nil
        do {
            let result = try VaulteEncryptedBackupExporter.exportEncryptedArchive(passphrase: passphrase)
            exportURL = result.fileURL
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct PremiumMessageSearchView: View {
    let store: OTPStore
    let userId: UUID
    @Bindable private var subscription = VaulteSubscriptionManager.shared
    @State private var query = ""
    @State private var hits: [OTPMessageSearchHit] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !subscription.hasPremiumAccess {
                Text(VaulteL.t("premium.search_need_sub"))
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(hits, id: \.messageId) { hit in
                        NavigationLink {
                            ChatScreen(store: store, conversationId: hit.conversationId, userId: userId)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.preview)
                                    .lineLimit(2)
                                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                                Text(hit.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .searchable(text: $query, prompt: VaulteL.t("premium.search_placeholder"))
                .onChange(of: query) { _, newValue in
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 280_000_000)
                        guard !Task.isCancelled else { return }
                        await runSearch(newValue)
                    }
                }
            }
        }
        .navigationTitle(VaulteL.t("premium.search_title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runSearch(_ raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run { hits = [] }
            return
        }
        let found = (try? await store.searchDecryptedMessages(normalizedNeedle: trimmed)) ?? []
        await MainActor.run { hits = found }
    }
}

private struct PremiumDevicesView: View {
    @Bindable private var subscription = VaulteSubscriptionManager.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("ID") {
                    Text(VaulteLocalDeviceIdentity.deviceId.uuidString)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent(VaulteL.t("common.name")) {
                    Text(VaulteLocalDeviceIdentity.deviceMarketingName)
                        .font(.body)
                }
            } header: {
                Text(VaulteL.t("premium.devices_title"))
            }
            if !subscription.hasEliteAccess {
                Text(VaulteL.t("premium.devices_elite_only"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(VaulteL.t("premium.devices_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

