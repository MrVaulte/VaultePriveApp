//
//  ApplicationViews.swift
//  Vaulté Privé
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Enhanced Registration Components

enum RegistrationStep: CaseIterable {
    case mainPassphrase
    case panicPassphrase
    case usernameSelection
    case welcomeAnimation
    var title: String {
        switch self {
        case .mainPassphrase: return "Create Main Passphrase"
        case .panicPassphrase: return "Create Panic Phrase"
        case .usernameSelection: return "Choose Username"
        case .welcomeAnimation: return ""
        }
    }
    
    var description: String {
        switch self {
        case .mainPassphrase: return "This will be your primary login passphrase"
        case .panicPassphrase: return "Emergency phrase to reset your account"
        case .usernameSelection: return "Your unique identifier in Vaulté"
        case .welcomeAnimation: return ""
        }
    }
    
    var stepNumber: Int {
        switch self {
        case .mainPassphrase: return 1
        case .panicPassphrase: return 2
        case .usernameSelection: return 3
        case .welcomeAnimation: return 4
        }
    }
}

import UIKit
import ImageIO
import PhotosUI
import LocalAuthentication
import CryptoKit
import CoreImage
#if os(macOS)
import AppKit
#endif
internal import Combine

// MARK: - Typography

enum VaulteTypography {
    private static let regular = "AMTypewriter"
    private static let bold = "AMTypewriter-Bold"
    private static let light = "AMTypewriter-Light"

    enum Weight {
        case regular
        case light
        case semibold
        case bold
    }

    static func swiftUIFont(size: CGFloat, weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = regular
        case .light: name = light
        case .semibold, .bold: name = bold
        }
        if UIFont(name: name, size: size) != nil {
            return Font.custom(name, size: size)
        }
        let fallback = weight == .light ? "AmericanTypewriter-Light" : (weight == .regular ? "AmericanTypewriter" : "AmericanTypewriter-Bold")
        return Font.custom(fallback, size: size)
    }

    static func uiFont(size: CGFloat, weight: Weight = .regular) -> UIFont {
        let name: String
        switch weight {
        case .regular: name = regular
        case .light: name = light
        case .semibold, .bold: name = bold
        }
        if let f = UIFont(name: name, size: size) { return f }
        switch weight {
        case .regular: return .systemFont(ofSize: size, weight: .regular)
        case .light: return .systemFont(ofSize: size, weight: .light)
        case .semibold: return .systemFont(ofSize: size, weight: .semibold)
        case .bold: return .systemFont(ofSize: size, weight: .bold)
        }
    }

    static func applyUIKitAppearances() {
        let body = uiFont(size: 17, weight: .regular)
        let tabCaption = uiFont(size: 10, weight: .regular)
        let navTitle = uiFont(size: 17, weight: .bold)
        let navLarge = uiFont(size: 34, weight: .bold)

        UILabel.appearance(whenContainedInInstancesOf: [UITableView.self]).font = body

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(VaultePalette.ink)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.font: navTitle]
        nav.largeTitleTextAttributes = [.font: navLarge]

        let navBar = UINavigationBar.appearance()
        navBar.standardAppearance = nav
        navBar.compactAppearance = nav
        navBar.scrollEdgeAppearance = nav
        navBar.tintColor = UIColor(VaultePalette.gold)

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(VaultePalette.ink)
        tab.shadowColor = .clear
        tab.stackedLayoutAppearance.normal.iconColor = UIColor(VaultePalette.mist)
        tab.stackedLayoutAppearance.selected.iconColor = UIColor(VaultePalette.gold)
        tab.stackedLayoutAppearance.normal.titleTextAttributes = [
            .font: tabCaption,
            .foregroundColor: UIColor(VaultePalette.mist)
        ]
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [
            .font: tabCaption,
            .foregroundColor: UIColor(VaultePalette.gold)
        ]
        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = tab
        tabBar.scrollEdgeAppearance = tab
        tabBar.tintColor = UIColor(VaultePalette.gold)

        UITabBarItem.appearance().setTitleTextAttributes([.font: tabCaption], for: .normal)
        UITextField.appearance().font = body
        UISegmentedControl.appearance().setTitleTextAttributes([.font: body], for: .normal)

        let barButton = uiFont(size: 17, weight: .regular)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: barButton, .foregroundColor: UIColor(VaultePalette.gold)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: barButton, .foregroundColor: UIColor(VaultePalette.gold)], for: .highlighted)
    }
}

enum VaultePalette {
    static let ink = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let gold = Color.white
    static let mist = Color.white.opacity(0.62)
    static let surface = Color.white.opacity(0.06)
    static let surfaceStrong = Color.white.opacity(0.1)
    static let border = Color.white.opacity(0.14)
    static let borderStrong = Color.white.opacity(0.28)
}

// MARK: - Verification badge cache + view

@Observable
final class BadgeCache: @unchecked Sendable {
    static let shared = BadgeCache()
    private(set) var badges: [UUID: BadgeType] = [:]
    private var lastFetch: Date = .distantPast

    func refresh() async {
        guard Date().timeIntervalSince(lastFetch) > 60 else { return }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let map = try await client.fetchAllBadges()
            await MainActor.run { self.badges = map }
            lastFetch = Date()
        } catch {}
    }

    func badge(for userId: UUID) -> BadgeType? {
        badges[userId]
    }
}

/// Small «brilliant» gem: soft bloom, facet-like gradient, sparkle glints (owner tier).
private struct VaulteBrilliantDiamondGlyph: View {
    var fontSize: CGFloat = 13

    var body: some View {
        let s = fontSize
        let diamondFont = s + 0.5
        let spark1 = max(4, s * 0.42)
        let spark2 = max(3, s * 0.3)
        return ZStack {
            Image(systemName: "diamond.fill")
                .font(.system(size: diamondFont + 1.2, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.5, green: 0.78, blue: 1),
                            Color(red: 0.82, green: 0.5, blue: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: 2.8)
                .opacity(0.5)
            Image(systemName: "diamond.fill")
                .font(.system(size: diamondFont, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: Color(red: 0.88, green: 0.94, blue: 1), location: 0.18),
                            .init(color: Color(red: 0.52, green: 0.74, blue: 1), location: 0.42),
                            .init(color: Color(red: 0.96, green: 0.98, blue: 1), location: 0.58),
                            .init(color: Color(red: 0.68, green: 0.58, blue: 1), location: 0.78),
                            .init(color: .white, location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkle")
                .font(.system(size: spark1, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.9), radius: 1, y: 0)
                .offset(x: s * 0.4, y: -s * 0.38)
            Image(systemName: "sparkle")
                .font(.system(size: spark2, weight: .heavy))
                .foregroundStyle(Color.white.opacity(0.95))
                .offset(x: -s * 0.34, y: s * 0.3)
        }
        .accessibilityHidden(true)
        .shadow(color: Color(red: 0.62, green: 0.86, blue: 1).opacity(0.7), radius: 3.5 + s * 0.08, y: 0)
    }
}

private struct VerifiedBadgeGlyph: View {
    let badgeType: BadgeType

    var body: some View {
        switch badgeType {
        case .verified:
            Image(systemName: "crown.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: .white.opacity(0.5), radius: 4, y: 1)
        case .official:
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: .white.opacity(0.5), radius: 4, y: 1)
        case .diamond:
            Image("OwnerBadge")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .shadow(color: .white.opacity(0.22), radius: 3, y: 1)
        }
    }
}

struct VerifiedBadgeView: View {
    let badgeType: BadgeType
    @State private var showInfo = false

    private var label: String {
        switch badgeType {
        case .official: return VaulteL.t("verified.official_account")
        case .verified: return VaulteL.t("verified.premium_account")
        case .diamond: return VaulteL.t("verified.owner_account")
        }
    }

    private var detail: String {
        switch badgeType {
        case .official: return VaulteL.t("verified.official_detail")
        case .verified: return VaulteL.t("verified.premium_detail")
        case .diamond: return VaulteL.t("verified.owner_detail")
        }
    }

    var body: some View {
        Button {
            showInfo = true
        } label: {
            VerifiedBadgeGlyph(badgeType: badgeType)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .alert(label, isPresented: $showInfo) {
            Button(VaulteL.t("common.ok"), role: .cancel) {}
        } message: {
            Text(detail)
        }
    }
}

// MARK: - Glass chrome


// MARK: - Sheet chrome

private struct AbsoluteCinemaSheetRoot<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            StarfieldBackdrop()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            content()
        }
    }
}
    

#if os(macOS)
private struct FixedMacWindowConfigurator: ViewModifier {
    let fixedSize: NSSize

    func body(content: Content) -> some View {
        content.background(WindowConfigurator(fixedSize: fixedSize))
    }

    private struct WindowConfigurator: NSViewRepresentable {
        let fixedSize: NSSize

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                if let window = view.window ?? NSApp.windows.first {
                    window.setContentSize(fixedSize)
                    window.center()
                    window.styleMask.remove([.resizable, .fullScreen])
                    window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
                    window.standardWindowButton(.zoomButton)?.isEnabled = false
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                    window.tabbingMode = .disallowed
                    window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
                    window.standardWindowButton(.closeButton)?.isEnabled = true
                    window.isMovableByWindowBackground = true
                }
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                if let window = nsView.window ?? NSApp.windows.first {
                    window.setContentSize(fixedSize)
                    window.center()
                    window.styleMask.remove([.resizable, .fullScreen])
                    window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
                    window.standardWindowButton(.zoomButton)?.isEnabled = false
                    window.standardWindowButton(.zoomButton)?.isHidden = true
                    window.tabbingMode = .disallowed
                }
            }
        }
    }
}

private extension View {
    func fixedMacWindow(width: CGFloat = 720, height: CGFloat = 520) -> some View {
        modifier(FixedMacWindowConfigurator(fixedSize: NSSize(width: width, height: height)))
    }
}
#endif

// MARK: - Post-registration welcome flow

/// Two-stage animated welcome shown right after username selection.
///   Stage 0: Language picker (EN / FR / DE)
///   Stage 1: Full-screen logo animation + "Welcome To Vaulté Privé"
///
/// When stage 1 starts, `hideChrome` is set to `true` — the parent hides
/// the brand header and step indicator so only the animation is visible.
struct PostRegistrationWelcomeView: View {
    /// Set to `true` when the animation stage begins; parent hides header/indicator.
    @Binding var hideChrome: Bool
    let onComplete: () -> Void

    @State private var stage: Int = 0
    @State private var selectedLanguage: String = VaulteAppLanguage.shared.code
    @State private var didAdvanceFromLanguagePicker = false

    // Animation states
    @State private var logoScale: CGFloat = 0.45
    @State private var logoOffset: CGFloat = 0
    @State private var titleOpacity: Double = 0
    @State private var tapHintOpacity: Double = 0

    var body: some View {
        Group {
            if stage == 0 {
                languageStage
                    .transition(.opacity)
            } else {
                animationStage
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: stage)
    }

    // MARK: Stage 0 — language picker

    private var languageStage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your language")
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text("You can change this later in settings.")
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            VStack(spacing: 10) {
                ForEach([("en", "English"), ("fr", "Français"), ("de", "Deutsch")], id: \.0) { code, name in
                    Button {
                        selectedLanguage = code
                    } label: {
                        HStack {
                            Text(name)
                                .font(VaulteTypography.swiftUIFont(
                                    size: 15,
                                    weight: selectedLanguage == code ? .bold : .regular
                                ))
                                .foregroundStyle(
                                    selectedLanguage == code ? Color.white : Color.white.opacity(0.55)
                                )
                            Spacer()
                            if selectedLanguage == code {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(selectedLanguage == code ? 0.15 : 0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            Color.white.opacity(selectedLanguage == code ? 0.40 : 0.16),
                                            lineWidth: 1
                                        )
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                guard !didAdvanceFromLanguagePicker else { return }
                didAdvanceFromLanguagePicker = true
                VaulteAppLanguage.shared.setCode(selectedLanguage)
                withAnimation(.easeInOut(duration: 0.45)) {
                    hideChrome = true
                    stage = 1
                }
                startLogoAnimation()
            } label: {
                Text("Continue")
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                            )
                    }
            }
            .buttonStyle(.plain)
            .disabled(didAdvanceFromLanguagePicker)
            .vaulteCTAGlow()
            .padding(.top, 8)
        }
    }

    // MARK: Stage 1 — full-screen logo animation + welcome text

    private var animationStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                Image("Absolute Cinema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.white)
                    .scaleEffect(logoScale)
                    .offset(y: logoOffset)

                Text("Welcome To Vaulté Privé")
                    .font(VaulteTypography.swiftUIFont(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .opacity(titleOpacity)
            }

            Spacer(minLength: 0)

            Text("Tap to continue")
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.5))
                .opacity(tapHintOpacity)
                .padding(.bottom, 36)
                .onTapGesture { onComplete() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Animation sequence

    private func startLogoAnimation() {
        logoScale = 0.45
        logoOffset = 0
        titleOpacity = 0
        tapHintOpacity = 0

        withAnimation(.spring(response: 0.72, dampingFraction: 0.68).delay(0.2)) {
            logoScale = 1.0
        }
        withAnimation(.easeInOut(duration: 1.1).delay(0.9)) {
            logoOffset = -30
        }
        withAnimation(.easeIn(duration: 0.9).delay(1.2)) {
            titleOpacity = 1.0
        }
        withAnimation(.easeIn(duration: 0.7).delay(2.5)) {
            tapHintOpacity = 1.0
        }
    }
}

// MARK: - Glow modifier for primary CTA buttons

private extension View {
    /// Visible white glow using blurred stroke layers rendered *behind* the button.
    /// Works on semi-transparent fills where plain `.shadow` would be too faint.
    func vaulteCTAGlow(color: Color = VaultePalette.gold, cornerRadius: CGFloat = 14) -> some View {
        self
            // tight inner halo
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .blur(radius: 5)
                    .padding(-3)
            )
            // wide outer bloom
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.18), lineWidth: 5)
                    .blur(radius: 14)
                    .padding(-9)
            )
    }
}

// MARK: - Relay login


struct RelayConnectLoginView: View {
    let store: OTPStore
    var onAuthenticated: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("vaulteprive.relay.setupComplete") private var setupComplete = false
    @AppStorage("vaulteprive.auth.biometricEnabled") private var biometricEnabled = false

    @State private var setupWizardStep = 1
    @State private var setupPass1 = ""
    @State private var setupPass2 = ""
    @State private var showSetupPass1 = false
    @State private var setupBusy = false
    @State private var setupError: String?

    @State private var panicPass1 = ""
    @State private var panicPass2 = ""
    @State private var showPanicPass1 = false
    @State private var panicBusy = false
    @State private var panicError: String?

    @State private var showWelcomeScreen = false
    @State private var welcomeUsername = ""
    @State private var welcomeBusy = false
    @State private var isWelcomeAnimating = false

    @State private var usernameInput = ""
    @State private var usernameBusy = false
    @State private var usernameError: String?
    @State private var profileNameInput = ""
    @State private var profileSetupAvatar: UIImage?
    @State private var profileSetupPhotoItem: PhotosPickerItem?
    @State private var profileSetupBusy = false
    @State private var profileSetupError: String?

    @State private var loginPassphrase = ""
    @State private var loginBusy = false
    @State private var loginError: String?
    @State private var biometryType: LABiometryType = .none

    private var relayTwoStepMode: VaulteRelayTwoStepIndicator.Mode {
        if showWelcomeScreen { return .welcomeScreen }
        if setupComplete { return .unlockScreen }
        switch setupWizardStep {
        case 1: return .mainPassphraseSetup
        case 2: return .panicPassphraseSetup
        case 3: return .usernameSetup
        default: return .profileSetup
        }
    }

    private var glassColumnMaxWidth: CGFloat {
        #if os(macOS)
        let base: CGFloat = 520
        #else
        let base: CGFloat = (horizontalSizeClass == .regular) ? 480 : 340
        #endif
        return base
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let target = min(glassColumnMaxWidth, max(320, w * (horizontalSizeClass == .regular ? 0.42 : 0.86)))

            HStack {
                Spacer(minLength: 0)

                VStack(spacing: 22) {
                    Spacer(minLength: 0)

                    if !isWelcomeAnimating {
                        relayBrandHeader
                    }

                    if relayTwoStepMode != .unlockScreen && !isWelcomeAnimating {
                        VaulteRelayTwoStepIndicator(mode: relayTwoStepMode)
                            .padding(.top, 4)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    if showWelcomeScreen {
                        PostRegistrationWelcomeView(
                            hideChrome: $isWelcomeAnimating,
                            onComplete: completeWelcome
                        )
                    } else if setupComplete {
                        authenticatePanel
                    } else if setupWizardStep == 1 {
                        setupPassphrasePanel
                    } else if setupWizardStep == 2 {
                        panicSetupPassphrasePanel
                    } else if setupWizardStep == 3 {
                        usernameSelectionPanel
                    } else {
                        profileSetupPanel
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: target)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .background {
                StarfieldBackdrop()
                    .ignoresSafeArea()
            }
        }
        #if os(macOS)
        .fixedMacWindow(width: 760, height: 560)
        #endif
        .onAppear {
            migrateSetupStateIfNeeded()
            refreshBiometryAvailability()
        }
    }

    private func migrateSetupStateIfNeeded() {
        guard setupComplete else { return }
        if !PassphraseEnclaveStore.hasPrimaryVerifier() {
            setupComplete = false
            setupWizardStep = 1
        } else if !PassphraseEnclaveStore.hasPanicVerifier() {
            setupComplete = false
            setupWizardStep = 2
            panicError = VaulteL.t("relay.msg.migrate_set_panic")
        }
    }

    private var relayBrandHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 32, height: 1)

                Image("Absolute Cinema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 60)
                    .foregroundStyle(.white)

                Rectangle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 32, height: 1)
            }

            Text(VaulteL.t("relay.brand_title"))
                .font(VaulteTypography.swiftUIFont(size: 18, weight: .light))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 4)
    }

    private var setupPassphrasePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                Text(VaulteL.t("relay.set_passphrase_title"))
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(.white)

            Text(VaulteL.t("relay.set_passphrase_body"))
                .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .trailing) {
                Group {
                    if showSetupPass1 {
                        TextField("", text: $setupPass1, prompt: enterPassphrasePrompt)
                            .textContentType(.newPassword)
                    } else {
                        SecureField("", text: $setupPass1, prompt: enterPassphrasePrompt)
                            .textContentType(.newPassword)
                    }
                }
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.leading, 16)
                .padding(.trailing, 48)
                .padding(.vertical, 14)
                .accessibilityLabel(VaulteL.t("relay.a11y_enter_passphrase"))

                Button {
                    showSetupPass1.toggle()
                } label: {
                    Image(systemName: showSetupPass1 ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.trailing, 12)
            }
            .background { VaulteGlassChrome.fieldBackground() }

            SecureField("", text: $setupPass2, prompt: confirmPassphrasePrompt)
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityLabel(VaulteL.t("relay.a11y_confirm_passphrase"))
                .background { VaulteGlassChrome.fieldBackground() }

            Button(action: submitMainSetup) {
                ZStack {
                    if setupBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text(VaulteL.t("common.continue"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .vaulteCTAGlow()
            .padding(.top, 8)
            .disabled(setupBusy || !canSubmitSetup)

            if let setupError {
                Text(setupError)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private var enterPassphrasePrompt: Text {
        Text(VaulteL.t("relay.enter_passphrase_prompt"))
            .foregroundStyle(Color.white.opacity(0.35))
    }

    private var confirmPassphrasePrompt: Text {
        Text(VaulteL.t("relay.confirm_passphrase_prompt"))
            .foregroundStyle(Color.white.opacity(0.35))
    }

    private var canSubmitSetup: Bool {
        let a = setupPass1.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = setupPass2.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a == b
    }

    private func submitMainSetup() {
        setupError = nil
        let p = setupPass1.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = setupPass2.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !p.isEmpty, p == q else {
            setupError = VaulteL.t("relay.error.passphrase_mismatch")
            return
        }

        setupBusy = true
        do {
            try PassphraseEnclaveStore.savePrimaryVerifier(passphrase: p)
            setupPass1 = ""
            setupPass2 = ""
            showSetupPass1 = false
            setupWizardStep = 2
            panicPass1 = ""
            panicPass2 = ""
            panicError = nil
        } catch {
            setupError = VaulteL.t("relay.error.passphrase_save_failed")
        }
        setupBusy = false
    }

    private var panicSetupPassphrasePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                Text(VaulteL.t("relay.set_panic_title"))
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(Color.red.opacity(0.95))

            Text(VaulteL.t("relay.set_panic_body"))
                .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                .foregroundStyle(Color.red.opacity(0.55))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { VaulteGlassChrome.fieldBackground() }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red.opacity(0.5), lineWidth: 1)
                )

            ZStack(alignment: .trailing) {
                Group {
                    if showPanicPass1 {
                        TextField("", text: $panicPass1, prompt: enterPanicPasswordPrompt)
                            .textContentType(.newPassword)
                    } else {
                        SecureField("", text: $panicPass1, prompt: enterPanicPasswordPrompt)
                            .textContentType(.newPassword)
                    }
                }
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.leading, 16)
                .padding(.trailing, 48)
                .padding(.vertical, 14)

                Button {
                    showPanicPass1.toggle()
                } label: {
                    Image(systemName: showPanicPass1 ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.trailing, 12)
            }
            .background { VaulteGlassChrome.fieldBackground() }

            SecureField("", text: $panicPass2, prompt: confirmPanicPasswordPrompt)
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background { VaulteGlassChrome.fieldBackground() }

            Button(action: submitPanicSetup) {
                ZStack {
                    if panicBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text(VaulteL.t("relay.complete_setup"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .vaulteCTAGlow()
            .padding(.top, 8)
            .disabled(panicBusy || !canSubmitPanic)

            if let panicError {
                Text(panicError)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private var welcomePanel: some View {
        VStack(alignment: .center, spacing: 24) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.green.opacity(0.9))
                
                Text("Welcome To Vaulte")
                    .font(VaulteTypography.swiftUIFont(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                if !welcomeUsername.isEmpty {
                    Text("Your panic phrase includes @\(welcomeUsername)")
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            
            Button(action: completeWelcome) {
                ZStack {
                    if welcomeBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text(VaulteL.t("common.continue"))
                            .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(welcomeBusy)
        }
    }

    private var canSubmitPanic: Bool {
        let a = panicPass1.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = panicPass2.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a == b
    }

    private func submitPanicSetup() {
        panicError = nil
        let p1 = panicPass1.trimmingCharacters(in: .whitespacesAndNewlines)
        let p2 = panicPass2.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !p1.isEmpty, p1 == p2 else {
            panicError = VaulteL.t("relay.error.passphrase_mismatch")
            return
        }

        guard !PassphraseEnclaveStore.verifyPrimary(passphrase: p1) else {
            panicError = VaulteL.t("relay.error.panic_must_differ")
            return
        }

        panicBusy = true

        Task { @MainActor in
            do {
                try PassphraseEnclaveStore.savePanicVerifier(passphrase: p1)
                panicPass1 = ""
                panicPass2 = ""
                showPanicPass1 = false
                withAnimation(.easeInOut(duration: 0.35)) {
                    setupWizardStep = 3
                }
            } catch {
                panicError = VaulteL.t("relay.error.panic_save_failed")
            }
            panicBusy = false
        }
    }

    private func completeWelcome() {
        isWelcomeAnimating = false
        setupComplete = true
        showWelcomeScreen = false
        loginPassphrase = ""
        loginError = nil
    }

    private func publishSecureChatKeys(userId: UUID) async throws {
        try await ChatViewModel.publishX3DHKeysIfNeeded(for: userId)
    }

    // MARK: - Username selection (step 3)

    private var usernameSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12))
                Text("Choose your username")
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(.white)

            Text("This is the only public identifier others will see.\nChoose carefully.")
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 0) {
                Text("@")
                    .font(VaulteTypography.swiftUIFont(size: 15, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .padding(.leading, 16)
                    .padding(.trailing, 2)

                TextField(
                    "",
                    text: $usernameInput,
                    prompt: Text("username")
                        .foregroundStyle(Color.white.opacity(0.3))
                )
                .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .padding(.trailing, 16)
                .padding(.vertical, 14)
                .onSubmit { if canSubmitUsername { submitUsername() } }
            }
            .background { VaulteGlassChrome.fieldBackground() }

            Button(action: submitUsername) {
                ZStack {
                    if usernameBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text("Confirm")
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .vaulteCTAGlow()
            .padding(.top, 8)
            .disabled(usernameBusy || !canSubmitUsername)

            if let usernameError {
                Text(usernameError)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private var canSubmitUsername: Bool {
        let u = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.count >= 3
    }

    private func submitUsername() {
        usernameError = nil
        let u = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard u.count >= 3 else { return }
        usernameBusy = true
        Task { @MainActor in
            do {
                let userId = try LocalIdentityStore.readOrCreateUserID()
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                try await publishSecureChatKeys(userId: userId)
                let user = try await client.syncEncryptedProfile(userId: userId, username: u)
                welcomeUsername = user.username.isEmpty ? u : user.username
                withAnimation(.easeInOut(duration: 0.35)) {
                    setupWizardStep = 4
                }
            } catch RelayAPIError.usernameTaken {
                usernameError = "This username is already taken. Try another one."
            } catch RelayAPIError.invalidUsername {
                usernameError = "Invalid username. Use 3–20 letters, numbers, or underscores."
            } catch {
                usernameError = VaulteL.relaySetupErrorMessage(error)
            }
            usernameBusy = false
        }
    }

    private var profileSetupPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.square")
                    .font(.system(size: 12))
                Text("Set up your profile")
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(.white)

            Text("Add a display name and profile photo. You can change both later in settings.")
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.48))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            HStack(spacing: 18) {
                PhotosPicker(selection: $profileSetupPhotoItem, matching: .images) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .frame(width: 112, height: 112)

                        if let profileSetupAvatar {
                            Image(uiImage: profileSetupAvatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 112, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.system(size: 22, weight: .medium))
                                Text("Photo")
                                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                            }
                            .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Profile photo")
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Square cover, soft edges, same style as the rest of onboarding.")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Tap to choose from Photos")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }

            TextField(
                "",
                text: $profileNameInput,
                prompt: Text("Your name")
                    .foregroundStyle(Color.white.opacity(0.3))
            )
            .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
            .textContentType(.name)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background { VaulteGlassChrome.fieldBackground() }

            Button(action: submitProfileSetup) {
                ZStack {
                    if profileSetupBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text("Continue")
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .vaulteCTAGlow()
            .padding(.top, 8)
            .disabled(profileSetupBusy)

            if let profileSetupError {
                Text(profileSetupError)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
        .onChange(of: profileSetupPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    await MainActor.run { profileSetupError = "Could not read that photo." }
                    return
                }
                guard let jpeg = VaulteProfileAvatarRelayEncoder.jpegDataForRelay(from: data),
                      let preview = UIImage(data: jpeg)
                else {
                    await MainActor.run { profileSetupError = "Could not prepare that photo." }
                    return
                }
                await MainActor.run {
                    profileSetupAvatar = preview
                    profileSetupError = nil
                }
            }
        }
    }

    private func submitProfileSetup() {
        profileSetupError = nil
        profileSetupBusy = true
        Task { @MainActor in
            defer { profileSetupBusy = false }
            do {
                let userId = try LocalIdentityStore.readOrCreateUserID()
                let name = profileNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = name.isEmpty ? nil : name
                let avatarBase64 = profileSetupAvatar?.jpegData(compressionQuality: 0.92)?.base64EncodedString()
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                _ = try await client.syncEncryptedProfile(
                    userId: userId,
                    username: welcomeUsername,
                    displayName: displayName,
                    avatarBase64: avatarBase64
                )
                if let displayName {
                    UserDefaults.standard.set(displayName, forKey: "vaulteprive.profile.displayName")
                }
                if let avatar = profileSetupAvatar,
                   let jpeg = avatar.jpegData(compressionQuality: 0.92) {
                    let key = VaulteProfileAvatar.storageKeyPrefix + userId.uuidString
                    UserDefaults.standard.set(jpeg, forKey: key)
                    NotificationCenter.default.post(name: VaulteProfileAvatar.didChangeNotification, object: nil)
                }
                withAnimation(.easeInOut(duration: 0.35)) {
                    showWelcomeScreen = true
                }
            } catch {
                profileSetupError = VaulteL.relaySetupErrorMessage(error)
            }
        }
    }

    private var enterPanicPasswordPrompt: Text {
        Text(VaulteL.t("relay.enter_panic_prompt"))
            .foregroundStyle(Color.white.opacity(0.35))
    }

    private var confirmPanicPasswordPrompt: Text {
        Text(VaulteL.t("relay.confirm_panic_prompt"))
            .foregroundStyle(Color.white.opacity(0.35))
    }

    private var authenticatePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                Text(VaulteL.t("relay.enter_passphrase_header"))
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                    .tracking(1)
            }
            .foregroundStyle(.white)

            ZStack(alignment: .trailing) {
                SecureField("", text: $loginPassphrase, prompt: enterPassphrasePrompt)
                    .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                    .padding(.trailing, 48)
                    .padding(.vertical, 14)
                    .accessibilityLabel(VaulteL.t("relay.a11y_passphrase"))

                Button(action: authenticateWithBiometrics) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                            )

                        Image(systemName: biometryIconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .disabled(loginBusy || biometryType == .none || !biometricEnabled)
            }
            .background { VaulteGlassChrome.fieldBackground() }

            Button(action: authenticate) {
                ZStack {
                    if loginBusy {
                        ProgressView().tint(.primary)
                    } else {
                        Text(VaulteL.t("relay.proceed"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)
            .vaulteCTAGlow()
            .padding(.top, 8)
            .disabled(loginBusy || trimmedLoginPassphrase.isEmpty)

            if let loginError {
                Text(loginError)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.9))
            }
        }
    }

    private var trimmedLoginPassphrase: String {
        loginPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authenticate() {
        loginError = nil
        let p = trimmedLoginPassphrase
        guard !p.isEmpty else { return }

        loginBusy = true
        Task { @MainActor in
            if PassphraseEnclaveStore.verifyPanic(passphrase: p) {
                await performPanicResetEverywhere()
                loginPassphrase = ""
                loginBusy = false
                loginError = VaulteL.t("relay.msg.panic_complete")
            } else if PassphraseEnclaveStore.verifyPrimary(passphrase: p) {
                do {
                    let userId = try LocalIdentityStore.readOrCreateUserID()
                    try await publishSecureChatKeys(userId: userId)
                    loginPassphrase = ""
                    loginBusy = false
                    onAuthenticated()
                } catch {
                    loginBusy = false
                    loginError = VaulteL.relaySetupErrorMessage(error)
                }
            } else {
                loginBusy = false
                loginError = VaulteL.t("relay.error.wrong_passphrase")
            }
        }
    }

    private func performPanicResetEverywhere() async {
        let existingUserId = LocalIdentityStore.readUserIDIfPresent()
        if let existingUserId {
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                try await client.hardResetAccount(userId: existingUserId)
            } catch {
                // Continue local wipe even if relay cannot be reached.
            }
        }

        try? await store.wipeAllLocalData()
        PassphraseEnclaveStore.deleteAllVerifiers()
        ConversationKeyStore.deleteAll()
        LocalIdentityStore.deleteAllX3DHKeys()
        LocalIdentityStore.clearAllTOFUPins()
        LocalIdentityStore.deleteUserID()
        await IdentityKeyExchange.shared.clearLocalIdentityKey()
        VaulteDisplayName.clearAllCustomNames()

        UserDefaults.standard.removeObject(forKey: "vaulteprive.relay.setupComplete")
        UserDefaults.standard.removeObject(forKey: "vaulteprive.profile.displayName")
        if let existingUserId {
            UserDefaults.standard.removeObject(forKey: VaulteProfileAvatar.storageKeyPrefix + existingUserId.uuidString)
            NotificationCenter.default.post(name: VaulteProfileAvatar.didChangeNotification, object: nil)
        }
        setupComplete = false
    }

    private var biometryIconName: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "key.fill"
        }
    }

    private func refreshBiometryAvailability() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometryType = context.biometryType
        } else {
            biometryType = .none
        }
    }

    private func authenticateWithBiometrics() {
        loginError = nil
        guard biometricEnabled else {
            loginError = VaulteL.t("relay.error.biometric_enable_first")
            return
        }
        guard setupComplete, PassphraseEnclaveStore.hasPrimaryVerifier() else {
            loginError = VaulteL.t("relay.error.setup_complete_first")
            return
        }
        let context = LAContext()
        context.localizedCancelTitle = VaulteL.t("relay.biometric_cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            refreshBiometryAvailability()
            loginError = VaulteL.t("relay.error.biometric_unavailable")
            return
        }
        loginBusy = true
        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: VaulteL.t("relay.biometric_reason")
        ) { success, evalError in
            Task { @MainActor in
                if success {
                    do {
                        let userId = try LocalIdentityStore.readOrCreateUserID()
                        try await publishSecureChatKeys(userId: userId)
                        loginBusy = false
                        onAuthenticated()
                    } catch {
                        loginBusy = false
                        loginError = VaulteL.relaySetupErrorMessage(error)
                    }
                } else if let laErr = evalError as? LAError, laErr.code == .userCancel {
                    loginBusy = false
                    // silent cancel
                } else {
                    loginBusy = false
                    loginError = VaulteL.t("relay.error.biometric_failed")
                }
            }
        }
    }
}

private struct VaulteRelayTwoStepIndicator: View {
    enum Mode {
        case mainPassphraseSetup
        case panicPassphraseSetup
        case usernameSetup
        case profileSetup
        case welcomeScreen
        case unlockScreen
    }

    let mode: Mode

    var body: some View {
        HStack(spacing: 0) {
            stepBox(number: 1, role: role(for: 1))
            connector(filled: mode != .mainPassphraseSetup)
            stepBox(number: 2, role: role(for: 2))
            connector(filled: mode == .usernameSetup || mode == .profileSetup || mode == .welcomeScreen || mode == .unlockScreen)
            stepBox(number: 3, role: role(for: 3))
            connector(filled: mode == .profileSetup || mode == .welcomeScreen || mode == .unlockScreen)
            stepBox(number: 4, role: role(for: 4))
            connector(filled: mode == .welcomeScreen || mode == .unlockScreen)
            stepBox(number: 5, role: role(for: 5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func role(for step: Int) -> StepRole {
        switch mode {
        case .mainPassphraseSetup:
            return step == 1 ? .active : .pending
        case .panicPassphraseSetup:
            return step == 1 ? .completed : step == 2 ? .active : .pending
        case .usernameSetup:
            return step <= 2 ? .completed : step == 3 ? .active : .pending
        case .profileSetup:
            if step <= 3 { return .completed }
            return step == 4 ? .active : .pending
        case .welcomeScreen, .unlockScreen:
            return step <= 4 ? .completed : .active
        }
    }

    enum StepRole {
        case completed
        case active
        case pending
    }

    private func connector(filled: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(filled ? 0.50 : 0.20))
            .frame(width: 18, height: 1)
    }

    @ViewBuilder
    private func stepBox(number: Int, role: StepRole) -> some View {
        StepLockBox(number: number, role: role)
    }

    private func backgroundColor(for role: StepRole) -> Color {
        switch role {
        case .completed:
            return Color.white.opacity(0.16)
        case .active:
            return Color.white.opacity(0.22)
        case .pending:
            return Color.clear
        }
    }

    private func borderColor(for role: StepRole) -> Color {
        switch role {
        case .completed:
            return Color.white.opacity(0.55)
        case .active:
            return Color.white.opacity(0.8)
        case .pending:
            return Color.white.opacity(0.35)
        }
    }

    private func textColor(for role: StepRole) -> Color {
        switch role {
        case .completed:
            return Color.white.opacity(0.90)
        case .active:
            return Color.white.opacity(1)
        case .pending:
            return Color.white.opacity(0.6)
        }
    }
}

// MARK: - Animated lock step box

/// A single step square with an open-lock → closed-lock animation when completed.
private struct StepLockBox: View {
    let number: Int
    let role: VaulteRelayTwoStepIndicator.StepRole

    @State private var locked = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(bgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.3), value: role)

            Group {
                if role == .completed {
                    Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .onAppear {
                            // brief delay so the open lock is visible before closing
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                                    locked = true
                                }
                            }
                        }
                } else {
                    Text("\(number)")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                        .foregroundStyle(numberColor)
                        .transition(.scale(scale: 1.3).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: role)
        }
        .frame(width: 24, height: 24)
        .onChange(of: role) { newRole in
            if newRole != .completed { locked = false }
        }
    }

    private var bgColor: Color {
        switch role {
        case .completed: return Color.white.opacity(0.16)
        case .active:    return Color.white.opacity(0.22)
        case .pending:   return Color.clear
        }
    }

    private var borderColor: Color {
        switch role {
        case .completed: return Color.white.opacity(0.55)
        case .active:    return Color.white.opacity(0.80)
        case .pending:   return Color.white.opacity(0.35)
        }
    }

    private var numberColor: Color {
        switch role {
        case .completed: return Color.white.opacity(0.90)
        case .active:    return Color.white
        case .pending:   return Color.white.opacity(0.5)
        }
    }
}

// MARK: - Backdrop

struct StarfieldBackdrop: View {
    struct Star: Identifiable {
        let id = UUID()
        var position: CGPoint
        var velocity: CGVector
        let size: CGFloat
        let opacity: Double
        let depth: CGFloat
    }

    @State private var stars: [Star] = []
    @State private var canvasSize: CGSize = .zero
    @State private var mouseOffset: CGPoint = .zero

    #if os(macOS)
    private let starCount = 200
    #else
    private let starCount = 50
    #endif

    private let timer = Timer.publish(
        every: 1.0 / 120.0,
        tolerance: 0.0005,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                for star in stars {
                    let parallaxX = mouseOffset.x * 0.02 * star.depth
                    let parallaxY = mouseOffset.y * 0.02 * star.depth

                    let rect = CGRect(
                        x: star.position.x + parallaxX,
                        y: star.position.y + parallaxY,
                        width: star.size,
                        height: star.size
                    )

                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(VaultePalette.gold.opacity(star.opacity * 0.9))
                    )
                }
            }
            .background(VaultePalette.ink)
            .ignoresSafeArea()
            .onAppear {
                canvasSize = geo.size
                stars = makeStars(size: geo.size)
            }
            .onChange(of: geo.size) { newSize in
                canvasSize = newSize
                stars = makeStars(size: newSize)
            }
            .onReceive(timer) { _ in
                updateStars()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        mouseOffset = CGPoint(
                            x: value.location.x - canvasSize.width / 2,
                            y: value.location.y - canvasSize.height / 2
                        )
                    }
            )
        }
    }

    private func makeStars(size: CGSize) -> [Star] {
        (0..<starCount).map { _ in
            let depth = CGFloat.random(in: 0.6...1.4)
            let baseSpeed = CGFloat.random(in: 0.01...0.04)

            return Star(
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: CGFloat.random(in: 0...size.height)
                ),
                velocity: CGVector(
                    dx: CGFloat.random(in: -baseSpeed...baseSpeed) * depth,
                    dy: CGFloat.random(in: -baseSpeed...baseSpeed) * depth
                ),
                size: CGFloat.random(in: 1...3),
                opacity: Double.random(in: 0.35...0.85),
                depth: depth
            )
        }
    }

    private func updateStars() {
        for i in stars.indices {
            stars[i].position.x += stars[i].velocity.dx
            stars[i].position.y += stars[i].velocity.dy

            if stars[i].position.x < 0 { stars[i].position.x = canvasSize.width }
            if stars[i].position.x > canvasSize.width { stars[i].position.x = 0 }
            if stars[i].position.y < 0 { stars[i].position.y = canvasSize.height }
            if stars[i].position.y > canvasSize.height { stars[i].position.y = 0 }
        }
    }
}

// MARK: - Root tabs

struct RootTabs: View {
    let store: OTPStore
    let userId: UUID
    let callManager: CallManager

    /// 0 = Calls, 1 = Messages (default after login), 2 = Contacts, 3 = Settings
    @State private var selectedTab = 1
    @State private var connectChallengeCenter = VaulteConnectChallengeCenter.shared
    @State private var otpPairingCenter = VaulteOtpPadPairingCenter.shared

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                CallsTabView(callManager: callManager, store: store, userId: userId)
                    .tabItem { Label("Calls", systemImage: "phone.fill") }
                    .tag(0)

                ConversationListView(store: store, userId: userId, callManager: callManager)
                    .tabItem { Label("Chats", systemImage: "message.fill") }
                    .tag(1)

                ContactsTabView(store: store, userId: userId)
                    .tabItem { Label("Contacts", systemImage: "person.2.fill") }
                    .tag(2)

                AppSettingsView(store: store, userId: userId)
                    .tabItem { Label("Settings", systemImage: "person.crop.circle.fill") }
                    .tag(3)
            }
            .background {
                ZStack {
                    Color.black.ignoresSafeArea()
                    StarfieldBackdrop()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }

            if case let .incoming(callId, peerId) = callManager.state {
                IncomingCallOverlay(callManager: callManager, callId: callId, peerId: peerId)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: callManager.isInCall)
        .task {
            await VaulteSubscriptionManager.shared.start()
            otpPairingCenter.bind(userId: userId, store: store)
        }
        .sheet(
            item: Binding(
                get: { otpPairingCenter.activeSession },
                set: { newValue in
                    if newValue == nil {
                        otpPairingCenter.clear()
                    }
                }
            )
        ) { _ in
            VaulteOtpPadPairingSheet {
                otpPairingCenter.clear()
            }
            .presentationDetents([.height(340)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.black)
            .presentationCornerRadius(22)
        }
        .sheet(
            item: Binding(
                get: { connectChallengeCenter.pendingChallenge },
                set: { newValue in
                    if newValue == nil {
                        connectChallengeCenter.clear()
                    }
                }
            )
        ) { challenge in
            VaulteConnectApprovalSheet(challenge: challenge, userId: userId)
                .presentationDetents([.fraction(0.46)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.clear)
        }
    }
}

private struct VaulteConnectApprovalSheet: View {
    private static let fallbackIcons = ["star.fill", "moon.fill", "bolt.fill"]

    let challenge: VaulteConnectChallenge
    let userId: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var didResolve = false
    @State private var relayChallenge: RelayAuthChallengeDTO?
    @State private var isLoadingRelayChallenge = false
    @State private var isSubmittingSelection = false
    @State private var challengeErrorMessage: String?

    private var displayedOrigin: String {
        relayChallenge?.origin ?? challenge.origin
    }

    private var displayedIcons: [String] {
        let icons = relayChallenge?.icons ?? challenge.icons
        return icons.isEmpty ? Self.fallbackIcons : icons
    }

    private var resolvedCallbackURLString: String? {
        relayChallenge?.redirectURI ?? challenge.callbackURLString
    }

    private var resolvedCallbackState: String? {
        let trimmed = (relayChallenge?.state ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isChallengeForDifferentAccount: Bool {
        guard let relayChallenge else { return false }
        return relayChallenge.userId != userId
    }

    private var canResolveLocally: Bool {
        challenge.hasEmbeddedApprovalPayload
    }

    private var canApprove: Bool {
        !isLoadingRelayChallenge
            && !isSubmittingSelection
            && !isChallengeForDifferentAccount
            && (relayChallenge != nil || canResolveLocally)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)

                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 66, height: 66)
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }

                    Text("Approve On This Device")
                        .font(VaulteTypography.swiftUIFont(size: 22, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Choose the same symbol shown in \(displayedOrigin) to confirm the connection.")
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                HStack(spacing: 12) {
                    ForEach(displayedIcons, id: \.self) { icon in
                        Button {
                            handleSelection(icon)
                        } label: {
                            VStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(Color.white.opacity(0.06))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                        .frame(height: 84)
                                    Image(systemName: icon)
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canApprove)
                        .opacity(canApprove ? 1 : 0.55)
                    }
                }

                if isLoadingRelayChallenge || isSubmittingSelection {
                    ProgressView()
                        .tint(.white.opacity(0.92))
                }

                if isChallengeForDifferentAccount {
                    Text("This login request belongs to a different Vaulte account.")
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(Color.red.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                } else if let challengeErrorMessage {
                    Text(challengeErrorMessage)
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(Color.red.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                Button("Cancel") {
                    resolve(
                        result: "cancelled",
                        selectedIcon: nil,
                        callbackURLString: resolvedCallbackURLString,
                        state: resolvedCallbackState
                    )
                }
                .buttonStyle(.plain)
                .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.58))
                .disabled(isSubmittingSelection)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.black.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
        }
        .task(id: challenge.id) {
            await loadRelayChallenge()
        }
        .interactiveDismissDisabled(isSubmittingSelection)
        .onDisappear {
            if !didResolve {
                resolve(
                    result: "cancelled",
                    selectedIcon: nil,
                    callbackURLString: resolvedCallbackURLString,
                    state: resolvedCallbackState
                )
            }
            VaulteConnectChallengeCenter.shared.clear()
        }
    }

    private func handleSelection(_ icon: String) {
        guard canApprove else { return }
        if relayChallenge != nil {
            Task {
                await approveRelayChallenge(selectedIcon: icon)
            }
            return
        }

        let result = (icon == challenge.correctIcon) ? "approved" : "rejected"
        resolve(
            result: result,
            selectedIcon: icon,
            callbackURLString: resolvedCallbackURLString,
            state: resolvedCallbackState
        )
    }

    private func resolve(
        result: String,
        selectedIcon: String?,
        callbackURLString: String? = nil,
        state: String? = nil,
        code: String? = nil
    ) {
        guard !didResolve else { return }
        didResolve = true

        if let callbackURL = makeCallbackURL(
            result: result,
            selectedIcon: selectedIcon,
            callbackURLString: callbackURLString,
            state: state,
            code: code
        ) {
            openURL(callbackURL)
        }

        Task {
            await MainActor.run {
                VaulteConnectChallengeCenter.shared.clear()
                dismiss()
            }
        }
    }

    private func loadRelayChallenge() async {
        await MainActor.run {
            isLoadingRelayChallenge = true
            challengeErrorMessage = nil
        }

        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let fetchedChallenge = try await client.fetchAuthChallenge(challengeId: challenge.id)
            await MainActor.run {
                relayChallenge = fetchedChallenge
                isLoadingRelayChallenge = false
                challengeErrorMessage = fetchedChallenge.userId == userId
                    ? nil
                    : "This login request belongs to a different Vaulte account."
            }
        } catch {
            await MainActor.run {
                relayChallenge = nil
                isLoadingRelayChallenge = false
                if !challenge.hasEmbeddedApprovalPayload {
                    challengeErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func approveRelayChallenge(selectedIcon: String) async {
        await MainActor.run {
            isSubmittingSelection = true
            challengeErrorMessage = nil
        }

        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let response = try await client.approveAuthChallenge(
                challengeId: challenge.id,
                userId: userId,
                selectedIcon: selectedIcon
            )
            await MainActor.run {
                isSubmittingSelection = false
                resolve(
                    result: response.result,
                    selectedIcon: selectedIcon,
                    callbackURLString: response.redirectURI ?? resolvedCallbackURLString,
                    state: response.state ?? resolvedCallbackState,
                    code: response.code
                )
            }
        } catch {
            await MainActor.run {
                isSubmittingSelection = false
                challengeErrorMessage = error.localizedDescription
            }
        }
    }

    private func makeCallbackURL(
        result: String,
        selectedIcon: String?,
        callbackURLString: String? = nil,
        state: String? = nil,
        code: String? = nil
    ) -> URL? {
        guard let callbackURLString = callbackURLString ?? resolvedCallbackURLString,
              let baseURL = URL(string: callbackURLString),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let replacedKeys: Set<String> = [
            "result",
            "challenge_id",
            "selected_icon",
            "user_id",
            "code",
            "state",
        ]
        var queryItems = (components.queryItems ?? []).filter { !replacedKeys.contains($0.name) }
        queryItems.append(URLQueryItem(name: "result", value: result))
        queryItems.append(URLQueryItem(name: "challenge_id", value: challenge.id))
        queryItems.append(URLQueryItem(name: "selected_icon", value: selectedIcon))
        queryItems.append(URLQueryItem(name: "user_id", value: userId.uuidString))
        if let code, !code.isEmpty {
            queryItems.append(URLQueryItem(name: "code", value: code))
        }
        if let state, !state.isEmpty {
            queryItems.append(URLQueryItem(name: "state", value: state))
        }
        components.queryItems = queryItems
        return components.url
    }
}

private struct CallsTabView: View {
    let callManager: CallManager
    let store: OTPStore
    let userId: UUID
    @State private var showActiveCall = false

    var body: some View {
        NavigationStack {
            ZStack {
                VaultePalette.ink.ignoresSafeArea()
                StarfieldBackdrop().ignoresSafeArea().allowsHitTesting(false)

                if callManager.history.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "phone.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(VaultePalette.gold.opacity(0.92))
                            .shadow(color: VaultePalette.gold.opacity(0.22), radius: 16)
                        Text(VaulteL.t("calls.title"))
                            .font(VaulteTypography.swiftUIFont(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.94))
                        Text(VaulteL.t("calls.empty"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(VaultePalette.mist)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(callManager.history) { entry in
                                CallHistoryRow(entry: entry)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle(VaulteL.t("calls.title"))
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showActiveCall) {
                ActiveCallView(callManager: callManager)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onChange(of: callManager.state) { _, newState in
            if case .active = newState { showActiveCall = true }
            if case .idle = newState { showActiveCall = false }
        }
    }
}

private struct CallHistoryRow: View {
    let entry: CallHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.direction == .incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                .font(.system(size: 18))
                .foregroundStyle(entry.outcome == .missed ? VaultePalette.gold.opacity(0.75) : VaultePalette.gold.opacity(0.9))
                .frame(width: 36, height: 36)
                .background(Circle().fill(VaultePalette.surface))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.peerName ?? entry.peerId.uuidString.prefix(8).uppercased())
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(entry.outcome == .missed ? VaulteL.t("calls.outcome.missed") : entry.outcome == .declined ? VaulteL.t("calls.outcome.declined") : formatDuration(entry.duration))
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(entry.outcome == .missed ? VaultePalette.gold.opacity(0.72) : VaultePalette.mist)

                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))

                    Text(relativeTime(entry.startedAt))
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(VaultePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(VaultePalette.border, lineWidth: 0.8)
                )
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = VaulteLocale.preferredLocale
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Active Call Screen

struct ActiveCallView: View {
    let callManager: CallManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            VaultePalette.ink.ignoresSafeArea()
            StarfieldBackdrop().ignoresSafeArea().allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [VaultePalette.gold.opacity(0.16), .white.opacity(0.01)],
                                    center: .center,
                                    startRadius: 20,
                                    endRadius: 60
                                )
                            )
                            .frame(width: 120, height: 120)
                        Image(systemName: "person.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .shadow(color: VaultePalette.gold.opacity(0.14), radius: 30)

                    if let name = callManager.displayNameForCurrentCall ?? callManager.peerIdForCurrentCall.map({ String($0.uuidString.prefix(8).uppercased()) }) {
                        Text(name)
                            .font(VaulteTypography.swiftUIFont(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                    }

                    callStatusLabel
                    if let detail = callManager.callStatusDetail {
                        Text(detail)
                            .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                            .foregroundStyle(VaultePalette.gold.opacity(0.78))
                    }
                }

                Spacer()

                HStack(spacing: 32) {
                    callActionButton(
                        icon: callManager.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: VaulteL.t("calls.label.microphone"),
                        active: callManager.isMuted
                    ) {
                        callManager.toggleMute()
                    }

                    callActionButton(
                        icon: callManager.isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                        label: VaulteL.t("calls.label.speaker"),
                        active: callManager.isSpeaker
                    ) {
                        callManager.toggleSpeaker()
                    }

                    Button {
                        callManager.endCall()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color.red))
                            .shadow(color: .red.opacity(0.5), radius: 12)
                    }
                }
                .padding(.bottom, 60)
            }

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(VaulteL.t("calls.e2e_label"))
                            .font(VaulteTypography.swiftUIFont(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.green.opacity(0.82))
                    .foregroundStyle(VaultePalette.gold.opacity(0.88))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background {
                        Capsule(style: .continuous)
                            .fill(VaultePalette.gold.opacity(0.1))
                            .overlay(Capsule(style: .continuous).strokeBorder(VaultePalette.borderStrong, lineWidth: 0.9))
                    }
                    Spacer()
                }
                .padding(.top, 60)
                Spacer()
            }
        }
        .onChange(of: callManager.state) { _, newState in
            if case .idle = newState { dismiss() }
            if case .ended = newState {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var callStatusLabel: some View {
        switch callManager.state {
        case .outgoing:
            HStack(spacing: 8) {
                ProgressView().tint(.white.opacity(0.6))
                Text(VaulteL.t("calls.status.calling"))
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .active:
            Text(formatCallDuration(callManager.callDuration))
                .font(VaulteTypography.swiftUIFont(size: 20))
                .foregroundStyle(VaultePalette.gold.opacity(0.9))
                .monospacedDigit()
        case .ended(let reason):
            Text(VaulteL.t(reason))
                .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
        default:
            EmptyView()
        }
    }

    private func callActionButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(active ? VaultePalette.ink : .white.opacity(0.9))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(active ? VaultePalette.gold : VaultePalette.surfaceStrong))
                Text(label)
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    private func formatCallDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Incoming Call Overlay

struct IncomingCallOverlay: View {
    let callManager: CallManager
    let callId: UUID
    let peerId: UUID

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 30) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(VaultePalette.gold.opacity(0.08))
                        .frame(width: 140, height: 140)
                        .scaleEffect(pulseScale)
                    Circle()
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 110, height: 110)
                    Image(systemName: "person.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        pulseScale = 1.15
                    }
                }

                VStack(spacing: 8) {
                    Text(VaulteL.t("calls.incoming_title"))
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(callManager.displayNameForCurrentCall ?? peerId.uuidString.prefix(8).uppercased())
                        .font(VaulteTypography.swiftUIFont(size: 24, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                }

                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(VaulteL.t("calls.e2e_call_label"))
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                }
                .foregroundStyle(VaultePalette.gold.opacity(0.82))

                Spacer()

                HStack(spacing: 50) {
                    Button {
                        callManager.declineCall()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Circle().fill(Color.red))
                                .shadow(color: .red.opacity(0.5), radius: 12)
                            Text(VaulteL.t("calls.decline"))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        callManager.acceptCall()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Circle().fill(VaultePalette.gold))
                                .shadow(color: VaultePalette.gold.opacity(0.4), radius: 12)
                            Text(VaulteL.t("calls.accept"))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 60)
            }
        }
    }
}

struct ContactsTabView: View {
    let store: OTPStore
    let userId: UUID

    @State private var conversations: [OTPConversationListRow] = []
    @State private var showNew = false
    @State private var showSecureExchange = false
    @State private var showRenameSheet = false
    @State private var renamingPeerId: UUID?
    @State private var renameDraft = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                StarfieldBackdrop()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(conversations, id: \.id) { conv in
                            NavigationLink {
                                ChatScreen(store: store, conversationId: conv.id, userId: userId)
                            } label: {
                                ContactRowCard(
                                    peerId: conv.peerRecipientId,
                                    title: conv.title,
                                    isGroup: conv.isGroup,
                                    groupOwnerUserId: conv.groupOwnerUserId
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !conv.isGroup {
                                    Button {
                                        renamingPeerId = conv.peerRecipientId
                                        renameDraft = VaulteDisplayName.nickname(for: conv.peerRecipientId) ?? ""
                                        showRenameSheet = true
                                    } label: {
                                        Label(VaulteL.t("conversations.rename"), systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .contextMenu {
                                if !conv.isGroup {
                                    Button {
                                        renamingPeerId = conv.peerRecipientId
                                        renameDraft = VaulteDisplayName.nickname(for: conv.peerRecipientId) ?? ""
                                        showRenameSheet = true
                                    } label: {
                                        Label(VaulteL.t("conversations.rename"), systemImage: "pencil")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .sheet(isPresented: $showRenameSheet) {
                    RenameContactSheet(
                        peerId: renamingPeerId ?? UUID(),
                        draft: $renameDraft,
                        isPresented: $showRenameSheet
                    )
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await refresh()
                }
            }
            .navigationTitle(VaulteL.t("contacts.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(VaulteL.t("contacts.title"))
                        .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(isPresented: $showNew) {
                NewConversationSheet(store: store, userId: userId) {
                    Task { await refresh() }
                }
            }
            .task { await refresh() }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func refresh() async {
        await syncInboxIfNeeded()
        if let list = try? await store.allConversations() {
            conversations = list
            await refreshRelayProfiles(for: list.map(\.peerRecipientId), excluding: userId)
            conversations = list
        }
    }

    private func syncInboxIfNeeded() async {
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let inbox = try await client.fetchInboxMessages(recipientId: userId)
            for m in inbox where m.recipientId == userId {
                let localConversationId: UUID
                if m.padId != m.conversationId {
                    localConversationId = m.conversationId
                } else if let existing = try? await store.directConversationId(for: m.senderId) {
                    localConversationId = existing
                } else {
                    localConversationId = VaulteDirectConversationId.uuid(between: userId, and: m.senderId)
                }
                let alreadyStored = (try? await store.hasMessage(messageId: m.messageId)) ?? false
                if let deletedCutoff = try await store.deletedConversationCutoff(conversationId: localConversationId),
                   m.createdAt <= deletedCutoff
                {
                    continue
                }
                try await store.clearDeletedConversationMarker(conversationId: localConversationId)
                try await store.upsertConversation(id: localConversationId, peerRecipientId: m.senderId)

                if let dto = try? await client.fetchUser(userId: m.senderId) {
                    cacheRelayUser(dto)
                }

                if !alreadyStored {
                    try await store.upsertServerMessage(
                        messageId: m.messageId,
                        conversationId: localConversationId,
                        senderId: m.senderId,
                        recipientId: m.recipientId,
                        padId: m.padId,
                        ciphertextBase64: m.ciphertextBase64,
                        createdAt: m.createdAt
                    )
                }
            }
        } catch {
            // Keep UI responsive; chat screen sync handles detailed errors.
        }
    }
}

private struct RenameContactSheet: View {
    let peerId: UUID
    @Binding var draft: String
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Text(VaulteL.t("rename.title"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                TextField(VaulteL.t("common.name"), text: $draft)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                            )
                    )
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }

                HStack(spacing: 14) {
                    Button(VaulteL.t("common.cancel")) {
                        isPresented = false
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                    Button(VaulteL.t("common.save")) {
                        save()
                    }
                    .foregroundStyle(.white)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
        }
        .onAppear { focused = true }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            VaulteDisplayName.setNickname(nil, for: peerId)
        } else {
            VaulteDisplayName.setNickname(trimmed, for: peerId)
        }
        isPresented = false
    }
}

private struct ContactRowCard: View {
    let peerId: UUID
    let title: String?
    var isGroup: Bool = false
    var groupOwnerUserId: UUID? = nil

    private var displayTitle: String {
        conversationRowTitle(isGroup: isGroup, title: title, peerRecipientId: peerId, groupOwnerUserId: groupOwnerUserId)
    }

    private var usernameSubtitle: String? {
        isGroup ? VaulteL.t("newgroup.list_subtitle") : relayUsername(for: peerId)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.85)
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)

                if let sub = usernameSubtitle {
                    Text(sub)
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            let base = RoundedRectangle(cornerRadius: 22, style: .continuous)
            base
                .fill(Color.clear)
                .overlay(
                    base
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.22),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
        }
    }
}

// MARK: - Conversations

/// Relay usernames are `^[a-z0-9_]{3,24}$` (see relay-server). Those are shown with a leading `@`.
private func isRelayStyleUsername(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    guard let re = try? NSRegularExpression(pattern: "^[a-z0-9_]{3,24}$", options: []) else { return false }
    return re.firstMatch(in: s, options: [], range: range) != nil
}

/// `@vaulte` → `@Vaulte` (capitalizes first letter of handle; rest as on server, usually lower).
private func formattedAtUsername(core: String) -> String {
    guard let first = core.first else { return "@" }
    return "@" + String(first).uppercased() + String(core.dropFirst())
}

private func displayName(for id: UUID) -> String {
    // 1. User-set nickname takes top priority
    if let nick = VaulteDisplayName.nickname(for: id),
       !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return nick
    }
    // 2. Relay public display name
    let raw = VaulteDisplayName.customName(for: id) ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, !trimmed.hasPrefix("user-") {
        return trimmed
    }
    // 3. Relay username fallback
    if let username = relayUsername(for: id) {
        return username
    }
    return VaulteL.t("display.placeholder_name")
}

/// Returns the relay @Username for subtitle display (independent of nickname).
private func relayUsername(for id: UUID) -> String? {
    let core = (VaulteDisplayName.relayUsername(for: id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if core.isEmpty { return nil }
    if isRelayStyleUsername(core) {
        return formattedAtUsername(core: core)
    }
    return nil
}

private func cacheRelayUser(_ user: RelayUserDTO) {
    VaulteDisplayName.setRelayUsername(user.username, for: user.userId)
    VaulteDisplayName.setCustomName(user.displayName, for: user.userId)
}

private func refreshRelayProfiles(for ids: [UUID], excluding excludedId: UUID? = nil, maxCount: Int? = nil) async {
    guard let client = try? ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL) else { return }
    var unique = Array(Set(ids))
    if let excludedId {
        unique.removeAll { $0 == excludedId }
    }
    if let maxCount, unique.count > maxCount {
        unique = Array(unique.prefix(maxCount))
    }
    for userId in unique {
        guard let dto = try? await client.fetchUser(userId: userId) else { continue }
        cacheRelayUser(dto)
    }
}

private func sharedConversationId(userA: UUID, userB: UUID) -> UUID {
    VaulteDirectConversationId.uuid(between: userA, and: userB)
}

/// If the stored group title only repeats the owner’s personal labels, treat it as unset (show generic “Group”).
private func distinctGroupTitle(stored title: String?, ownerId: UUID?) -> String? {
    let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if t.isEmpty { return nil }
    guard let owner = ownerId else { return t }
    var candidates: [String] = [
        displayName(for: owner),
        VaulteDisplayName.nickname(for: owner) ?? "",
        VaulteDisplayName.customName(for: owner) ?? "",
        relayUsername(for: owner) ?? ""
    ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    candidates = candidates.filter { !$0.isEmpty }
    for c in candidates where t.caseInsensitiveCompare(c) == .orderedSame {
        return nil
    }
    return t
}

/// Primary line for a conversation row, delete confirmation, pickers, and chat title fallback.
private func conversationRowTitle(isGroup: Bool, title: String?, peerRecipientId: UUID, groupOwnerUserId: UUID? = nil) -> String {
    if isGroup {
        if let d = distinctGroupTitle(stored: title, ownerId: groupOwnerUserId) { return d }
        return VaulteL.t("chat.header_group")
    }
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
    return displayName(for: peerRecipientId)
}

private func conversationRowTitle(conv: OTPConversationListRow) -> String {
    conversationRowTitle(isGroup: conv.isGroup, title: conv.title, peerRecipientId: conv.peerRecipientId, groupOwnerUserId: conv.groupOwnerUserId)
}

private struct VaulteChatRowMatchedGeometry: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID?
    /// List row = `true` (hero “from”), chat header = `false` (hero “to”). Both `true` makes the header stick to the row’s frame.
    var isSource: Bool = true
    /// Turn off on the chat header shortly after push so layout isn’t pulled by the list row’s geometry.
    var enabled: Bool = true

    func body(content: Content) -> some View {
        if let namespace, enabled {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .frame, isSource: isSource)
        } else {
            content
        }
    }
}

struct ConversationListView: View {
    let store: OTPStore
    let userId: UUID
    var callManager: CallManager?

    @Namespace private var chatOpenNamespace
    @State private var navigationPath = NavigationPath()
    @State private var conversations: [OTPConversationListRow] = []
    @State private var showNew = false
    @State private var showNewGroup = false
    @State private var showSecureExchange = false
    @State private var glowingConversationIDs: Set<UUID> = []
    @State private var stretchingConversationId: UUID?
    @State private var pendingDeleteConversation: (id: UUID, title: String)?
    @State private var deleteError: String?
    @State private var showRenameSheet = false
    @State private var renamingPeerId: UUID?
    @State private var renameDraft = ""
    /// Last message preview per conversation: subtitle line + optional JPEG thumb.
    @State private var conversationRowExtras: [UUID: (previewLine: String?, previewImageJPEG: Data?)] = [:]
    /// Bumped when peer profile images are cached so rows re-read `UserDefaults` avatars.
    @State private var peerAvatarRefreshTick: Int = 0

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                StarfieldBackdrop()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(conversations, id: \.id) { conv in
                            Button {
                                openChat(convId: conv.id)
                            } label: {
                                ConversationRowCard(
                                    conversationId: conv.id,
                                    peerId: conv.peerRecipientId,
                                    title: conv.title,
                                    isGroup: conv.isGroup,
                                    groupOwnerUserId: conv.groupOwnerUserId,
                                    previewLine: conversationRowExtras[conv.id]?.previewLine,
                                    previewImageJPEG: conversationRowExtras[conv.id]?.previewImageJPEG,
                                    isGlowing: glowingConversationIDs.contains(conv.id),
                                    rowNamespace: chatOpenNamespace,
                                    verticalStretch: stretchingConversationId == conv.id
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDeleteConversation = (conv.id, conversationTitle(for: conv))
                                } label: {
                                    Label(VaulteL.t("common.delete"), systemImage: "trash")
                                }
                                if !conv.isGroup {
                                    Button {
                                        renamingPeerId = conv.peerRecipientId
                                        renameDraft = VaulteDisplayName.nickname(for: conv.peerRecipientId) ?? ""
                                        showRenameSheet = true
                                    } label: {
                                        Label(VaulteL.t("conversations.rename"), systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .contextMenu {
                                if !conv.isGroup {
                                    Button {
                                        renamingPeerId = conv.peerRecipientId
                                        renameDraft = VaulteDisplayName.nickname(for: conv.peerRecipientId) ?? ""
                                        showRenameSheet = true
                                    } label: {
                                        Label(VaulteL.t("conversations.rename"), systemImage: "pencil")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingDeleteConversation = (conv.id, conversationTitle(for: conv))
                                } label: {
                                    Label(VaulteL.t("conversations.delete_chat"), systemImage: "trash")
                                }
                            }
                        }
                    }
                    .id(peerAvatarRefreshTick)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await refresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: VaulteProfileAvatar.didChangeNotification)) { _ in
                    peerAvatarRefreshTick &+= 1
                }
            }
            .navigationTitle(VaulteL.t("conversations.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSecureExchange = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text(VaulteL.t("conversations.title"))
                        .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .accessibilityLabel(VaulteL.t("newchat.title"))
                }
            }
            .sheet(isPresented: $showNew) {
                NewConversationSheet(store: store, userId: userId) {
                    Task { await refresh() }
                }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupChatSheet(store: store, userId: userId) {
                    Task { await refresh() }
                }
            }
            .sheet(isPresented: $showSecureExchange) {
                SecureExchangeSheet(
                    store: store,
                    userId: userId,
                    onUpdated: {
                        Task { await refresh() }
                    },
                    onOpenConversation: { conversationId in
                        showSecureExchange = false
                        Task {
                            await refresh()
                            await MainActor.run {
                                openChat(convId: conversationId)
                            }
                        }
                    }
                )
            }
            .alert(
                VaulteL.t("conversations.delete_confirm_title"),
                isPresented: Binding(
                    get: { pendingDeleteConversation != nil },
                    set: { if !$0 { pendingDeleteConversation = nil } }
                ),
                presenting: pendingDeleteConversation
            ) { item in
                Button(VaulteL.t("common.delete"), role: .destructive) {
                    Task { await deleteConversation(item.id) }
                }
                Button(VaulteL.t("common.cancel"), role: .cancel) {}
            } message: { item in
                Text(VaulteL.tf1("conversations.delete_confirm_fmt", item.title))
            }
            .alert(VaulteL.t("conversations.delete_failed_title"), isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button(VaulteL.t("common.ok"), role: .cancel) {}
            } message: {
                Text(VaulteL.t(deleteError ?? ""))
            }
            .sheet(isPresented: $showRenameSheet) {
                RenameContactSheet(
                    peerId: renamingPeerId ?? UUID(),
                    draft: $renameDraft,
                    isPresented: $showRenameSheet
                )
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
            }
            .task {
                await refresh()
                await BadgeCache.shared.refresh()
            }
            .navigationDestination(for: UUID.self) { conversationId in
                ChatScreen(
                    store: store,
                    conversationId: conversationId,
                    userId: userId,
                    callManager: callManager,
                    rowNamespace: chatOpenNamespace
                )
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func openChat(convId: UUID) {
        glowingConversationIDs.remove(convId)
        stretchingConversationId = convId
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            // vertical stretch is driven by stretchingConversationId
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                navigationPath.append(convId)
            }
            stretchingConversationId = nil
        }
    }

    private func refresh() async {
        await syncInboxIfNeeded()
        guard let list = try? await store.allConversations() else {
            await MainActor.run {
                conversations = []
                conversationRowExtras = [:]
            }
            return
        }
        var extras: [UUID: (previewLine: String?, previewImageJPEG: Data?)] = [:]
        for conv in list {
            guard let last = try? await store.lastMessageForListPreview(conversationId: conv.id),
                  let plain = last.plaintext, !plain.isEmpty
            else { continue }
            let stripped = ChatViewModel.stripGroupLineDedupePrefix(plain)
            let parsed = ChatViewModel.parseStoredPlaintext(stripped)
            let fromSelf = last.senderId == userId
            let previewLine: String?
            if parsed.image != nil {
                let cap = parsed.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cap, !cap.isEmpty {
                    previewLine = fromSelf ? VaulteL.t("conversations.preview_you_prefix") + cap : cap
                } else {
                    // No caption: list row already shows a thumbnail; avoid a second line like "Foto".
                    previewLine = fromSelf ? VaulteL.t("conversations.preview_you_prefix") + "📷" : nil
                }
            } else if let t = parsed.text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let clipped = String(t.prefix(120))
                previewLine = fromSelf ? VaulteL.t("conversations.preview_you_prefix") + clipped : clipped
            } else {
                previewLine = nil
            }
            if previewLine != nil || parsed.image != nil {
                extras[conv.id] = (previewLine, parsed.image)
            }
        }
        await MainActor.run {
            conversations = list
            conversationRowExtras = extras
        }
        await refreshRelayProfiles(for: list.map(\.peerRecipientId), excluding: userId, maxCount: 24)
        await prefetchPeerProfileAvatarsIfMissing(peerIds: list.map(\.peerRecipientId))
        await MainActor.run {
            peerAvatarRefreshTick &+= 1
        }
    }

    /// Fetches relay profile photos for peers that are not yet cached locally (so the inbox row avatar fills in without opening each chat).
    private func prefetchPeerProfileAvatarsIfMissing(peerIds: [UUID]) async {
        guard let client = try? ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL) else { return }
        let unique = Array(Set(peerIds)).filter { $0 != userId }
        var count = 0
        for peerId in unique {
            if count >= 12 { break }
            count += 1
            do {
                guard let dto = try await client.fetchUser(userId: peerId) else { continue }
                cacheRelayUser(dto)
                guard let b64 = dto.avatarB64, !b64.isEmpty,
                      let data = ChatAPIClient.imageDataFromRelayAvatarBase64(b64),
                      !data.isEmpty,
                      UIImage(data: data) != nil
                else { continue }
                let key = VaulteProfileAvatar.storageKeyPrefix + peerId.uuidString
                UserDefaults.standard.set(data, forKey: key)
            } catch {
                continue
            }
        }
    }

    private func syncInboxIfNeeded() async {
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let inbox = try await client.fetchInboxMessages(recipientId: userId)
            var newlyActiveConversationIDs = Set<UUID>()
            for m in inbox where m.recipientId == userId {
                if let deletedConversationId = VaulteSystemSignals.deletedConversationId(from: m.ciphertextBase64) {
                    try? await store.deleteConversation(deletedConversationId)
                    try? await client.deleteMessage(messageId: m.messageId, requesterId: userId)
                    newlyActiveConversationIDs.remove(deletedConversationId)
                    continue
                }
                let localConversationId: UUID
                if m.padId != m.conversationId {
                    localConversationId = m.conversationId
                } else if let existing = try? await store.directConversationId(for: m.senderId) {
                    localConversationId = existing
                } else {
                    localConversationId = VaulteDirectConversationId.uuid(between: userId, and: m.senderId)
                }
                let alreadyStored = (try? await store.hasMessage(messageId: m.messageId)) ?? false
                if let deletedCutoff = try await store.deletedConversationCutoff(conversationId: localConversationId),
                   m.createdAt <= deletedCutoff
                {
                    continue
                }
                try await store.clearDeletedConversationMarker(conversationId: localConversationId)
                try await store.upsertConversation(id: localConversationId, peerRecipientId: m.senderId)

                if let dto = try? await client.fetchUser(userId: m.senderId) {
                    cacheRelayUser(dto)
                }

                if !alreadyStored {
                    try await store.upsertServerMessage(
                        messageId: m.messageId,
                        conversationId: localConversationId,
                        senderId: m.senderId,
                        recipientId: m.recipientId,
                        padId: m.padId,
                        ciphertextBase64: m.ciphertextBase64,
                        createdAt: m.createdAt
                    )
                }
                if !alreadyStored, m.senderId != userId {
                    newlyActiveConversationIDs.insert(localConversationId)
                }
            }
            if !newlyActiveConversationIDs.isEmpty {
                await MainActor.run {
                    glowingConversationIDs.formUnion(newlyActiveConversationIDs)
                }
            }
        } catch {
            // Keep UI responsive; chat screen sync handles detailed errors.
        }
    }

    private func conversationTitle(for conv: OTPConversationListRow) -> String {
        conversationRowTitle(conv: conv)
    }

    private func deleteConversation(_ conversationId: UUID) async {
        do {
            if let peerId = try? await store.peerRecipient(for: conversationId),
               peerId != userId {
                let vm = ChatViewModel(store: store, conversationId: conversationId, currentUserId: userId)
                try? await vm.updatePeer(to: peerId)
                // First: tell peer to clear their local message history.
                await vm.sendSystemMessage(
                    "\(VaulteSystemSignals.convClearPrefix)\(conversationId.uuidString.lowercased())"
                )
                // Then: tell peer to remove the conversation entry itself.
                await vm.sendConversationDeleteSignal()
            }
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            try await client.deleteConversationMessages(
                conversationId: conversationId,
                requesterUserId: userId
            )
            try await store.deleteConversation(conversationId)
            pendingDeleteConversation = nil
            await refresh()
        } catch {
            pendingDeleteConversation = nil
            deleteError = "conversations.delete_failed_server"
        }
    }
}

private struct ConversationRowCard: View {
    let conversationId: UUID
    let peerId: UUID
    let title: String?
    let isGroup: Bool
    var groupOwnerUserId: UUID? = nil
    let previewLine: String?
    let previewImageJPEG: Data?
    let isGlowing: Bool
    let rowNamespace: Namespace.ID?
    var verticalStretch: Bool = false

    @State private var pulse = false

    private var displayTitle: String {
        conversationRowTitle(isGroup: isGroup, title: title, peerRecipientId: peerId, groupOwnerUserId: groupOwnerUserId)
    }

    var body: some View {
        HStack(spacing: 14) {
            leadingCircle
                .shadow(
                    color: isGlowing ? Color.white.opacity(pulse ? 0.22 : 0.10) : .clear,
                    radius: isGlowing ? (pulse ? 14 : 7) : 0
                )
                .animation(
                    isGlowing
                        ? .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayTitle)
                        .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)

                    if !isGroup, let badge = BadgeCache.shared.badge(for: peerId) {
                        VerifiedBadgeView(badgeType: badge)
                    }
                }

                if let line = previewLine, !line.isEmpty {
                    Text(line)
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(2)
                } else if isGroup {
                    Text(VaulteL.t("newgroup.list_subtitle"))
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                } else if let sub = relayUsername(for: peerId) {
                    Text(sub)
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isGlowing ? 0.9 : 0.65))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            let base = RoundedRectangle(cornerRadius: 22, style: .continuous)
            base
                .fill(Color.clear)
                .overlay(
                    base
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isGlowing ? 0.55 : 0.18),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isGlowing ? 1.45 : 0.9
                        )
                )
        }
        .overlay {
            if isGlowing {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(pulse ? 0.42 : 0.16), lineWidth: 2.2)
                    .blur(radius: pulse ? 11 : 7)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
            }
        }
        .onAppear {
            updateGlowAnimation(active: isGlowing)
        }
        .onChange(of: isGlowing) { _, newValue in
            updateGlowAnimation(active: newValue)
        }
        .modifier(VaulteChatRowMatchedGeometry(id: conversationId, namespace: rowNamespace, isSource: true, enabled: true))
        .scaleEffect(x: 1, y: verticalStretch ? 1.12 : 1, anchor: .center)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: verticalStretch)
    }

    private var leadingCircle: some View {
        ZStack {
            if let jpeg = previewImageJPEG, let ui = UIImage(data: jpeg) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else if let peerImg = VaulteProfileAvatar.loadImage(for: peerId) {
                Image(uiImage: peerImg)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(
                        isGlowing ? Color.white.opacity(0.98) : Color.white.opacity(0.82)
                    )
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .background(
            Circle()
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            Circle()
                .strokeBorder(
                    isGlowing ? Color.white.opacity(0.75) : Color.white.opacity(0.55),
                    lineWidth: 0.5
                )
        )
    }

    private func updateGlowAnimation(active: Bool) {
        guard active else {
            pulse = false
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

struct NewConversationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: OTPStore
    let userId: UUID
    var onCreated: () -> Void

    private enum NewDirectChatMode: String, CaseIterable, Identifiable {
        case standard
        case verifiedOtp

        var id: String { rawValue }
    }

    @State private var peerField = ""
    @State private var errorText: String?
    @State private var searchResults: [RelayUserDTO] = []
    @State private var searchingUsers = false
    @State private var selectedChatMode: NewDirectChatMode = .standard
    @Bindable private var subscription = VaulteSubscriptionManager.shared

    var body: some View {
        AbsoluteCinemaSheetRoot {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(VaulteL.t("newchat.title"))
                                .font(VaulteTypography.swiftUIFont(size: 26, weight: .bold))
                                .foregroundStyle(.white.opacity(0.96))
                            Text("Pick a recipient and choose which direct chat mode to create.")
                                .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                                .foregroundStyle(.white.opacity(0.58))
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Chat type")
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .tracking(0.8)

                            VStack(spacing: 10) {
                                modeCard(
                                    mode: .standard,
                                    title: "Standard E2E",
                                    subtitle: "Fast private chat with the default secure mode.",
                                    accent: Color.green.opacity(0.9),
                                    icon: "lock.fill"
                                )
                                if subscription.hasVerifiedOtpLimitedAccess {
                                    modeCard(
                                        mode: .verifiedOtp,
                                        title: "One Time Pad",
                                        subtitle: verifiedOtpModeSubtitle,
                                        accent: Color.red.opacity(0.92),
                                        icon: "shield.fill"
                                    )
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(VaulteL.t("newchat.find_section"))
                                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .tracking(0.8)
                            }

                            HStack(alignment: .center, spacing: 10) {
                                TextField(VaulteL.t("newchat.field_placeholder"), text: $peerField)
                                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .background { VaulteGlassChrome.fieldBackground() }

                                Button(action: searchByUsername) {
                                    HStack(spacing: 8) {
                                        if searchingUsers {
                                            ProgressView()
                                                .tint(.white.opacity(0.92))
                                        } else {
                                            Image(systemName: "magnifyingglass")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        Text(VaulteL.t("newchat.search_users"))
                                    }
                                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color.white.opacity(0.12))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .vaulteCTAGlow(color: .white.opacity(0.75), cornerRadius: 14)
                                .disabled(searchingUsers || normalizedUsernameInput.count < 2)
                            }

                            Text(VaulteL.t("newchat.footer_recipient"))
                                .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                                .foregroundStyle(.white.opacity(0.42))

                            if !searchResults.isEmpty {
                                VStack(spacing: 10) {
                                    ForEach(searchResults) { user in
                                        Button {
                                            peerField = formattedAtUsername(core: user.username)
                                        } label: {
                                            HStack(spacing: 12) {
                                                ZStack {
                                                    Circle()
                                                        .fill(Color.white.opacity(0.08))
                                                        .overlay(
                                                            Circle()
                                                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                                        )
                                                        .frame(width: 44, height: 44)
                                                    Image(systemName: "at")
                                                        .font(.system(size: 18, weight: .bold))
                                                        .foregroundStyle(.white.opacity(0.88))
                                                }
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(formattedAtUsername(core: user.username))
                                                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                                                        .foregroundStyle(.white.opacity(0.95))
                                                    Text(verbatim: user.userId.uuidString.lowercased())
                                                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                                                        .foregroundStyle(.white.opacity(0.38))
                                                        .lineLimit(1)
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(.white.opacity(0.5))
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)
                                            .background {
                                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                    .fill(Color.white.opacity(0.04))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                                                    )
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if let errorText {
                            Text(VaulteL.t(errorText))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(Color.red.opacity(0.88))
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .navigationTitle(VaulteL.t("newchat.title"))
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: subscription.hasVerifiedOtpLimitedAccess) { _, hasAccess in
                    if !hasAccess, selectedChatMode == .verifiedOtp {
                        selectedChatMode = .standard
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(VaulteL.t("common.cancel")) { dismiss() }
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(VaulteL.t("common.create")) { create() }
                    }
                }
            }
            .background(Color.clear)
        }
    }

    private var verifiedOtpModeSubtitle: String {
        if subscription.hasVerifiedOtpFullAccess {
            return "One Time Pad chat with single-use pads."
        }
        if subscription.hasVerifiedOtpLimitedAccess {
            return "Single-use pad chat. Premier can prepare it, Elite can activate it."
        }
        return "Single-use pad chat. Available with Elite."
    }

    @ViewBuilder
    private func modeCard(
        mode: NewDirectChatMode,
        title: String,
        subtitle: String,
        accent: Color,
        icon: String
    ) -> some View {
        let selected = selectedChatMode == mode
        Button {
            selectedChatMode = mode
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(selected ? 0.22 : 0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(accent.opacity(0.95))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(subtitle)
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.54))
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 10)

                ZStack {
                    Circle()
                        .fill(selected ? accent.opacity(0.22) : Color.white.opacity(0.05))
                        .overlay(
                            Circle()
                                .strokeBorder(selected ? accent.opacity(0.55) : Color.white.opacity(0.14), lineWidth: 1)
                        )
                        .frame(width: 24, height: 24)
                    if selected {
                        Circle()
                            .fill(accent.opacity(0.95))
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.07 : 0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(selected ? accent.opacity(0.42) : Color.white.opacity(0.12), lineWidth: selected ? 1.15 : 0.9)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func create() {
        let trimmed = peerField.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                let peer: UUID
                if let rawUUID = UUID(uuidString: trimmed) {
                    peer = rawUUID
                    if let dto = try await client.fetchUser(userId: rawUUID) {
                        cacheRelayUser(dto)
                    }
                } else {
                    let normalized = normalizeUsername(trimmed)
                    guard let resolved = try await client.resolveUsername(normalized)
                    else {
                        errorText = "newchat.error_username_not_found"
                        return
                    }
                    peer = resolved.userId
                    cacheRelayUser(resolved)
                }
                let hadExistingConversation = (try? await store.directConversationId(for: peer)) != nil
                let deterministicId = sharedConversationId(userA: userId, userB: peer)
                _ = try await store.createConversation(
                    peerRecipientId: peer,
                    conversationId: deterministicId
                )
                if !hadExistingConversation {
                    let seedVM = ChatViewModel(store: store, conversationId: deterministicId, currentUserId: userId)
                    await seedVM.sendSystemMessage("seed_chat")
                }
                onCreated()
                dismiss()
            } catch {
                errorText = "newchat.error_create_failed"
            }
        }
    }

    private var normalizedUsernameInput: String {
        normalizeUsername(peerField)
    }

    private func normalizeUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func searchByUsername() {
        errorText = nil
        let q = normalizedUsernameInput
        guard q.count >= 2 else {
            searchResults = []
            return
        }
        searchingUsers = true
        Task {
            defer { searchingUsers = false }
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                if let exact = try await client.resolveUsername(q) {
                    searchResults = [exact]
                    return
                }
                searchResults = try await client.searchUsers(query: q, limit: 20)
            } catch {
                searchResults = []
                errorText = "newchat.error_username_not_found"
            }
        }
    }
}

/// Create a group: everyone must already have a 1:1 encrypted session with you (same keys as DM).
struct NewGroupChatSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: OTPStore
    let userId: UUID
    var onCreated: () -> Void

    @State private var groupTitle = ""
    @State private var membersField = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        AbsoluteCinemaSheetRoot {
            NavigationStack {
                Form {
                    Section {
                        TextField(VaulteL.t("newgroup.field_title"), text: $groupTitle)
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .regular))
                    } header: {
                        Text(VaulteL.t("newgroup.section_title"))
                    }

                    Section {
                        TextField(VaulteL.t("newgroup.field_members_placeholder"), text: $membersField, axis: .vertical)
                            .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                            .lineLimit(3...10)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text(VaulteL.t("newgroup.section_members"))
                    } footer: {
                        Text(VaulteL.t("newgroup.footer_members"))
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    }

                    if let errorText {
                        Section {
                            Text(VaulteL.t(errorText))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle(VaulteL.t("newgroup.title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(VaulteL.t("common.cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(VaulteL.t("common.create")) { create() }
                            .disabled(busy)
                    }
                }
            }
            .background(Color.clear)
        }
    }

    private func create() {
        let title = groupTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorText = "newgroup.error_title"
            return
        }
        let lines = membersField
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            errorText = "newgroup.error_need_peers"
            return
        }

        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                var peerIds: [UUID] = []
                for line in lines {
                    let trimmed = String(line)
                    if let u = UUID(uuidString: trimmed) {
                        peerIds.append(u)
                        if let dto = try? await client.fetchUser(userId: u) {
                            cacheRelayUser(dto)
                        }
                    } else {
                        let normalized = normalizeUsername(trimmed)
                        guard let resolved = try await client.resolveUsername(normalized) else {
                            errorText = "newchat.error_username_not_found"
                            return
                        }
                        peerIds.append(resolved.userId)
                        cacheRelayUser(resolved)
                    }
                }
                var all = Array(Set(peerIds + [userId]))
                guard all.count >= 2 else {
                    errorText = "newgroup.error_need_peers"
                    return
                }
                for peer in all where peer != userId {
                    let pairId = VaulteDirectConversationId.uuid(between: userId, and: peer)
                    if ConversationKeyStore.loadRatchetState(for: pairId) == nil,
                       ConversationKeyStore.load(for: pairId) == nil {
                        errorText = "errvm.group_no_dm_keys"
                        return
                    }
                }
                all.sort { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
                let listPeer = all.first(where: { $0 != userId }) ?? all[0]
                let groupId = try await store.createGroupConversation(
                    title: title,
                    memberUserIds: all,
                    listPeerId: listPeer,
                    ownerUserId: userId
                )
                let vm = ChatViewModel(store: store, conversationId: groupId, currentUserId: userId)
                await vm.loadPeer()
                await vm.sendGroupMemberBootstrap(title: title, memberUUIDs: all, ownerUUID: userId, adminUUIDs: [])
                onCreated()
                dismiss()
            } catch {
                errorText = "newchat.error_create_failed"
            }
        }
    }

    private func normalizeUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}

private struct SecureIdentityQRPayload: Codable {
    let v: Int
    let userId: UUID
    let username: String
    /// X25519 identity public key (Base64).
    let publicKey: String
    /// X25519 initial ratchet public key — present in v ≥ 2.
    let ratchetKey: String?
    /// Random 32-byte PSK for post-quantum hybrid — present in v ≥ 2.
    let psk: String?
    let relay: String
}

private struct SecureExchangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: OTPStore
    let userId: UUID
    var onUpdated: () -> Void
    var onOpenConversation: ((UUID) -> Void)? = nil

    @State private var qrImage: UIImage?
    @State private var statusText: String?
    @State private var loadingQR = false
    @State private var isHandlingScanResult = false
    private var mediaCardSide: CGFloat {
        let proposed = UIScreen.main.bounds.width * 0.60
        return min(max(proposed, 180), 260)
    }

    var body: some View {
        AbsoluteCinemaSheetRoot {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Button { dismiss() } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .frame(width: 30, height: 30)
                            }

                            Text(VaulteL.t("secure_qr.title"))
                                .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                                .foregroundStyle(.white.opacity(0.95))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                                        )
                                )
                        }

                        VStack(spacing: 16) {
                            HStack(alignment: .center, spacing: 14) {
                                qrCard
                                Text(VaulteL.t("secure_qr.sharing_blurb"))
                                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(alignment: .center, spacing: 14) {
                                Text(VaulteL.t("secure_qr.scanning_blurb"))
                                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                cameraCard
                            }

                        }
                        .padding(16)

                        if let statusText {
                            Text(statusText)
                                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
                .task {
                    await generateMyQR()
                }
            }
            .background(Color.clear)
        }
    }

    private var qrCard: some View {
        Group {
            if let qrImage {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
                        )
                    Image(uiImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(8)
                }
            } else if loadingQR {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(ProgressView())
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.55))
                    )
            }
        }
        .frame(width: mediaCardSide, height: mediaCardSide)
    }

    private var cameraCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
                )
            QRScannerView { value in
                Task {
                    guard !isHandlingScanResult else { return }
                    isHandlingScanResult = true
                    defer { isHandlingScanResult = false }
                    await importFromSecureQR(value)
                }
            } onCancel: {}
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(1)
        }
        .frame(width: mediaCardSide, height: mediaCardSide)
    }

    private func generateMyQR() async {
        loadingQR = true
        defer { loadingQR = false }
        do {
            let client    = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let username  = (try await client.fetchUser(userId: userId)?.username) ?? "name"
            let publicKey  = try await IdentityKeyExchange.shared.localPublicKeyBase64()
            let ratchetKey = try await IdentityKeyExchange.shared.localRatchetPublicKeyBase64()
            let psk        = await IdentityKeyExchange.shared.localQRPsk()
            let payload = SecureIdentityQRPayload(
                v: 2,
                userId: userId,
                username: username,
                publicKey: publicKey,
                ratchetKey: ratchetKey,
                psk: psk,
                relay: VaulteRelayConfiguration.baseURL.absoluteString
            )
            let enc = JSONEncoder()
            enc.keyEncodingStrategy = .convertToSnakeCase
            let data = try enc.encode(payload)
            guard let text = String(data: data, encoding: .utf8) else {
                statusText = VaulteL.t("secure_qr.status_encoding_fail")
                return
            }
            qrImage = try OTPQRService.makeQRImage(from: text)
            statusText = nil
        } catch {
            statusText = VaulteL.t("secure_qr.status_build_fail")
        }
    }

    private func importFromSecureQR(_ raw: String) async {
        do {
            guard let data = raw.data(using: .utf8) else {
                statusText = VaulteL.t("secure_qr.status_invalid")
                return
            }
            let dec = JSONDecoder()
            dec.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try dec.decode(SecureIdentityQRPayload.self, from: data)
            guard payload.v == 1 || payload.v == 2 else {
                statusText = VaulteL.t("secure_qr.status_unsupported_version")
                return
            }
            guard payload.userId != userId else {
                statusText = VaulteL.t("secure_qr.status_own_qr")
                return
            }
            VaulteDisplayName.setRelayUsername(payload.username, for: payload.userId)
            VaulteDisplayName.setCustomName(nil, for: payload.userId)
            let cid = sharedConversationId(userA: userId, userB: payload.userId)
            _ = try await store.createConversation(
                peerRecipientId: payload.userId,
                conversationId: cid
            )

            if payload.v >= 2,
               let peerRatchetKey = payload.ratchetKey,
               let peerPsk        = payload.psk {
                // v2: PQXDH hybrid master secret + Double Ratchet session init
                try await IdentityKeyExchange.shared.initializeRatchetSession(
                    localUserId:     userId,
                    peerUserId:      payload.userId,
                    peerIdentityB64: payload.publicKey,
                    peerRatchetB64:  peerRatchetKey,
                    peerPskB64:      peerPsk,
                    conversationId:  cid
                )
                statusText = VaulteL.t("secure_qr.status_e2e_ready")
            } else {
                // v1 fallback: plain ECDH AES-GCM key
                try await IdentityKeyExchange.shared.deriveAndStoreKey(
                    peerPublicKeyBase64: payload.publicKey,
                    conversationId: cid
                )
                statusText = VaulteL.t("secure_qr.status_aes_ready")
            }
            onUpdated()
            onOpenConversation?(cid)
        } catch {
            statusText = VaulteL.t("secure_qr.status_read_fail")
        }
    }
}

private struct PixelIdentityGlyph: View {
    private let pattern: [String] = [
        "000000111111000000",
        "000001122221100000",
        "000012222222210000",
        "000122111111221000",
        "001221000000122100",
        "012210000000012210",
        "122100000000001221",
        "221000000000000122",
        "210000000000000012",
        "100000000000000001",
        "110000000000000011",
        "122100000000001221",
        "012210000000012210",
        "001221000000122100",
        "000122100001221000",
        "000012210012210000",
        "000001221122100000",
        "000000122221000000",
        "000000012210000000",
        "000000001100000000",
    ]

    var body: some View {
        GeometryReader { geo in
            let rows = pattern.count
            let cols = pattern.first?.count ?? 1
            let cellW = geo.size.width / CGFloat(cols)
            let cellH = geo.size.height / CGFloat(rows)

            Canvas { context, _ in
                for (r, row) in pattern.enumerated() {
                    for (c, ch) in row.enumerated() {
                        let color: Color
                        switch ch {
                        case "1":
                            color = Color.white.opacity(0.88)
                        case "2":
                            color = Color.white.opacity(0.55)
                        default:
                            continue
                        }
                        let rect = CGRect(
                            x: CGFloat(c) * cellW,
                            y: CGFloat(r) * cellH,
                            width: cellW.rounded(.up),
                            height: cellH.rounded(.up)
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
    }
}

// MARK: - Chat

private enum VaulteProfileAvatar {
    static let storageKeyPrefix = "vaulteprive.profile.avatar."
    static let didChangeNotification = Notification.Name("vaulteprive.profile.avatar.changed")

    static func loadImage(for userId: UUID) -> UIImage? {
        let key = storageKeyPrefix + userId.uuidString
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return UIImage(data: data)
    }
}

private struct GroupDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let userId: UUID
    @Bindable var vm: ChatViewModel

    @State private var showRenameSheet = false
    @State private var renameDraft = ""

    private var resolvedTitle: String {
        let raw = vm.conversationDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleOpt: String? = raw.isEmpty ? nil : raw
        return conversationRowTitle(
            isGroup: true,
            title: titleOpt,
            peerRecipientId: vm.peerRecipientId ?? userId,
            groupOwnerUserId: vm.groupOwnerUserId
        )
    }

    private var sortedMemberIds: [UUID] {
        vm.groupMemberUUIDs.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    private func roleLocalizationKey(for memberId: UUID) -> String {
        if let owner = vm.groupOwnerUserId, memberId == owner { return "group.role.owner" }
        if vm.groupAdminUserIds.contains(memberId) { return "group.role.admin" }
        return "group.role.member"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sortedMemberIds, id: \.self) { mid in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: mid))
                                .font(VaulteTypography.swiftUIFont(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                            Text(VaulteL.t(roleLocalizationKey(for: mid)))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(VaulteL.t("group.members_section"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(resolvedTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(VaulteL.t("common.done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if vm.groupOwnerUserId == userId {
                        Button(VaulteL.t("group.rename")) {
                            renameDraft = vm.conversationDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            showRenameSheet = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showRenameSheet) {
                NavigationStack {
                    Form {
                        Section {
                            TextField(VaulteL.t("group.rename_placeholder"), text: $renameDraft)
                                .font(VaulteTypography.swiftUIFont(size: 17, weight: .regular))
                        } header: {
                            Text(VaulteL.t("group.rename_field_header"))
                        }
                        if let err = vm.userError {
                            Section {
                                Text(VaulteL.resolveChatUserError(err))
                                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                    .foregroundStyle(Color.red.opacity(0.88))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.black.ignoresSafeArea())
                    .navigationTitle(VaulteL.t("group.rename"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(VaulteL.t("common.cancel")) { showRenameSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(VaulteL.t("common.save")) {
                                Task {
                                    await vm.renameGroupTitle(renameDraft)
                                    if vm.userError == nil { showRenameSheet = false }
                                }
                            }
                        }
                    }
                }
                .onAppear { vm.userError = nil }
                .presentationDetents([.height(280)])
            }
        }
    }
}

private struct IdentifiableChatPhoto: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Modal list for disappearing-message TTL (replaces the compact `Menu` so options are easier to read).
private struct VanishingMessagesPickerSheet: View {
    @Binding var isPresented: Bool
    let selectedSeconds: Int
    let onPick: (Int) -> Void

    var body: some View {
        AbsoluteCinemaSheetRoot {
            NavigationStack {
                List {
                    Section {
                        row(VaulteL.t("chat.vanish.off"), 0)
                    }
                    Section {
                        row(VaulteL.t("chat.vanish.1s"), 1)
                        row(VaulteL.t("chat.vanish.2s"), 2)
                        row(VaulteL.t("chat.vanish.5s"), 5)
                        row(VaulteL.t("chat.vanish.10s"), 10)
                        row(VaulteL.t("chat.vanish.15s"), 15)
                        row(VaulteL.t("chat.vanish.20s"), 20)
                        row(VaulteL.t("chat.vanish.30s"), 30)
                    } header: {
                        Text(VaulteL.t("chat.vanish.section_seconds"))
                    }
                    Section {
                        row(VaulteL.t("chat.vanish.1m"), 60)
                        row(VaulteL.t("chat.vanish.5m"), 300)
                        row(VaulteL.t("chat.vanish.15m"), 900)
                        row(VaulteL.t("chat.vanish.30m"), 1800)
                    } header: {
                        Text(VaulteL.t("chat.vanish.section_minutes"))
                    }
                    Section {
                        row(VaulteL.t("chat.vanish.1h"), 3600)
                        row(VaulteL.t("chat.vanish.1d"), 86400)
                        row(VaulteL.t("chat.vanish.7d"), 86400 * 7)
                    } header: {
                        Text(VaulteL.t("chat.vanish.section_hours_days"))
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle(VaulteL.t("chat.vanish.sheet_title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(VaulteL.t("common.close")) {
                            isPresented = false
                        }
                    }
                }
            }
            .background(Color.clear)
        }
        #if !os(macOS)
        .presentationBackground(.clear)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private func row(_ title: String, _ secs: Int) -> some View {
        Button {
            onPick(secs)
        } label: {
            HStack {
                Text(title)
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: selectedSeconds == secs ? .bold : .regular))
                    .foregroundStyle(.white.opacity(selectedSeconds == secs ? 0.95 : 0.72))
                Spacer()
                if selectedSeconds == secs {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.cyan.opacity(0.92))
                }
            }
        }
    }
}

struct ChatScreen: View {
    let store: OTPStore
    let userId: UUID
    var callManager: CallManager?
    private let rowNamespace: Namespace.ID?
    @Environment(\.dismiss) private var dismiss
    @Bindable private var subscription = VaulteSubscriptionManager.shared

    @State private var vm: ChatViewModel
    @State private var myProfileAvatar: UIImage?
    @State private var peerProfileAvatar: UIImage?
    @State private var showPeerEditor = false
    @State private var peerDraft = ""
    @State private var peerEditError: String?
    @State private var appeared = false
    @State private var liveSyncStarted = false
    @State private var showActiveCall = false
    @State private var showSafetyNumber = false
    @State private var showRenameContact = false
    @State private var contactRenameDraft = ""
    @State private var screenshotBannerVisible = false
    @State private var composerPhotoPickerItem: PhotosPickerItem?
    @State private var pendingComposerRawPhoto: Data?
    @State private var pendingComposerRawPreview: UIImage?
    @State private var composerPhotoQualityMode: VaulteChatComposerImageEncoder.Mode = .standard
    @State private var showComposerPhotoQualitySheet = false
    /// Bumped when key material may have changed so the E2E header badge re-reads the keychain.
    @State private var e2eBadgeEpoch = 0
    /// Keeps `matchedGeometryEffect` on the header only for the open transition; then drops it so the plaque doesn’t drift toward the list row.
    @State private var chatHeaderGeometryBridgeActive = true
    @State private var showGroupDetails = false
    @State private var photoViewerItem: IdentifiableChatPhoto?
    @State private var showVanishPicker = false
    @State private var showVerifiedOtpSetup = false
    @State private var verifiedOtpBundleSizeMB = 10
    @State private var verifiedOtpError: String?
    @State private var verifiedOtpImportCenter = VerifiedOtpImportCenter.shared
    @State private var showVerifiedOtpDeleteConfirm = false
    @State private var showVerifiedOtpFileImporter = false

    init(store: OTPStore, conversationId: UUID, userId: UUID, callManager: CallManager? = nil, rowNamespace: Namespace.ID? = nil) {
        self.store = store
        self.userId = userId
        self.callManager = callManager
        self.rowNamespace = rowNamespace
        _vm = State(
            initialValue: ChatViewModel(store: store, conversationId: conversationId, currentUserId: userId)
        )
    }

    var body: some View {
        Group {
            #if os(iOS)
            // `ScreenshotProtected` uses `isSecureTextEntry`; iOS never renders that subtree in screenshots. Only wrap while screenshots are not peer-approved.
            if vm.screenshotAllowed {
                chatBody
            } else {
                ScreenshotProtected(content: chatBody)
            }
            #else
            chatBody
            #endif
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 30, height: 30, alignment: .center)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    if vm.isGroupConversation {
                        Button {
                            showGroupDetails = true
                        } label: {
                            Text(chatHeaderTitle)
                                .font(VaulteTypography.swiftUIFont(size: 18, weight: .bold))
                                .foregroundStyle(.white.opacity(0.93))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(chatHeaderTitle)
                            .font(VaulteTypography.swiftUIFont(size: 18, weight: .bold))
                            .foregroundStyle(.white.opacity(0.93))
                            .lineLimit(1)
                        if let peer = vm.peerRecipientId,
                           let badge = BadgeCache.shared.badge(for: peer) {
                            VerifiedBadgeView(badgeType: badge)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                if let callManager, !vm.isGroupConversation {
                    Button {
                        guard let peer = vm.peerRecipientId else { return }
                        callManager.startCall(peerId: peer, conversationId: vm.conversationId, peerName: chatHeaderTitle)
                        showActiveCall = true
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }

                let hasE2E = chatConversationHasE2EMaterial(conversationId: vm.conversationId)
                HStack(spacing: 5) {
                    if hasE2E && vm.activeSecureMode == .verifiedOtp {
                        Image(systemName: "shield.fill")
                            .font(.system(size: 9, weight: .bold))
                    } else {
                        Image(systemName: hasE2E ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(securityBadgeTitle(hasE2E: hasE2E))
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .bold))
                    if vm.pendingSecureModeState != nil {
                        Circle()
                            .fill(Color.white.opacity(0.82))
                            .frame(width: 5, height: 5)
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(securityBadgeForeground(hasE2E: hasE2E))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(securityBadgeFill(hasE2E: hasE2E))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    securityBadgeStroke(hasE2E: hasE2E),
                                    lineWidth: 0.9
                                )
                        )
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if hasE2E && vm.activeSecureMode == .verifiedOtp {
                        showVerifiedOtpSetup = true
                    } else {
                        showSafetyNumber = true
                    }
                }
                .onLongPressGesture(minimumDuration: 0.55) {
                    guard hasE2E, vm.activeSecureMode == .verifiedOtp else { return }
                    Task { await vm.requestVerifiedOtpModeToggle() }
                }
                .id(e2eBadgeEpoch)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            }
            .padding(.horizontal)
            .padding(.top, 0)
            .padding(.bottom, 10)
            .modifier(
                VaulteChatRowMatchedGeometry(
                    id: vm.conversationId,
                    namespace: rowNamespace,
                    isSource: false,
                    enabled: chatHeaderGeometryBridgeActive
                )
            )

            if screenshotBannerVisible {
                screenshotBanner
            }

            if vm.showsIncomingModeSwitchBanner {
                secureModeSwitchBanner
            }

            if vm.modeToastTitle != nil {
                secureModeToast
            }

            ScrollViewReader { scrollProxy in
                List {
                        ForEach(vm.rows) { row in
                            ChatMessageBubble(
                                row: row,
                                myAvatar: myProfileAvatar,
                                peerAvatar: peerProfileAvatar,
                                incomingUsesGroupGlyph: vm.isGroupConversation,
                                copyAllowed: subscription.hasEliteAccess && vm.copyAllowed,
                                canRequestCopyPermission: subscription.hasEliteAccess && !vm.copyAllowed,
                                displayText: displayText(for: row),
                                onPhotoTap: { photoViewerItem = IdentifiableChatPhoto(image: $0) },
                                onCopy: {
                                    if let data = row.imageJPEGData, let img = UIImage(data: data) {
                                        UIPasteboard.general.image = img
                                    } else {
                                        UIPasteboard.general.string = displayText(for: row)
                                    }
                                },
                                onRequestCopy: {
                                    Task { await vm.requestCopyPermission() }
                                },
                                onDelete: {
                                    Task { await vm.deleteMessage(row.id) }
                                },
                                onEdit: (row.isMine
                                    && row.imageJPEGData == nil
                                    && !row.isInvalid
                                    && !ChatViewModel.isCorruptedDisplayedPlaintext(row.text)) ? {
                                    vm.draftText = displayText(for: row)
                                    Task { await vm.deleteMessage(row.id) }
                                } : nil
                            )
                            .id(row.id)
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await vm.syncFromServer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: vm.rows.count) { _, _ in
                    scrollChatToEnd(proxy: scrollProxy)
                }
                .onChange(of: vm.rows.last?.id) { _, _ in
                    scrollChatToEnd(proxy: scrollProxy)
                }
                .onAppear {
                    scrollChatToEnd(proxy: scrollProxy)
                }
            }

            if let err = vm.userError {
                Text(VaulteL.resolveChatUserError(err))
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
            }

            if vm.draftExceedsNextPad {
                Text(VaulteL.tf1("chat.pad_too_long_fmt", vm.nextOutboundPadByteLength))
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                    .foregroundStyle(Color.red.opacity(0.92))
                    .padding(.horizontal)
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $composerPhotoPickerItem, matching: .images) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.08))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                            )
                            .frame(width: 42, height: 42)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.88))
                    }
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                }
                .buttonStyle(.plain)

                if let jpeg = vm.pendingComposerImageJPEG, let thumb = UIImage(data: jpeg) {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .overlay(alignment: .bottomLeading) {
                                if vm.pendingComposerImageUses4K {
                                    Text("4K")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.cyan.opacity(0.85)))
                                        .padding(4)
                                }
                            }
                        Button {
                            vm.pendingComposerImageJPEG = nil
                            vm.pendingComposerImageUses4K = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                        .accessibilityLabel(VaulteL.t("chat.remove_attachment_a11y"))
                    }
                }

                ZStack(alignment: .trailing) {
                    TextField(VaulteL.t("chat.message_placeholder"), text: $vm.draftText, axis: .vertical)
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1...5)
                        .padding(.leading, 14)
                        .padding(.trailing, 40)
                        .padding(.vertical, 12)

                    Button {
                        if subscription.hasEliteAccess {
                            showVanishPicker = true
                        } else {
                            vm.userError = nil
                            vm.showEliteLockedToast(
                                title: VaulteL.t("chat.vanish_elite_only"),
                                detail: VaulteL.t("chat.vanish_elite_detail")
                            )
                        }
                    } label: {
                        Image(systemName: "timer")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(vm.disappearingMessageSeconds > 0 ? Color.cyan.opacity(0.92) : Color.white.opacity(0.5))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(VaulteL.t("chat.vanish.menu_a11y"))
                    .padding(.trailing, 4)
                }
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }

                Button {
                    Task {
                        await vm.send()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(vm.canSend ? Color.white.opacity(0.12) : Color.white.opacity(0.07))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                            )
                            .frame(width: 42, height: 42)

                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(vm.canSend ? Color.white.opacity(0.9) : Color.white.opacity(0.45))
                    }
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                }
                .disabled(!vm.canSend)
            }
            .padding(.horizontal)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.easeInOut(duration: 0.25), value: appeared)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showVanishPicker) {
            VanishingMessagesPickerSheet(
                isPresented: $showVanishPicker,
                selectedSeconds: vm.disappearingMessageSeconds,
                onPick: { secs in
                    Task {
                        await vm.setDisappearingMessageSeconds(secs)
                        showVanishPicker = false
                    }
                }
            )
        }
        .sheet(isPresented: $showPeerEditor) {
            AbsoluteCinemaSheetRoot {
                NavigationStack {
                    Form {
                        if let u = UUID(uuidString: peerDraft.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            LabeledContent(VaulteL.t("chat.section_handle")) {
                                Text(verbatim: VaulteDisplayName.handle(for: u))
                                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Section(VaulteL.t("chat.section_recipient_uuid")) {
                            TextField(VaulteL.t("chat.field_recipient_uuid"), text: $peerDraft)
                                .font(VaulteTypography.swiftUIFont(size: 17, weight: .regular))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        if let peerEditError {
                            Section {
                                Text(peerEditError)
                                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .navigationTitle(VaulteL.t("chat.recipient_nav_title"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(VaulteL.t("common.cancel")) {
                                peerEditError = nil
                                showPeerEditor = false
                            }
                        }

                        ToolbarItem(placement: .confirmationAction) {
                            Button(VaulteL.t("common.save")) {
                                let t = peerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard let u = UUID(uuidString: t) else {
                                    peerEditError = VaulteL.t("chat.error_invalid_uuid")
                                    return
                                }

                                Task {
                                    try? await vm.updatePeer(to: u)
                                    peerEditError = nil
                                    showPeerEditor = false
                                }
                            }
                        }
                    }
                }
                .background(Color.clear)
            }
        }
        .sheet(isPresented: $showComposerPhotoQualitySheet) {
            AbsoluteCinemaSheetRoot {
                VStack(spacing: 18) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 36, height: 5)
                        .padding(.top, 10)

                    Text("Send photo as")
                        .font(VaulteTypography.swiftUIFont(size: 18, weight: .bold))
                        .foregroundStyle(.white)

                    if let pendingComposerRawPreview {
                        Image(uiImage: pendingComposerRawPreview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 112, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                    }

                    Picker("", selection: $composerPhotoQualityMode) {
                        Text("HD").tag(VaulteChatComposerImageEncoder.Mode.standard)
                        Text("4K").tag(VaulteChatComposerImageEncoder.Mode.raw4K)
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)

                    Text(composerPhotoQualityMode == .raw4K ? "Original quality, larger file." : "Compressed for faster sending.")
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.5))

                    HStack(spacing: 10) {
                        Button(VaulteL.t("common.cancel")) {
                            pendingComposerRawPhoto = nil
                            pendingComposerRawPreview = nil
                            showComposerPhotoQualitySheet = false
                        }
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        )

                        Button("Attach") {
                            Task { await confirmComposerPhotoSelection() }
                        }
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .task(id: vm.conversationId) {
            chatHeaderGeometryBridgeActive = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled {
                chatHeaderGeometryBridgeActive = false
            }
        }
        .onDisappear {
            chatHeaderGeometryBridgeActive = false
        }
        .task {
            await vm.loadPeer()
            await vm.refreshDisappearingFromStore()
            await loadPeerAvatarFromRelay()
            await vm.syncFromServer()
            await vm.refreshDisappearingFromStore()
            e2eBadgeEpoch &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaulteOtpPairingDidStart)) { note in
            guard note.object as? UUID == vm.conversationId else { return }
            showVerifiedOtpSetup = false
            showVerifiedOtpFileImporter = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .vaulteOtpPairingDidComplete)) { note in
            guard note.object as? UUID == vm.conversationId else { return }
            showVerifiedOtpSetup = false
            showVerifiedOtpFileImporter = false
            Task {
                await vm.loadSecureModeState()
                await vm.refreshVerifiedOtpSummary()
            }
        }
        .onChange(of: composerPhotoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await prepareComposerPhotoSelection(from: newItem) }
        }
        .task {
            guard !liveSyncStarted else { return }
            liveSyncStarted = true
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await vm.syncFromServer()
                await vm.refreshDisappearingFromStore()
                e2eBadgeEpoch &+= 1
            }
        }
        .onChange(of: vm.peerRecipientId) { _, _ in
            Task { await loadPeerAvatarFromRelay() }
            e2eBadgeEpoch &+= 1
        }
        .onAppear {
            appeared = true
            refreshMyProfileAvatar()
            Task { await loadPeerAvatarFromRelay() }
            e2eBadgeEpoch &+= 1
        }
        .onChange(of: showSafetyNumber) { _, isPresented in
            if !isPresented { e2eBadgeEpoch &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshMyProfileAvatar()
            Task {
                await vm.refreshDisappearingFromStore()
                await loadPeerAvatarFromRelay()
            }
            e2eBadgeEpoch &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: VaulteProfileAvatar.didChangeNotification)) { _ in
            refreshMyProfileAvatar()
            Task { await loadPeerAvatarFromRelay() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            Task { await vm.expirePendingModeSwitchIfNeeded(showToastIfOutgoing: true) }
            guard vm.disappearingMessageSeconds > 0 else { return }
            Task { await vm.purgeExpiredMessages() }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showActiveCall) {
            if let callManager {
                ActiveCallView(callManager: callManager)
            }
        }
        .fullScreenCover(item: $photoViewerItem) { item in
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            photoViewerItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 30, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 18)
                        .padding(.top, 14)
                    }
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showSafetyNumber) {
            SafetyNumberSheet(
                userId: userId,
                peerId: vm.peerRecipientId,
                conversationId: vm.conversationId,
                secureMode: vm.activeSecureMode,
                isGroupConversation: vm.isGroupConversation,
                groupMemberUUIDs: vm.groupMemberUUIDs,
                onOpenOneTimePad: {
                    showSafetyNumber = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        showVerifiedOtpSetup = true
                    }
                }
            )
        }
        .sheet(isPresented: $showRenameContact) {
            RenameContactSheet(
                peerId: vm.peerRecipientId ?? UUID(),
                draft: $contactRenameDraft,
                isPresented: $showRenameContact
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGroupDetails) {
            GroupDetailsSheet(userId: userId, vm: vm)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showVerifiedOtpSetup) {
            AbsoluteCinemaSheetRoot {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Verified OTP")
                                    .font(VaulteTypography.swiftUIFont(size: 26, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.96))
                                Text("Directional pad bundles for the separate stronger OTP mode.")
                                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.56))
                            }

                            otpGlassSection(title: "Bundle size") {
                                Picker("Bundle size", selection: $verifiedOtpBundleSizeMB) {
                                    Text("10 MB").tag(10)
                                    Text("50 MB").tag(50)
                                    Text("100 MB").tag(100)
                                }
                                .pickerStyle(.segmented)
                                Text("Verified OTP uses nearby-only directional bundles. Elite unlocks full activation; Premier stays limited to bundle prep and import.")
                                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.58))
                            }

                            if let send = vm.verifiedOtpStateSummary?.sendBundle,
                               let receive = vm.verifiedOtpStateSummary?.receiveBundle {
                                otpGlassSection(title: "Trust") {
                                    otpFingerprintRow(title: "Send fingerprint", value: send.fingerprint.shortCode)
                                    otpFingerprintRow(title: "Receive fingerprint", value: receive.fingerprint.shortCode)
                                    Text("Compare these fingerprints in person before requesting activation.")
                                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.58))
                                }

                                otpGlassSection(title: "Capacity") {
                                    otpFingerprintRow(
                                        title: "Send pad remaining",
                                        value: "~\(approximateOtpCharacterCount(for: send.remainingBytes)) symbols"
                                    )
                                    otpFingerprintRow(
                                        title: "Receive pad remaining",
                                        value: "~\(approximateOtpCharacterCount(for: receive.remainingBytes)) symbols"
                                    )
                                    Text("Approximate text capacity. Simple text is close to 1 byte per symbol; emoji and some languages can consume more.")
                                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                            }

                            otpGlassSection(title: "Actions") {
                                otpActionButton("Create and export bundles", accent: .white, glow: true) {
                                    Task {
                                        do {
                                            verifiedOtpError = nil
                                            _ = try await vm.createVerifiedOtpBundles(byteCount: verifiedOtpBundleSizeMB * 1_000_000)
                                        } catch {
                                            verifiedOtpError = error.localizedDescription
                                        }
                                    }
                                }
                                .disabled(!subscription.hasVerifiedOtpLimitedAccess)

                                if let exportURL = vm.verifiedOtpPendingExportURL {
                                    // Use UIActivityViewController (not ShareLink) so we get a
                                    // completion callback and can wipe the file after sharing.
                                    Button {
                                        let avc = UIActivityViewController(
                                            activityItems: [exportURL],
                                            applicationActivities: nil
                                        )
                                        avc.completionWithItemsHandler = { _, completed, _, _ in
                                            // Wipe regardless of whether the user actually shared —
                                            // they've seen the sheet, so the intent was to transfer.
                                            if completed {
                                                Task { @MainActor in vm.wipeExportedBundleIfNeeded() }
                                            }
                                        }
                                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                           let root = scene.windows.first?.rootViewController {
                                            root.present(avc, animated: true)
                                        }
                                    } label: {
                                        otpActionLabel("Share .vaultepad", accent: .white)
                                    }
                                }

                                otpActionButton("Import pending .vaultepad", accent: .white) {
                                    guard let pending = verifiedOtpImportCenter.pendingURL,
                                          let data = try? Data(contentsOf: pending),
                                          let conversationId = VerifiedOtpBundleCrypto.peekConversationId(from: data)
                                    else {
                                        verifiedOtpError = "Could not read the pending pad file."
                                        return
                                    }
                                    VaulteOtpPadPairingCenter.shared.attachReceiverImport(
                                        url: pending,
                                        conversationId: conversationId
                                    )
                                }
                                .disabled(verifiedOtpImportCenter.pendingURL == nil || !subscription.hasVerifiedOtpLimitedAccess)

                                otpActionButton("Choose .vaultepad from Files", accent: .white) {
                                    showVerifiedOtpFileImporter = true
                                }
                                .disabled(!subscription.hasVerifiedOtpLimitedAccess)

                                if vm.verifiedOtpStateSummary?.sendBundle != nil,
                                   vm.verifiedOtpStateSummary?.receiveBundle != nil,
                                   vm.activeSecureMode != .verifiedOtp {
                                    otpActionButton("Request Verified OTP Activation", accent: .red) {
                                        Task { await vm.requestVerifiedOtpModeToggle() }
                                    }
                                    .disabled(!subscription.hasVerifiedOtpFullAccess)
                                }
                            }

                            if !subscription.hasVerifiedOtpLimitedAccess {
                                otpGlassSection(title: "Access") {
                                    Text("Verified OTP is unavailable on this plan. Elite unlocks the full stronger mode, while Premier can prepare and import limited bundles.")
                                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                            } else if !subscription.hasVerifiedOtpFullAccess {
                                otpGlassSection(title: "Premier limits") {
                                    Text("Premier can prepare, export, and import bundles here, but only Elite can activate Verified OTP Strong Mode after peer approval.")
                                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                        .foregroundStyle(.white.opacity(0.58))
                                }
                            }

                            if vm.verifiedOtpStateSummary?.sendBundle != nil || vm.verifiedOtpStateSummary?.receiveBundle != nil {
                                otpGlassSection(title: "Manage") {
                                    otpActionButton("Disable Verified OTP", accent: .white) {
                                        Task { await vm.disableVerifiedOtpMode() }
                                    }
                                    .disabled(vm.activeSecureMode != .verifiedOtp)

                                    otpActionButton("Revoke bundles", accent: .orange) {
                                        Task { await vm.revokeVerifiedOtpBundles() }
                                    }

                                    otpActionButton("Delete bundles", accent: .red) {
                                        showVerifiedOtpDeleteConfirm = true
                                    }
                                }
                            }

                            if let verifiedOtpError {
                                Text(verifiedOtpError)
                                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                                    .foregroundStyle(Color.red.opacity(0.88))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 18)
                        .padding(.bottom, 28)
                    }
                    .navigationTitle("Verified OTP")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(VaulteL.t("common.close")) { showVerifiedOtpSetup = false }
                        }
                    }
                }
                .background(Color.clear)
            }
            .alert("Delete Verified OTP bundles?", isPresented: $showVerifiedOtpDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task { await vm.deleteVerifiedOtpBundles() }
                }
                Button(VaulteL.t("common.cancel"), role: .cancel) {}
            } message: {
                Text("This removes local directional pad bundles for this chat and switches the conversation back to standard E2E.")
            }
            .fileImporter(
                isPresented: $showVerifiedOtpFileImporter,
                allowedContentTypes: [UTType.vaulteVaultepad],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    guard VaulteVaultepadDocumentType.isVaultepadURL(url) else {
                        verifiedOtpError = "Please choose a .vaultepad file."
                        return
                    }
                    Task {
                        verifiedOtpError = nil
                        showVerifiedOtpFileImporter = false
                        showVerifiedOtpSetup = false
                        let accessGranted = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessGranted {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        VerifiedOtpImportCenter.shared.handleIncomingURL(url)
                    }
                case .failure(let error):
                    verifiedOtpError = error.localizedDescription
                }
            }
        }
        // Screenshot detection — notify peer only if not yet approved; ignore if already allowed
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard subscription.hasEliteAccess else { return }
            guard !vm.screenshotAllowed else { return }
            Task {
                await vm.sendSystemMessage("screenshot")
                withAnimation(.easeInOut(duration: 0.3)) { screenshotBannerVisible = true }
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                withAnimation(.easeInOut(duration: 0.4)) { screenshotBannerVisible = false }
            }
        }
        // Peer took a screenshot — ask if we allow it
        .alert(VaulteL.t("chat.screenshot_request_title"), isPresented: $vm.peerRequestsScreenshot) {
            Button(VaulteL.t("common.allow")) {
                Task { await vm.approveScreenshotForPeer() }
            }
            Button(VaulteL.t("common.deny"), role: .cancel) {}
        } message: {
            Text(VaulteL.tf1("chat.screenshot_request_fmt", chatHeaderTitle))
        }
        // Peer requests copy permission
        .alert(VaulteL.t("chat.copy_request_title"), isPresented: $vm.peerRequestsCopy) {
            Button(VaulteL.t("common.allow")) {
                Task { await vm.approveCopyForPeer() }
            }
            Button(VaulteL.t("common.deny"), role: .cancel) {}
        } message: {
            Text(VaulteL.tf1("chat.copy_request_fmt", chatHeaderTitle))
        }
    }

    @ViewBuilder
    private var screenshotBanner: some View {
        let bg = Capsule(style: .continuous).fill(Color.orange.opacity(0.22))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.orange.opacity(0.45), lineWidth: 0.8))
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 12, weight: .semibold))
            Text(VaulteL.t("chat.screenshot_banner"))
                .font(VaulteTypography.swiftUIFont(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background { bg }
        .padding(.horizontal)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var secureModeSwitchBanner: some View {
        if let request = vm.pendingSecureModeRequest {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    request.to == .verifiedOtp
                        ? "Your chat partner wants to enable Verified OTP"
                        : VaulteL.t("chat.mode_switch_banner_disable_title")
                )
                .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                .foregroundStyle(.white)

                if request.to == .verifiedOtp {
                    Text("This separate stronger mode uses directional OTP bundles. Approve only after your pads are imported and trusted.")
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                }

                HStack(spacing: 10) {
                    Button(request.to == .verifiedOtp ? "Approve" : VaulteL.t("chat.mode_switch_accept")) {
                        Task { await vm.acceptPendingModeSwitch() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                    )

                    Button(request.to == .verifiedOtp ? "Decline" : VaulteL.t("chat.mode_switch_reject")) {
                        Task { await vm.rejectPendingModeSwitch() }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8))
                    )
                }
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.9)
                    )
            )
            .padding(.horizontal)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func otpGlassSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.46))

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.09),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.9)
                )
        )
    }

    @ViewBuilder
    private func otpFingerprintRow(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.94))
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.92))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    @ViewBuilder
    private func otpActionButton(
        _ title: String,
        accent: Color,
        glow: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            otpActionLabel(title, accent: accent)
        }
        .buttonStyle(.plain)
        .vaulteCTAGlow(color: glow ? accent.opacity(0.45) : .clear, cornerRadius: 16)
    }

    @ViewBuilder
    private func otpActionLabel(_ title: String, accent: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(VaulteTypography.swiftUIFont(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(accent.opacity(0.94))
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(accent.opacity(0.22), lineWidth: 0.9)
                )
        )
    }

    private func approximateOtpCharacterCount(for remainingBytes: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: max(0, remainingBytes)), number: .decimal)
    }

    @ViewBuilder
    private var secureModeToast: some View {
        if let title = vm.modeToastTitle {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                if let detail = vm.modeToastDetail, !detail.isEmpty {
                    Text(detail)
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.9)
                    )
            )
            .padding(.horizontal)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func securityBadgeTitle(hasE2E: Bool) -> String {
        guard hasE2E else { return VaulteL.t("chat.no_e2e_badge") }
        switch vm.activeSecureMode {
        case .e2e:
            return VaulteL.t("chat.e2e_badge")
        case .verifiedOtp:
            return "OTP"
        }
    }

    private func securityBadgeForeground(hasE2E: Bool) -> Color {
        guard hasE2E else { return Color.orange.opacity(0.95) }
        switch vm.activeSecureMode {
        case .verifiedOtp:
            return Color.red.opacity(0.96)
        case .e2e:
            return Color.green.opacity(0.82)
        }
    }

    private func securityBadgeFill(hasE2E: Bool) -> Color {
        guard hasE2E else { return Color.orange.opacity(0.14) }
        switch vm.activeSecureMode {
        case .verifiedOtp:
            return Color.red.opacity(0.17)
        case .e2e:
            return Color.green.opacity(0.12)
        }
    }

    private func securityBadgeStroke(hasE2E: Bool) -> Color {
        guard hasE2E else { return Color.orange.opacity(0.48) }
        switch vm.activeSecureMode {
        case .verifiedOtp:
            return Color.red.opacity(0.58)
        case .e2e:
            return Color.green.opacity(0.35)
        }
    }

    private func scrollChatToEnd(proxy: ScrollViewProxy) {
        guard let lastId = vm.rows.last?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    private func prepareComposerPhotoSelection(from item: PhotosPickerItem) async {
        defer {
            composerPhotoPickerItem = nil
        }
        guard let raw = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { vm.userError = "profile.status_photo_load_failed" }
            return
        }
        await MainActor.run {
            pendingComposerRawPhoto = raw
            pendingComposerRawPreview = UIImage(data: raw)
            composerPhotoQualityMode = .standard
            showComposerPhotoQualitySheet = true
        }
    }

    private func confirmComposerPhotoSelection() async {
        guard let raw = pendingComposerRawPhoto else {
            await MainActor.run { showComposerPhotoQualitySheet = false }
            return
        }
        let mode = composerPhotoQualityMode
        guard let jpeg = VaulteChatComposerImageEncoder.jpegForComposer(from: raw, mode: mode) else {
            await MainActor.run {
                showComposerPhotoQualitySheet = false
                pendingComposerRawPhoto = nil
                pendingComposerRawPreview = nil
                vm.userError = mode == .raw4K ? "errvm.photo_4k_too_large" : "errvm.photo_too_large"
            }
            return
        }
        await MainActor.run {
            showComposerPhotoQualitySheet = false
            pendingComposerRawPhoto = nil
            pendingComposerRawPreview = nil
            vm.pendingComposerImageJPEG = jpeg
            vm.pendingComposerImageUses4K = mode == .raw4K
            vm.userError = nil
        }
    }

    private func displayText(for row: ChatRow) -> String {
        if row.isInvalid || ChatViewModel.isCorruptedDisplayedPlaintext(row.text) {
            return VaulteL.t("chat.encrypted_message")
        }
        if row.imageJPEGData != nil {
            if let t = row.text, !t.isEmpty { return t }
            return VaulteL.t("chat.photo_message")
        }
        if let t = row.text {
            return t
        }
        return row.isMine ? VaulteL.t("chat.sending") : ""
    }

    private var chatHeaderTitle: String {
        if vm.isGroupConversation {
            let raw = vm.conversationDisplayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let titleOpt: String? = raw.isEmpty ? nil : raw
            return conversationRowTitle(
                isGroup: true,
                title: titleOpt,
                peerRecipientId: vm.peerRecipientId ?? userId,
                groupOwnerUserId: vm.groupOwnerUserId
            )
        }
        guard let peer = vm.peerRecipientId else { return VaulteL.t("chat.header_conversation") }
        // Show the public relay profile name first, then fall back to the live relay username.
        if let serverName = VaulteDisplayName.customName(for: peer),
           !serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return serverName
        }
        if let username = relayUsername(for: peer) {
            return username
        }
        return VaulteL.t("chat.header_conversation")
    }

    /// Matches `SafetyNumberSheet`: Double Ratchet state or legacy AES conversation key counts as E2E-capable.
    private func chatConversationHasE2EMaterial(conversationId: UUID) -> Bool {
        if vm.isGroupConversation {
            for m in vm.groupMemberUUIDs where m != userId {
                let pairId = VaulteDirectConversationId.uuid(between: userId, and: m)
                if ConversationKeyStore.loadRatchetState(for: pairId) != nil { return true }
                if ConversationKeyStore.load(for: pairId) != nil { return true }
            }
            if let p = vm.peerRecipientId, p != userId {
                let pairId = VaulteDirectConversationId.uuid(between: userId, and: p)
                if ConversationKeyStore.loadRatchetState(for: pairId) != nil { return true }
                if ConversationKeyStore.load(for: pairId) != nil { return true }
            }
            return false
        }
        // DM: ratchet/AES may live under deterministic pair id (X3DH) while `conversationId` is the thread row.
        if let p = vm.peerRecipientId, p != userId {
            let pairId = VaulteDirectConversationId.uuid(between: userId, and: p)
            if ConversationKeyStore.loadRatchetState(for: pairId) != nil { return true }
            if ConversationKeyStore.load(for: pairId) != nil { return true }
        }
        if ConversationKeyStore.loadRatchetState(for: conversationId) != nil { return true }
        if ConversationKeyStore.load(for: conversationId) != nil { return true }
        return false
    }

    private func refreshMyProfileAvatar() {
        myProfileAvatar = VaulteProfileAvatar.loadImage(for: userId)
    }

    /// Shows any cached peer avatar immediately, then refreshes from relay.
    /// Does not clear `peerProfileAvatar` when `peerRecipientId` is still nil — avoids races with parallel `.task` / `onAppear` work wiping a valid image.
    private func loadPeerAvatarFromRelay() async {
        let (peer, isGroup) = await MainActor.run { (vm.peerRecipientId, vm.isGroupConversation) }
        if isGroup {
            await MainActor.run { peerProfileAvatar = nil }
            return
        }
        guard let peer else { return }
        if let local = VaulteProfileAvatar.loadImage(for: peer) {
            await MainActor.run { peerProfileAvatar = local }
        } else {
            await MainActor.run { peerProfileAvatar = nil }
        }
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            guard let dto = try await client.fetchUser(userId: peer) else { return }
            cacheRelayUser(dto)
            guard let b64 = dto.avatarB64, !b64.isEmpty,
                  let data = ChatAPIClient.imageDataFromRelayAvatarBase64(b64),
                  let img = UIImage(data: data)
            else { return }
            let key = VaulteProfileAvatar.storageKeyPrefix + peer.uuidString
            UserDefaults.standard.set(data, forKey: key)
            await MainActor.run { peerProfileAvatar = img }
            NotificationCenter.default.post(name: VaulteProfileAvatar.didChangeNotification, object: nil)
        } catch {
            await MainActor.run {
                peerProfileAvatar = VaulteProfileAvatar.loadImage(for: peer)
            }
        }
    }
}

// MARK: - Screenshot-protected container

/// Hosts SwiftUI content inside the secure canvas of a `UITextField`.
/// This is the same family of iOS screenshot-blackout trick used by secure chat apps.
private struct ScreenshotProtected<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> ScreenshotProtectedHostController<Content> {
        ScreenshotProtectedHostController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: ScreenshotProtectedHostController<Content>, context: Context) {
        uiViewController.update(rootView: content)
    }
}

private final class ScreenshotProtectedHostController<Content: View>: UIViewController {
    private let secureField = UITextField()
    private let hostingController: UIHostingController<Content>
    private weak var secureContainer: UIView?

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        secureField.translatesAutoresizingMaskIntoConstraints = false
        secureField.isSecureTextEntry = true
        secureField.backgroundColor = .clear
        secureField.textColor = .clear
        secureField.tintColor = .clear
        secureField.text = " "

        view.addSubview(secureField)
        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: view.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installHostedViewIfNeeded()
    }

    func update(rootView: Content) {
        hostingController.rootView = rootView
        installHostedViewIfNeeded()
    }

    private func installHostedViewIfNeeded() {
        let target = secureContainer ?? resolveSecureContainer(in: secureField) ?? secureField
        secureContainer = target

        guard hostingController.view.superview !== target else { return }
        target.backgroundColor = .clear
        target.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: target.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])
    }

    private func resolveSecureContainer(in textField: UITextField) -> UIView? {
        textField.layoutIfNeeded()
        let candidates = textField.subviews + textField.subviews.flatMap(\.subviews)
        return candidates.first {
            let name = NSStringFromClass(type(of: $0))
            return name.contains("Canvas") || name.contains("LayoutCanvasView")
        }
    }
}

// MARK: - Chat message bubble

private struct ChatMessageBubble: View {
    let row: ChatRow
    let myAvatar: UIImage?
    let peerAvatar: UIImage?
    /// When true, incoming bubbles show the group glyph instead of a peer profile photo.
    var incomingUsesGroupGlyph: Bool = false
    let copyAllowed: Bool
    let canRequestCopyPermission: Bool
    let displayText: String
    var onPhotoTap: ((UIImage) -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onRequestCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        let isMine = row.isMine
        let bubbleColors: [Color] = isMine
            ? [Color.white.opacity(0.10), Color.white.opacity(0.04)]
            : [Color.white.opacity(0.07), Color.white.opacity(0.025)]
        let borderColor: Color = isMine ? Color.white.opacity(0.18) : Color.white.opacity(0.12)
        let textOpacity: Double = isMine ? 0.98 : 0.92

        let bubbleColumn = VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
            Group {
                if let imgData = row.imageJPEGData, let uiImg = UIImage(data: imgData) {
                    VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 182, height: 182)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPhotoTap?(uiImg)
                            }
                        if let cap = row.text, !cap.isEmpty {
                            Group {
                                if copyAllowed {
                                    Text(cap).textSelection(.enabled)
                                } else {
                                    Text(cap).textSelection(.disabled)
                                }
                            }
                            .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                            .foregroundStyle(.white.opacity(textOpacity))
                            .multilineTextAlignment(isMine ? .trailing : .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                    Group {
                        if copyAllowed {
                            Text(displayText).textSelection(.enabled)
                        } else {
                            Text(displayText).textSelection(.disabled)
                        }
                    }
                    .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(textOpacity))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: bubbleColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 4)
            }
            .contextMenu {
                if copyAllowed, let onCopy {
                    Button { onCopy() } label: {
                        Label(VaulteL.t("chat.context.copy"), systemImage: "doc.on.doc")
                    }
                }
                if canRequestCopyPermission, let onRequestCopy {
                    Button { onRequestCopy() } label: {
                        Label(VaulteL.t("chat.context.request_copy"), systemImage: "lock.open.rotation")
                    }
                }
                if let onEdit {
                    Button { onEdit() } label: {
                        Label(VaulteL.t("chat.context.edit"), systemImage: "pencil")
                    }
                }
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Label(VaulteL.t("chat.context.delete"), systemImage: "trash")
                    }
                }
            }

            Text(row.date.formatted(date: .omitted, time: .shortened))
                .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 4)

        }

        Group {
            if isMine {
                HStack(alignment: .center, spacing: 8) {
                    Spacer(minLength: 4)
                    bubbleColumn
                    messageAvatarView(image: myAvatar, size: 32)
                }
            } else {
                HStack(alignment: .center, spacing: 8) {
                    if incomingUsesGroupGlyph {
                        messageGroupGlyphAvatar(size: 32)
                    } else {
                        messageAvatarView(image: peerAvatar, size: 32)
                    }
                    bubbleColumn
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 4)
                }
            }
        }
    }

    @ViewBuilder
    private func messageGroupGlyphAvatar(size: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.34, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.88))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.white.opacity(0.06)))
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.88), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func messageAvatarView(image: UIImage?, size: CGFloat) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .background(Circle().fill(Color.white.opacity(0.06)))
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.88), lineWidth: 0.5)
        )
    }
}

// MARK: - Pad inventory

struct PadInventoryView: View {
    let store: OTPStore

    @State private var conversations: [OTPConversationListRow] = []
    @State private var counts: [UUID: (Int, Int)] = [:]
    @State private var generateCount = 32
    @State private var selectedConversation: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section(VaulteL.t("otp.section_conversation")) {
                    Picker(VaulteL.t("otp.picker_chat"), selection: $selectedConversation) {
                        Text(VaulteL.t("otp.select")).tag(Optional<UUID>.none)
                        ForEach(conversations, id: \.id) { c in
                            Text(conversationRowTitle(conv: c))
                                .tag(Optional(c.id))
                        }
                    }
                }

                if let cid = selectedConversation, let c = counts[cid] {
                    Section(VaulteL.t("otp.section_remaining")) {
                        LabeledContent(VaulteL.t("otp.inbound")) { Text("\(c.0)") }
                        LabeledContent(VaulteL.t("otp.outbound")) { Text("\(c.1)") }
                    }
                }

                Section(VaulteL.t("otp.section_generate")) {
                    Stepper(value: $generateCount, in: 1...256) {
                        Text(VaulteL.tf1("otp.count_fmt", generateCount))
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .regular))
                    }

                    Button(action: { Task { await generate(direction: .outbound) } }) {
                        Text(VaulteL.t("otp.add_outbound"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                                    )
                            }
                    }
                    .buttonStyle(.plain)

                    Button(action: { Task { await generate(direction: .inbound) } }) {
                        Text(VaulteL.t("otp.add_inbound"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(VaulteL.t("otp.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))

                        Text(VaulteL.t("otp.title"))
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                            }
                    }
                }
            }
            .task { await refreshList() }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
    }

    private func refreshList() async {
        if let list = try? await store.allConversations() {
            conversations = list
            if selectedConversation == nil { selectedConversation = list.first?.id }
        }

        var next: [UUID: (Int, Int)] = [:]
        for c in conversations {
            if let r = try? await store.remainingCounts(conversationId: c.id) {
                next[c.id] = r
            }
        }
        counts = next
    }

    private func generate(direction: OTPDirection) async {
        guard let cid = selectedConversation else { return }
        try? await store.generatePads(conversationId: cid, direction: direction, count: generateCount, byteLength: 256)
        await refreshList()
    }
}

// MARK: - QR transfer

struct QRTransferView: View {
    let store: OTPStore
    let userId: UUID
    @State private var conversations: [OTPConversationListRow] = []
    @State private var selectedConversation: UUID?
    @State private var qrImage: UIImage?
    @State private var status: String?
    @State private var showScanner = false
    @State private var exportMaxPads = 6
    @State private var lastBatchToken: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(VaulteL.t("qr.section_export")) {
                    Picker(VaulteL.t("qr.conversation"), selection: $selectedConversation) {
                        Text(VaulteL.t("otp.select")).tag(Optional<UUID>.none)
                        ForEach(conversations, id: \.id) { c in
                            Text(conversationRowTitle(conv: c))
                                .tag(Optional(c.id))
                        }
                    }

                    Stepper(value: $exportMaxPads, in: 1...32) {
                        Text(VaulteL.tf1("qr.max_pads_fmt", exportMaxPads))
                    }

                    Text(VaulteL.t("qr.export_body"))
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)

                    Button(action: { Task { await exportPeerQR() } }) {
                        Text(VaulteL.t("qr.show_qr"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                                    )
                            }
                    }
                    .buttonStyle(.plain)

                    if let lastBatchToken {
                        Text(VaulteL.tf1("qr.token_fmt", lastBatchToken))
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if let img = qrImage {
                    Section {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    }
                }

                Section(VaulteL.t("qr.section_import")) {
                    Button(action: { showScanner = true }) {
                        Text(VaulteL.t("qr.scan"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Rectangle())
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.38), lineWidth: 1)
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }

                if let status {
                    Section {
                        Text(status)
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .regular))
                    }
                }
            }
            .navigationTitle(VaulteL.t("qr.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.85))

                        Text(VaulteL.t("qr.title"))
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                            }
                    }
                }
            }
            .task { await loadConversations() }
            .sheet(isPresented: $showScanner) {
                AbsoluteCinemaSheetRoot {
                    NavigationStack {
                        QRScannerView { value in
                            Task {
                                await importFromString(value)
                                showScanner = false
                            }
                        } onCancel: {
                            showScanner = false
                        }
                        .ignoresSafeArea()
                    }
                    .navigationTitle(VaulteL.t("qr.scan_nav"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(VaulteL.t("common.close")) { showScanner = false }
                        }
                    }
                }
            }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
    }

    private func loadConversations() async {
        if let list = try? await store.allConversations() {
            conversations = list
            if selectedConversation == nil { selectedConversation = list.first?.id }
        }
    }

    private func exportPeerQR() async {
        guard let cid = selectedConversation else {
            status = VaulteL.t("qr.pick_conversation")
            return
        }

        status = nil
        qrImage = nil
        lastBatchToken = nil

        do {
            let payload = try await store.makePeerInboundPayload(conversationId: cid, maxPads: exportMaxPads)
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let created = try await client.createPadBatchToken(
                request: RelayPadBatchRequest(
                    conversationId: payload.conversationId,
                    direction: payload.direction.rawValue,
                    pads: payload.pads,
                    ownerUserId: nil,
                    ttlSeconds: nil
                )
            )

            let token = created.token
            guard OTPQRService.validateBatchToken(token) else {
                status = VaulteL.t("qr.invalid_token")
                return
            }
            qrImage = try OTPQRService.makeQRImage(from: token)
            lastBatchToken = token
            status = VaulteL.tf1("qr.token_ready_fmt", payload.pads.count)
        } catch {
            status = VaulteL.t("qr.create_batch_fail")
        }
    }

    private func importFromString(_ raw: String) async {
        do {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if OTPQRService.validateBatchToken(cleaned) {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                let batch = try await client.consumePadBatch(token: cleaned, requesterUserId: userId)
                guard let direction = OTPDirection(rawValue: batch.direction) else {
                    status = VaulteL.t("qr.invalid_direction")
                    return
                }
                let payload = OTPQRPayload(
                    schemaVersion: 2,
                    conversationId: batch.conversationId,
                    direction: direction,
                    pads: batch.pads
                )
                try await store.importQRPayload(payload)
                status = VaulteL.tf1("qr.imported_fmt", payload.pads.count)
                await loadConversations()
                return
            }

            // Backward compatibility for legacy full-payload QR exports.
            let payload = try OTPQRService.decodePayload(from: cleaned)
            try await store.importQRPayload(payload)
            status = VaulteL.tf1("qr.imported_legacy_fmt", payload.pads.count)
            await loadConversations()
        } catch RelayAPIError.relayError(let code) {
            switch code {
            case "batch_consumed":
                status = VaulteL.t("qr.err.batch_consumed")
            case "batch_expired":
                status = VaulteL.t("qr.err.batch_expired")
            case "owner_mismatch":
                status = VaulteL.t("qr.err.owner_mismatch")
            case "requester_user_id_required":
                status = VaulteL.t("qr.err.requester_required")
            case "batch_not_found":
                status = VaulteL.t("qr.err.batch_not_found")
            case "invalid_token":
                status = VaulteL.t("qr.err.invalid_token")
            case "signature_expired":
                status = VaulteL.t("qr.err.signature_expired")
            default:
                status = VaulteL.tf1("qr.err.relay_fmt", code)
            }
        } catch RelayAPIError.notFound {
            status = VaulteL.t("qr.err.not_found")
        } catch RelayAPIError.unauthorized {
            status = VaulteL.t("qr.err.unauthorized")
        } catch {
            status = VaulteL.t("qr.read_payload_fail")
        }
    }
}

// MARK: - Settings

struct AppSettingsView: View {
    let store: OTPStore
    let userId: UUID

    @ObservedObject private var appLanguageModel = VaulteAppLanguage.shared
    @AppStorage("vaulteprive.relay.setupComplete") private var setupComplete = false
    @State private var confirmPanic = false
    @State private var confirmResetRegistration = false
    @State private var confirmHardReset = false
    @State private var panicStatus: String?
    @State private var resetStatus: String?
    @State private var usernameDraft: String = ""
    @State private var avatarImage: UIImage?
    @AppStorage("vaulteprive.profile.displayName") private var profileDisplayName = "Vaulté User"
    @State private var biometryType: LABiometryType = .none
    @AppStorage("vaulteprive.auth.biometricEnabled") private var biometricEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profilePlate
                    premiumPlate
                    languagePlate
                    securityPlate
                    toolsPlate
                    accountPlate
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .navigationTitle(VaulteL.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(VaulteL.t("settings.title"))
                        .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .task {
                await loadUsername()
                loadAvatar()
                refreshBiometryType()
                await BadgeCache.shared.refresh()
            }
            .confirmationDialog(
                VaulteL.t("settings.wipe_pads_title"),
                isPresented: $confirmPanic,
                titleVisibility: .visible
            ) {
                Button(VaulteL.t("settings.erase_button"), role: .destructive) {
                    Task {
                        try? await store.panicWipe()
                        panicStatus = VaulteL.t("settings.panic_done_local")
                    }
                }

                Button(VaulteL.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(VaulteL.t("settings.wipe_pads_msg"))
            }
            .confirmationDialog(
                VaulteL.t("settings.reset_registration_title"),
                isPresented: $confirmResetRegistration,
                titleVisibility: .visible
            ) {
                Button(VaulteL.t("common.reset"), role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: "vaulteprive.relay.setupComplete")
                    resetStatus = VaulteL.t("settings.reset_done_msg")
                }

                Button(VaulteL.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(VaulteL.t("settings.reset_registration_msg"))
            }
            .confirmationDialog(
                VaulteL.t("settings.delete_account_title"),
                isPresented: $confirmHardReset,
                titleVisibility: .visible
            ) {
                Button(VaulteL.t("settings.delete_everywhere_button"), role: .destructive) {
                    Task { await performHardResetEverywhere() }
                }
                Button(VaulteL.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(VaulteL.t("settings.delete_account_msg"))
            }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
    }

    private var languagePlate: some View {
        VStack(alignment: .leading, spacing: 10) {
            plateTitle(VaulteL.t("settings.language_section"), icon: "globe")
            Picker(
                "",
                selection: Binding(
                    get: { appLanguageModel.code },
                    set: { appLanguageModel.setCode($0) }
                )
            ) {
                Text(VaulteL.t("language.english")).tag("en")
                Text(VaulteL.t("language.german")).tag("de")
                Text(VaulteL.t("language.french")).tag("fr")
            }
            .pickerStyle(.segmented)
            .tint(.green.opacity(0.75))
            Text(VaulteL.t("settings.language_footer"))
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { thinPlateBackground }
    }

    private var profilePlate: some View {
        NavigationLink {
            ProfileDetailsView(
                userId: userId,
                displayName: $profileDisplayName,
                usernameDraft: $usernameDraft,
                avatarImage: $avatarImage
            )
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .frame(width: 56, height: 56)
                    if let avatarImage {
                        Image(uiImage: avatarImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profileDisplayName.isEmpty ? VaulteL.t("settings.profile_default_name") : profileDisplayName)
                            .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                        if let badge = BadgeCache.shared.badge(for: userId) {
                            VerifiedBadgeGlyph(badgeType: badge)
                        }
                    }
                    Text(usernameDraft.isEmpty ? "@set_username" : usernameDraft)
                        .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.62))
                    if let badge = BadgeCache.shared.badge(for: userId) {
                        HStack(spacing: 6) {
                            VerifiedBadgeGlyph(badgeType: badge)
                            Text(settingsBadgeLabel(for: badge))
                                .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green.opacity(0.88))
                            .frame(width: 6, height: 6)
                        Text(VaulteL.t("settings.protected_relay"))
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(16)
        .background { thinPlateBackground }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var premiumPlate: some View {
        NavigationLink {
            PremiumHubView(store: store, userId: userId)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.92))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(VaulteL.t("settings.premium_section"))
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text(VaulteL.t("settings.premium_subtitle"))
                        .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
            .background { thinPlateBackground }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func settingsBadgeLabel(for badge: BadgeType) -> String {
        switch badge {
        case .official:
            return VaulteL.t("verified.official_account")
        case .verified:
            return VaulteL.t("verified.premium_account")
        case .diamond:
            return VaulteL.t("verified.owner_account")
        }
    }

    private var securityPlate: some View {
        VStack(alignment: .leading, spacing: 10) {
            plateTitle(VaulteL.t("settings.security_title"), icon: "shield.lefthalf.filled")

            Toggle(isOn: $biometricEnabled) {
                Text(VaulteL.tf1("settings.enable_biometric_fmt", biometryLabel))
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundStyle(.white)
            }
            .tint(.green.opacity(0.85))
            .disabled(biometryType == .none)

            Button(VaulteL.t("settings.erase_local_keys"), role: .destructive) {
                confirmPanic = true
            }
            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            if let panicStatus {
                Text(panicStatus)
                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
            }

        }
        .padding(14)
        .background { thinPlateBackground }
    }

    private var toolsPlate: some View {
        VStack(alignment: .leading, spacing: 10) {
            plateTitle(VaulteL.t("settings.tools_title"), icon: "wrench.and.screwdriver")

            Label(VaulteL.t("settings.e2e_mode_enabled"), systemImage: "lock.shield.fill")
                .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                .foregroundStyle(.white)

            NavigationLink {
                PrivacyPolicyMarkdownView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Privacy Policy")
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.44))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            NavigationLink {
                SecurityPolicyMarkdownView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "lock.doc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(VaulteL.t("premium.security_doc"))
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.44))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            NavigationLink {
                WhitepaperView()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                    Text("Security Architecture")
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.44))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background { thinPlateBackground }
    }

    private var accountPlate: some View {
        VStack(alignment: .leading, spacing: 10) {
            plateTitle(VaulteL.t("settings.account_title"), icon: "person.crop.circle.badge.exclamationmark")

            Button(VaulteL.t("settings.reset_registration"), role: .destructive) {
                confirmResetRegistration = true
            }
            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            Button(VaulteL.t("settings.delete_everywhere"), role: .destructive) {
                confirmHardReset = true
            }
            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            if let resetStatus {
                Text(resetStatus)
                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
        .padding(14)
        .background { thinPlateBackground }
    }

    @ViewBuilder
    private func plateTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
            Text(title)
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.84))
            Spacer()
        }
    }

    private var thinPlateBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.12),
                        lineWidth: 0.9
                    )
            )
    }

    private func loadUsername() async {
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            if let me = try await client.fetchUser(userId: userId) {
                if !me.username.isEmpty {
                    usernameDraft = formattedAtUsername(core: me.username)
                }
                cacheRelayUser(me)
            }
        } catch {
            // Keep local draft empty when profile fetch fails.
        }
    }

    private func loadAvatar() {
        let key = "vaulteprive.profile.avatar.\(userId.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let img = UIImage(data: data)
        else { return }
        avatarImage = img
    }

    private var biometryLabel: String {
        switch biometryType {
        case .faceID: return VaulteL.t("settings.biometry_faceid")
        case .touchID: return VaulteL.t("settings.biometry_touchid")
        default: return VaulteL.t("settings.biometry_generic")
        }
    }

    private func refreshBiometryType() {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            biometryType = context.biometryType
        } else {
            biometryType = .none
            biometricEnabled = false
        }
    }

    private func performHardResetEverywhere() async {
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            try await client.hardResetAccount(userId: userId)
        } catch {
            // Continue with local wipe even if relay is unavailable.
        }

        try? await store.wipeAllLocalData()
        PassphraseEnclaveStore.deleteAllVerifiers()
        ConversationKeyStore.deleteAll()
        LocalIdentityStore.deleteAllX3DHKeys()
        LocalIdentityStore.clearAllTOFUPins()
        LocalIdentityStore.deleteUserID()
        await IdentityKeyExchange.shared.clearLocalIdentityKey()
        VaulteDisplayName.clearAllCustomNames()
        setupComplete = false
        UserDefaults.standard.removeObject(forKey: "vaulteprive.relay.setupComplete")
        UserDefaults.standard.removeObject(forKey: VaulteProfileAvatar.storageKeyPrefix + userId.uuidString)
        UserDefaults.standard.removeObject(forKey: "vaulteprive.profile.displayName")
        usernameDraft = ""
        avatarImage = nil
        profileDisplayName = "Vaulté User"
        resetStatus = VaulteL.t("settings.account_wiped_msg")
        NotificationCenter.default.post(name: VaulteProfileAvatar.didChangeNotification, object: nil)
    }

}

/// iPhone full‑res photos (e.g. 24 MP HEIC) must not be uploaded raw — downsample before JPEG + base64.
/// Targets base64 length so older relays (600k cap) and noisy JPEGs still pass.
private enum VaulteProfileAvatarRelayEncoder {
    /// Fits legacy relay `avatar_too_large` checks (~600k) with margin; JSON is only a few extra bytes.
    private static let maxBase64Chars = 520_000
    private static let pixelCaps = [768, 640, 512, 400, 320, 256]
    private static let qualities: [CGFloat] = [0.84, 0.76, 0.68, 0.6, 0.52, 0.44, 0.36]

    /// Upper bound on base64 length without allocating the string (`ceil(n/3)*4`).
    private static func estimatedBase64Length(binaryByteCount: Int) -> Int {
        ((binaryByteCount + 2) / 3) * 4
    }

    /// Re-encode if `UserDefaults` still holds a huge pre-fixture image (falls back to original only if re-encode fails).
    static func normalizedStoredAvatar(_ data: Data) -> Data {
        if estimatedBase64Length(binaryByteCount: data.count) <= maxBase64Chars { return data }
        return jpegDataForRelay(from: data) ?? data
    }

    static func jpegDataForRelay(from imageData: Data) -> Data? {
        for maxPx in pixelCaps {
            for q in qualities {
                guard let data = imageJPEG(from: imageData, maxPixel: maxPx, quality: q) else { continue }
                if data.base64EncodedString().count <= maxBase64Chars { return data }
            }
        }
        for q in qualities.reversed() {
            if let data = imageJPEG(from: imageData, maxPixel: 200, quality: q),
               data.base64EncodedString().count <= maxBase64Chars {
                return data
            }
        }
        return nil
    }

    private static func imageJPEG(from imageData: Data, maxPixel: Int, quality: CGFloat) -> Data? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(imageData as CFData, srcOpts as CFDictionary),
              CGImageSourceGetCount(src) > 0
        else {
            return fallbackJPEG(from: imageData, maxPixel: maxPixel, quality: quality)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            let ui = UIImage(cgImage: cg, scale: 1, orientation: .up)
            return ui.jpegData(compressionQuality: quality)
        }
        return fallbackJPEG(from: imageData, maxPixel: maxPixel, quality: quality)
    }

    private static func fallbackJPEG(from imageData: Data, maxPixel: Int, quality: CGFloat) -> Data? {
        guard let img = UIImage(data: imageData) else { return nil }
        let w = img.size.width * img.scale
        let h = img.size.height * img.scale
        let maxSide = max(w, h)
        let ratio = min(1, CGFloat(maxPixel) / max(maxSide, 1))
        let newSize = CGSize(width: floor(img.size.width * ratio), height: floor(img.size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return scaled.jpegData(compressionQuality: quality)
    }
}

private struct ProfileDetailsView: View {
    let userId: UUID
    @Binding var displayName: String
    @Binding var usernameDraft: String
    @Binding var avatarImage: UIImage?

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var usernameStatus: String?
    /// When `usernameStatus` is `profile.status_relay_code_fmt`, relay `error` code for `VaulteL.tf1`.
    @State private var usernameRelayErrorCode: String?
    @State private var usernameBusy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                                )
                                .frame(width: 72, height: 72)
                            if let avatarImage {
                                Image(uiImage: avatarImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }

                        Spacer()

                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Label(VaulteL.t("profile.change_photo"), systemImage: "photo")
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background {
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                        .overlay(
                                            Capsule(style: .continuous)
                                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                        )
                                }
                        }
                    }

                    TextField(VaulteL.t("common.name"), text: $displayName)
                        .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background { profileFieldBackground }

                    TextField(VaulteL.t("profile.username_placeholder"), text: $usernameDraft)
                        .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background { profileFieldBackground }

                    Button(action: saveUsername) {
                        if usernameBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            Text(VaulteL.t("profile.save_info"))
                                .font(VaulteTypography.swiftUIFont(size: 13, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.plain)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .disabled(usernameBusy || normalizedUsernameDraft.count < 3)

                    if let usernameStatus {
                        let statusText: String = {
                            if usernameStatus == "profile.status_relay_code_fmt",
                               let code = usernameRelayErrorCode, !code.isEmpty {
                                return VaulteL.tf1(usernameStatus, code)
                            }
                            return VaulteL.t(usernameStatus)
                        }()
                        Text(statusText)
                            .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(16)
                .background { profilePlateBackground }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .navigationTitle(VaulteL.t("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        usernameRelayErrorCode = nil
                        usernameStatus = "profile.status_photo_load_failed"
                    }
                    return
                }
                guard let jpeg = VaulteProfileAvatarRelayEncoder.jpegDataForRelay(from: data) else {
                    await MainActor.run {
                        usernameRelayErrorCode = nil
                        usernameStatus = "profile.status_photo_prepare_failed"
                    }
                    return
                }
                await MainActor.run {
                    if let preview = UIImage(data: jpeg) {
                        avatarImage = preview
                    }
                    saveAvatar(jpeg)
                }
            }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
    }

    private var normalizedUsernameDraft: String {
        let t = usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("@") {
            return String(t.dropFirst())
        }
        return t
    }

    private var profileFieldBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
    }

    private var profilePlateBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.9)
            )
    }

    private func saveAvatar(_ jpegData: Data) {
        let key = VaulteProfileAvatar.storageKeyPrefix + userId.uuidString
        UserDefaults.standard.set(jpegData, forKey: key)
        NotificationCenter.default.post(name: VaulteProfileAvatar.didChangeNotification, object: nil)
        usernameRelayErrorCode = nil
        usernameStatus = "profile.status_saved"
        Task { await syncProfileToRelay() }
    }

    private func localAvatarBase64ForRelay() -> String? {
        let key = VaulteProfileAvatar.storageKeyPrefix + userId.uuidString
        guard let raw = UserDefaults.standard.data(forKey: key) else { return nil }
        let jpeg = VaulteProfileAvatarRelayEncoder.normalizedStoredAvatar(raw)
        return jpeg.base64EncodedString()
    }

    private func syncProfileToRelay() async {
        let normalized = normalizedUsernameDraft
        guard normalized.count >= 3 else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = name.isEmpty ? nil : name
        do {
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            let saved = try await client.syncEncryptedProfile(
                userId: userId,
                username: normalized,
                displayName: display,
                avatarBase64: localAvatarBase64ForRelay()
            )
            await MainActor.run {
                if !saved.username.isEmpty {
                    usernameDraft = formattedAtUsername(core: saved.username)
                }
                cacheRelayUser(saved)
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_saved"
            }
        } catch {
            await MainActor.run {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_update_failed"
            }
        }
    }

    private func saveUsername() {
        usernameStatus = nil
        usernameRelayErrorCode = nil
        let normalized = normalizedUsernameDraft
        guard normalized.count >= 3 else { return }
        usernameBusy = true
        Task {
            defer { usernameBusy = false }
            do {
                let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let saved = try await client.syncEncryptedProfile(
                    userId: userId,
                    username: normalized,
                    displayName: name.isEmpty ? nil : name,
                    avatarBase64: localAvatarBase64ForRelay()
                )
                await MainActor.run {
                    if !saved.username.isEmpty {
                        usernameDraft = formattedAtUsername(core: saved.username)
                    }
                    cacheRelayUser(saved)
                    usernameRelayErrorCode = nil
                    usernameStatus = "profile.status_saved"
                }
            } catch RelayAPIError.unauthorized {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_auth_failed"
            } catch RelayAPIError.usernameTaken {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_username_taken"
            } catch RelayAPIError.invalidUsername {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_username_rules"
            } catch RelayAPIError.forbidden {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_relay_denied"
            } catch RelayAPIError.relayError(let code) {
                usernameRelayErrorCode = code
                usernameStatus = "profile.status_relay_code_fmt"
            } catch {
                usernameRelayErrorCode = nil
                usernameStatus = "profile.status_update_failed"
            }
        }
    }

}

// MARK: - Safety Number Verification Sheet

struct SafetyNumberSheet: View {
    let userId: UUID
    let peerId: UUID?
    var conversationId: UUID? = nil
    var secureMode: SecureConversationMode = .e2e
    /// Group chats use pairwise ratchet/AES keys; encryption state is derived from members, not `conversationId` in the keychain.
    var isGroupConversation: Bool = false
    var groupMemberUUIDs: [UUID] = []
    var onOpenOneTimePad: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var safetyNumber: String?
    @State private var loading = true
    @Bindable private var subscription = VaulteSubscriptionManager.shared

    private func hasGroupPairwiseKeys() -> Bool {
        for m in groupMemberUUIDs where m != userId {
            let pairId = VaulteDirectConversationId.uuid(between: userId, and: m)
            if ConversationKeyStore.loadRatchetState(for: pairId) != nil { return true }
            if ConversationKeyStore.load(for: pairId) != nil { return true }
        }
        if let p = peerId, p != userId {
            let pairId = VaulteDirectConversationId.uuid(between: userId, and: p)
            if ConversationKeyStore.loadRatchetState(for: pairId) != nil { return true }
            if ConversationKeyStore.load(for: pairId) != nil { return true }
        }
        return false
    }

    private var heroIcon: String {
        "checkmark.shield.fill"
    }

    private var heroAccent: Color {
        .green
    }

    private var heroTitle: String {
        if isGroupConversation { return VaulteL.t("safety.verify_title") }
        return VaulteL.t("safety.e2e_title")
    }

    private var heroSubtitle: String {
        if isGroupConversation { return VaulteL.t("safety.verify_subtitle_group") }
        return VaulteL.t("safety.e2e_subtitle")
    }

    private var encryptionLabel: (icon: String, text: String, color: Color) {
        if isGroupConversation {
            if hasGroupPairwiseKeys() {
                return ("lock.fill", VaulteL.t("safety.encrypted_group"), .green)
            }
            return ("lock.open", VaulteL.t("safety.encrypted_group_none"), .orange)
        }
        guard let cid = conversationId else {
            return ("lock.open", VaulteL.t("safety.encrypted_none"), .orange)
        }
        if let p = peerId, p != userId {
            let pairId = VaulteDirectConversationId.uuid(between: userId, and: p)
            if ConversationKeyStore.loadRatchetState(for: pairId) != nil {
                return ("lock.fill", VaulteL.t("safety.encrypted_ratchet"), .green)
            }
            if ConversationKeyStore.load(for: pairId) != nil {
                return ("lock.fill", VaulteL.t("safety.encrypted_aes"), .green)
            }
        }
        if ConversationKeyStore.loadRatchetState(for: cid) != nil {
            return ("lock.fill", VaulteL.t("safety.encrypted_ratchet"), .green)
        }
        if ConversationKeyStore.load(for: cid) != nil {
            return ("lock.fill", VaulteL.t("safety.encrypted_aes"), .green)
        }
        return ("lock.open", VaulteL.t("safety.encrypted_none"), .orange)
    }

    private var cryptoCardAccent: Color {
        encryptionLabel.color
    }

    private var cryptoCardFill: Color {
        Color.white.opacity(0.05)
    }

    private var cryptoCardTitle: String {
        VaulteL.t("safety.current_protection_title")
    }

    private var cryptoCardSummary: String {
        VaulteL.tf1("safety.current_protection_fmt", encryptionLabel.text)
    }

    private var cryptoCardDetail: String? {
        nil
    }

    var body: some View {
        AbsoluteCinemaSheetRoot {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: heroIcon)
                            .font(.system(size: 44))
                            .foregroundStyle(heroAccent.opacity(0.92))
                        Text(heroTitle)
                            .font(VaulteTypography.swiftUIFont(size: 22, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                    .padding(.top, 24)

                    Text(heroSubtitle)
                        .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(cryptoCardTitle)
                            .font(VaulteTypography.swiftUIFont(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                        Text(cryptoCardSummary)
                            .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.74))
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = cryptoCardDetail {
                            Text(detail)
                                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(cryptoCardFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(cryptoCardAccent.opacity(0.34), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 22)

                    if loading {
                        ProgressView()
                            .tint(.white.opacity(0.5))
                            .padding()
                    } else if let code = safetyNumber {
                        safetyNumberGrid(code)
                        if isGroupConversation {
                            Text(VaulteL.t("safety.group_fingerprint_note"))
                                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                                .foregroundStyle(.white.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 22)
                        }
                    } else if isGroupConversation {
                        Text(VaulteL.t("safety.group_verify_hint"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.52))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 22)
                    } else {
                        Text(VaulteL.t("safety.no_peer_key"))
                            .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding()
                    }

                    HStack(spacing: 5) {
                        Image(systemName: encryptionLabel.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(encryptionLabel.color.opacity(0.7))
                        Text(encryptionLabel.text)
                            .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                            .foregroundStyle(encryptionLabel.color.opacity(0.6))
                    }

                    if !isGroupConversation, subscription.hasVerifiedOtpLimitedAccess, onOpenOneTimePad != nil {
                        Button {
                            dismiss()
                            onOpenOneTimePad?()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "shield.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Open One Time Pad")
                                    .font(VaulteTypography.swiftUIFont(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(Color.red.opacity(0.94))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.red.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.red.opacity(0.24), lineWidth: 1)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text(VaulteL.t("common.done"))
                            .font(VaulteTypography.swiftUIFont(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        #if !os(macOS)
        .presentationBackground(.clear)
        .presentationDetents([.large])
        #endif
        .task {
            await computeSafetyNumber()
        }
    }

    private func computeSafetyNumber() async {
        defer { loading = false }
        let targetPeer: UUID?
        if isGroupConversation {
            if let p = peerId, p != userId {
                targetPeer = p
            } else {
                // Deterministic pick so the same chat always shows the same fingerprint (sorted UUIDs).
                let others = groupMemberUUIDs.filter { $0 != userId }.sorted { $0.uuidString < $1.uuidString }
                targetPeer = others.first
            }
        } else {
            targetPeer = peerId
        }
        guard let pid = targetPeer else { return }
        do {
            // Must match keys used for X3DH / relay `identity_key` (LocalIdentityStore), not the separate QR Keychain slot.
            let localPubB64: String
            if let pair = LocalIdentityStore.loadIdentityKey() {
                localPubB64 = pair.publicKey.rawRepresentation.base64EncodedString()
            } else {
                localPubB64 = try await IdentityKeyExchange.shared.localPublicKeyBase64()
            }
            let client = try ChatAPIClient(baseURL: VaulteRelayConfiguration.baseURL)
            guard let peerKey = try await client.fetchIdentityKey(userId: pid),
                  !peerKey.publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                safetyNumber = nil
                return
            }
            safetyNumber = SafetyNumber.compute(
                localIdentityPubB64: localPubB64,
                remoteIdentityPubB64: peerKey.publicKeyBase64
            )
        } catch {
            safetyNumber = nil
        }
    }

    @ViewBuilder
    private func safetyNumberGrid(_ code: String) -> some View {
        let groups = code.split(separator: " ").map(String.init)
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { col in
                        let idx = row * 4 + col
                        if idx < groups.count {
                            Text(groups[idx])
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                )
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Badge Admin Sheet



