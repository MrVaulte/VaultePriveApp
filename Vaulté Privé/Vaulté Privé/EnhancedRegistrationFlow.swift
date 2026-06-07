//
//  EnhancedRegistrationFlow.swift
//  Vaulté Privé
//
//  Created by Mr Vaulte on 4/18/26.
//


//
//  EnhancedRegistrationViews.swift
//  Vaulté Privé
//

import SwiftUI
import LocalAuthentication

// MARK: - Enhanced Registration Flow

struct EnhancedRegistrationFlow: View {
    @State private var currentStep: RegistrationStep = .mainPassphrase
    @State private var mainPassphrase = ""
    @State private var confirmMainPassphrase = ""
    @State private var panicPassphrase = ""
    @State private var confirmPanicPassphrase = ""
    @State private var username = ""
    @State private var showWelcomeAnimation = false
    @State private var showIconAnimation = false
    @State private var showTapToContinue = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    
    // Animation states
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOffset: CGFloat = 0
    @State private var welcomeOpacity: Double = 0.0
    @State private var tapToContinueOpacity: Double = 0.0
    
    var onComplete: () -> Void
    
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
    
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // Step indicator
                stepIndicator
                
                Spacer()
                
                // Main content
                if currentStep == .welcomeAnimation {
                    welcomeAnimationView
                } else {
                    registrationStepView
                }
                
                Spacer()
                
                // Tap to continue for welcome screen
                if currentStep == .welcomeAnimation && showTapToContinue {
                    tapToContinueView
                        .padding(.bottom, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                StarfieldBackdrop()
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            // Start animations when welcome animation step begins
            if currentStep == .welcomeAnimation {
                startWelcomeAnimations()
            }
        }
        .onChange(of: currentStep) { _, newStep in
            if newStep == .welcomeAnimation {
                startWelcomeAnimations()
            }
        }
    }
    
    private var stepIndicator: some View {
        HStack(spacing: 20) {
            ForEach(RegistrationStep.allCases.filter { $0 != .welcomeAnimation }, id: \.self) { step in
                stepCircle(step)
            }
        }
        .padding(.top, 40)
    }
    
    private func stepCircle(_ step: RegistrationStep) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(isStepCompleted(step) ? Color.green.opacity(0.3) : Color.white.opacity(0.1))
                .overlay(
                    Circle()
                        .stroke(isStepCompleted(step) ? Color.green.opacity(0.8) : Color.white.opacity(0.3), lineWidth: 2)
                )
                .overlay(
                    Group {
                        if isStepCompleted(step) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.green)
                        } else {
                            Text("\(step.stepNumber)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                )
                .frame(width: 32, height: 32)
            
            if step.stepNumber < 3 {
                Rectangle()
                    .fill(isStepCompleted(step) ? Color.green.opacity(0.5) : Color.white.opacity(0.2))
                    .frame(height: 2)
                    .frame(maxWidth: .infinity)
            }
        }
    }
    
    private var registrationStepView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text(currentStep.title)
                    .font(VaulteTypography.swiftUIFont(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                if !currentStep.description.isEmpty {
                    Text(currentStep.description)
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            
            switch currentStep {
            case .mainPassphrase:
                mainPassphraseView
            case .panicPassphrase:
                panicPassphraseView
            case .usernameSelection:
                usernameSelectionView
            case .welcomeAnimation:
                EmptyView()
            }
            
            if currentStep != .welcomeAnimation {
                actionButton
            }
        }
        .padding(.horizontal, 32)
        .vaulteGlassPanelChrome()
    }
    
    private var mainPassphraseView: some View {
        VStack(spacing: 16) {
            SecureField("Enter main passphrase", text: $mainPassphrase)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm main passphrase", text: $confirmMainPassphrase)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            if let error = errorMessage {
                Text(error)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    private var panicPassphraseView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text("Emergency Reset")
                        .font(VaulteTypography.swiftUIFont(size: 11, weight: .bold))
                        .tracking(1)
                }
                .foregroundColor(.red.opacity(0.95))
                
                Text("This phrase allows you to reset your account in emergency situations. Make it memorable but different from your main passphrase.")
                    .font(VaulteTypography.swiftUIFont(size: 11, weight: .regular))
                    .foregroundColor(.red.opacity(0.55))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        VaulteGlassChrome.fieldBackground()
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    )
            }
            
            SecureField("Enter panic phrase", text: $panicPassphrase)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm panic phrase", text: $confirmPanicPassphrase)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            if let error = errorMessage {
                Text(error)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    private var usernameSelectionView: some View {
        VStack(spacing: 16) {
            TextField("Choose username", text: $username)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .padding(.leading, 20)
                .overlay(
                    HStack {
                        Text("@")
                            .foregroundColor(.white.opacity(0.5))
                            .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                        Spacer()
                    }
                    .padding(.leading, 16)
                )
            
            Text("Your username will be used to identify you in Vaulté. You can include it in your panic phrase for easy recovery.")
                .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            
            if let error = errorMessage {
                Text(error)
                    .font(VaulteTypography.swiftUIFont(size: 14, weight: .regular))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    private var welcomeAnimationView: some View {
        VStack(spacing: 40) {
            Spacer()
            
            // Absolute Cinema Icon with animation
            VStack(spacing: 24) {
                Image("Absolute Cinema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .scaleEffect(iconScale)
                    .offset(y: iconOffset)
                    .foregroundColor(.white)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.5)) {
                            iconScale = 1.0
                        }
                        withAnimation(.easeInOut(duration: 2.0).delay(0.8)) {
                            iconOffset = -20
                        }
                    }
                
                // Welcome text
                VStack(spacing: 16) {
                    Text("Welcome To Vaulté Privé")
                        .font(VaulteTypography.swiftUIFont(size: 32, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(welcomeOpacity)
                        .multilineTextAlignment(.center)
                        .onAppear {
                            withAnimation(.easeIn(duration: 1.5).delay(1.5)) {
                                welcomeOpacity = 1.0
                            }
                        }
                    
                    if !username.isEmpty {
                        Text("Your panic phrase includes @\(username)")
                            .font(VaulteTypography.swiftUIFont(size: 18, weight: .regular))
                            .foregroundColor(.white.opacity(0.7))
                            .opacity(welcomeOpacity)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            
            Spacer()
        }
    }
    
    private var tapToContinueView: some View {
        Text("Tap to continue")
            .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
            .foregroundColor(.white.opacity(0.6))
            .opacity(tapToContinueOpacity)
            .onAppear {
                withAnimation(.easeIn(duration: 1.0).delay(3.0)) {
                    tapToContinueOpacity = 1.0
                }
            }
            .onTapGesture {
                onComplete()
            }
    }
    
    private var actionButton: some View {
        Button(action: handleNextStep) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(currentStep == .usernameSelection ? "Complete Setup" : "Continue")
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .tracking(1.2)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
        }
        .disabled(isBusy || !canProceed)
        .opacity(canProceed ? 1.0 : 0.6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 2)
                .blur(radius: 5)
                .padding(-3)
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 5)
                .blur(radius: 14)
                .padding(-9)
        )
        .padding(.top, 16)
    }
    
    private func isStepCompleted(_ step: RegistrationStep) -> Bool {
        switch step {
        case .mainPassphrase:
            return currentStep == .panicPassphrase || currentStep == .usernameSelection || currentStep == .welcomeAnimation
        case .panicPassphrase:
            return currentStep == .usernameSelection || currentStep == .welcomeAnimation
        case .usernameSelection:
            return currentStep == .welcomeAnimation
        case .welcomeAnimation:
            return false
        }
    }
    
    private var canProceed: Bool {
        switch currentStep {
        case .mainPassphrase:
            return !mainPassphrase.isEmpty && mainPassphrase == confirmMainPassphrase && mainPassphrase.count >= 8
        case .panicPassphrase:
            return !panicPassphrase.isEmpty && panicPassphrase == confirmPanicPassphrase && panicPassphrase != mainPassphrase
        case .usernameSelection:
            return !username.isEmpty && username.count >= 3 && username.count <= 20
        case .welcomeAnimation:
            return true
        }
    }
    
    private func handleNextStep() {
        errorMessage = nil
        
        switch currentStep {
        case .mainPassphrase:
            if !canProceed {
                errorMessage = "Passphrase must be at least 8 characters and match confirmation"
                return
            }
            currentStep = .panicPassphrase
            
        case .panicPassphrase:
            if !canProceed {
                errorMessage = "Panic phrase must be different from main passphrase and match confirmation"
                return
            }
            currentStep = .usernameSelection
            
        case .usernameSelection:
            if !canProceed {
                errorMessage = "Username must be between 3-20 characters"
                return
            }
            // Save all data and proceed to welcome
            saveRegistrationData()
            currentStep = .welcomeAnimation
            
        case .welcomeAnimation:
            onComplete()
        }
    }
    
    private func saveRegistrationData() {
        // This would integrate with the existing PassphraseEnclaveStore
        // and other storage mechanisms
        print("Saving registration data...")
        print("Main passphrase: \(mainPassphrase)")
        print("Panic phrase: \(panicPassphrase)")
        print("Username: \(username)")
    }
    
    private func startWelcomeAnimations() {
        showWelcomeAnimation = true
        showIconAnimation = true
    }
}

// MARK: - Custom TextField Style

struct VaulteTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(VaulteTypography.swiftUIFont(size: 15, weight: .regular))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                VaulteGlassChrome.fieldBackground()
            }
    }
}

// MARK: - Glass Panel Extension

extension View {
    func vaulteGlassPanelChrome() -> some View {
        self
            .padding(20)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
            }
    }
}

// MARK: - Glass Chrome

struct VaulteGlassChrome {
    /// Frosted, well-visible input field background for dark contexts.
    static func fieldBackground() -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(VaultePalette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(VaultePalette.border, lineWidth: 1)
            )
    }
}


#Preview {
    EnhancedRegistrationFlow(onComplete: {})
        .preferredColorScheme(.dark)
}
