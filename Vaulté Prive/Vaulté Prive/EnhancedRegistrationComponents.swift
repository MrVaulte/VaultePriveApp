//
//  EnhancedRegistrationComponents.swift
//  Vaulté Privé
//

import SwiftUI

// MARK: - Enhanced Registration Flow

struct EnhancedRegistrationFlow: View {
    @Binding var mainPassphrase: String
    @Binding var panicPassphrase: String
    @Binding var username: String
    let onComplete: () -> Void
    
    @State private var currentStep: RegistrationStep = .mainPassphrase
    @State private var input1 = ""
    @State private var input2 = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    
    // Animation states
    @State private var iconScale: CGFloat = 0.8
    @State private var iconOffset: CGFloat = 0
    @State private var welcomeOpacity: Double = 0.0
    @State private var tapToContinueOpacity: Double = 0.0
    
    var body: some View {
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
            if currentStep == .welcomeAnimation {
                tapToContinueView
                    .padding(.bottom, 40)
            }
        }
        .background {
            StarfieldBackdrop()
                .ignoresSafeArea()
        }
        .onAppear {
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
            ForEach([RegistrationStep.mainPassphrase, .panicPassphrase, .usernameSelection], id: \.self) { step in
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
            
            stepContent
            
            actionButton
        }
        .padding(.horizontal, 32)
        .vaulteGlassPanelChrome()
    }
    
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .mainPassphrase:
            mainPassphraseContent
        case .panicPassphrase:
            panicPassphraseContent
        case .usernameSelection:
            usernameContent
        case .welcomeAnimation:
            EmptyView()
        }
    }
    
    private var mainPassphraseContent: some View {
        VStack(spacing: 16) {
            SecureField("Enter main passphrase", text: $input1)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm main passphrase", text: $input2)
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
    
    private var panicPassphraseContent: some View {
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
                
                Text("This phrase allows you to reset your account in emergency situations.")
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
            
            SecureField("Enter panic phrase", text: $input1)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm panic phrase", text: $input2)
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
    
    private var usernameContent: some View {
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
            
            Text("Your username will be used to identify you in Vaulté.")
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
            return !input1.isEmpty && input1 == input2 && input1.count >= 8
        case .panicPassphrase:
            return !input1.isEmpty && input1 == input2 && input1.count >= 8
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
            mainPassphrase = input1
            input1 = ""
            input2 = ""
            currentStep = .panicPassphrase
        case .panicPassphrase:
            if !canProceed {
                errorMessage = "Panic phrase must be at least 8 characters and match confirmation"
                return
            }
            panicPassphrase = input1
            input1 = ""
            input2 = ""
            currentStep = .usernameSelection
        case .usernameSelection:
            if !canProceed {
                errorMessage = "Username must be between 3-20 characters"
                return
            }
            currentStep = .welcomeAnimation
        case .welcomeAnimation:
            onComplete()
        }
    }
    
    private func startWelcomeAnimations() {
        welcomeOpacity = 0.0
        tapToContinueOpacity = 0.0
        iconScale = 0.8
        iconOffset = 0
    }
}

// MARK: - Enhanced Registration Step

struct EnhancedRegistrationStep: View {
    let step: RegistrationStep
    let onComplete: () -> Void
    
    @State private var input1 = ""
    @State private var input2 = ""
    @State private var username = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 16) {
                Text(step.title)
                    .font(VaulteTypography.swiftUIFont(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                if !step.description.isEmpty {
                    Text(step.description)
                        .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            
            stepContent
            
            actionButton
        }
        .padding(.horizontal, 32)
        .vaulteGlassPanelChrome()
    }
    
    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .mainPassphrase:
            mainPassphraseContent
        case .panicPassphrase:
            panicPassphraseContent
        case .usernameSelection:
            usernameContent
        case .welcomeAnimation:
            EmptyView()
        }
    }
    
    private var mainPassphraseContent: some View {
        VStack(spacing: 16) {
            SecureField("Enter main passphrase", text: $input1)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm main passphrase", text: $input2)
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
    
    private var panicPassphraseContent: some View {
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
                
                Text("This phrase allows you to reset your account in emergency situations.")
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
            
            SecureField("Enter panic phrase", text: $input1)
                .textFieldStyle(VaulteTextFieldStyle())
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            SecureField("Confirm panic phrase", text: $input2)
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
    
    private var usernameContent: some View {
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
            
            Text("Your username will be used to identify you in Vaulté.")
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
    
    private var actionButton: some View {
        Button(action: handleNextStep) {
            ZStack {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(step == .usernameSelection ? "Complete Setup" : "Continue")
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
        .padding(.top, 16)
    }
    
    private var canProceed: Bool {
        switch step {
        case .mainPassphrase:
            return !input1.isEmpty && input1 == input2 && input1.count >= 8
        case .panicPassphrase:
            return !input1.isEmpty && input1 == input2 && input1.count >= 8
        case .usernameSelection:
            return !username.isEmpty && username.count >= 3 && username.count <= 20
        case .welcomeAnimation:
            return true
        }
    }
    
    private func handleNextStep() {
        errorMessage = nil
        
        switch step {
        case .mainPassphrase, .panicPassphrase:
            if !canProceed {
                errorMessage = "Passphrase must be at least 8 characters and match confirmation"
                return
            }
            onComplete()
        case .usernameSelection:
            if !canProceed {
                errorMessage = "Username must be between 3-20 characters"
                return
            }
            onComplete()
        case .welcomeAnimation:
            onComplete()
        }
    }
}

// MARK: - Custom TextField Style

struct VaulteTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(VaulteTypography.swiftUIFont(size: 16, weight: .regular))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                VaulteGlassChrome.fieldBackground()
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
    }
}

// MARK: - Glass Panel Extension

extension View {
    func vaulteGlassPanelChrome() -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
    }
}

// MARK: - Glass Chrome

struct VaulteGlassChrome {
    static func fieldBackground() -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
    }
}


#Preview {
    EnhancedRegistrationFlow(
        mainPassphrase: .constant(""),
        panicPassphrase: .constant(""),
        username: .constant(""),
        onComplete: {}
    )
    .preferredColorScheme(.dark)
}
