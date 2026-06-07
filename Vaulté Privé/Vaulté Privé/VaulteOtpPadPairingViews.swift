import SwiftUI

struct VaulteOtpPadPairingSheet: View {
    let onDismiss: () -> Void

    @State private var center = VaulteOtpPadPairingCenter.shared
    @FocusState private var receiverFocused: Bool
    @State private var receiverEntry = ""

    var body: some View {
        Group {
            if let session = center.activeSession {
                sheetContent(session: session)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func sheetContent(session: VaulteOtpPadPairingSession) -> some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            Text(session.role == .sender ? "Pairing code" : "Confirm import")
                .font(VaulteTypography.swiftUIFont(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Text(subtitle(for: session))
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            pairingInput(for: session)
            statusView(for: session)

            Button(session.isComplete ? "Close" : "Cancel") {
                if session.isComplete {
                    onDismiss()
                } else {
                    Task {
                        await center.cancelActiveSession()
                        onDismiss()
                    }
                }
            }
            .buttonStyle(.plain)
            .font(VaulteTypography.swiftUIFont(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .onAppear {
            if session.role == .receiver, session.isLinked {
                receiverEntry = session.receiverDigits.joined()
                receiverFocused = true
            }
        }
        .onChange(of: receiverEntry) { _, newValue in
            guard center.activeSession?.role == .receiver,
                  center.activeSession?.isLinked == true,
                  center.activeSession?.isImporting != true
            else { return }
            handleReceiverEntry(newValue)
        }
        .onChange(of: center.activeSession?.isLinked) { _, linked in
            if center.activeSession?.role == .receiver, linked == true {
                receiverFocused = true
            }
        }
        .onChange(of: center.activeSession?.receiverDigits) { _, _ in
            guard center.activeSession?.role == .receiver else { return }
            let joined = center.activeSession?.receiverDigits.joined() ?? ""
            if receiverEntry != joined {
                receiverEntry = joined
            }
        }
        .onChange(of: center.activeSession?.isComplete) { _, isComplete in
            guard isComplete == true else { return }
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                onDismiss()
            }
        }
    }

    private func subtitle(for session: VaulteOtpPadPairingSession) -> String {
        switch session.role {
        case .sender:
            return "Read this code to your contact."
        case .receiver:
            return session.isLinked
                ? "Enter the code from the sender's screen."
                : "Connecting to sender…"
        }
    }

    @ViewBuilder
    private func pairingInput(for session: VaulteOtpPadPairingSession) -> some View {
        if session.role == .sender, let code = session.code {
            VaulteOtpPadSixSlotRow(
                digits: code.map { String($0) },
                slotStates: Array(repeating: .idle, count: 6),
                compact: true
            )
            Text("Live")
                .font(VaulteTypography.swiftUIFont(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .tracking(1)
            VaulteOtpPadSixSlotRow(
                digits: session.receiverDigits,
                slotStates: session.senderSlots,
                placeholder: "·",
                compact: true
            )
        } else if !session.isLinked {
            ProgressView()
                .tint(.white.opacity(0.7))
                .scaleEffect(0.85)
                .padding(.vertical, 4)
            Text("Waiting for code…")
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
        } else {
            ZStack {
                TextField("", text: $receiverEntry)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($receiverFocused)
                    .opacity(0.02)
                    .frame(width: 1, height: 1)

                VaulteOtpPadSixSlotRow(
                    digits: session.receiverDigits,
                    slotStates: session.receiverSlots,
                    placeholder: "·",
                    compact: true
                )
                .onTapGesture { receiverFocused = true }
            }
        }
    }

    @ViewBuilder
    private func statusView(for session: VaulteOtpPadPairingSession) -> some View {
        if session.isImporting {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
                Text("Importing pads…")
                    .font(VaulteTypography.swiftUIFont(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        } else if session.isComplete {
            Label(
                session.role == .sender ? "Done" : "Imported",
                systemImage: "checkmark.circle.fill"
            )
            .font(VaulteTypography.swiftUIFont(size: 13, weight: .semibold))
            .foregroundStyle(Color.green.opacity(0.92))
        } else if let error = session.errorMessage {
            Text(error)
                .font(VaulteTypography.swiftUIFont(size: 12, weight: .regular))
                .foregroundStyle(Color.red.opacity(0.92))
                .multilineTextAlignment(.center)
        }
    }

    private func handleReceiverEntry(_ raw: String) {
        let filtered = String(raw.filter(\.isNumber).prefix(6))
        if filtered != raw {
            receiverEntry = filtered
            return
        }

        let previous = center.activeSession?.receiverDigits.joined() ?? ""

        if filtered.count < previous.count {
            center.receiverClearFrom(index: filtered.count)
            return
        }

        if filtered.count > previous.count {
            let index = filtered.count - 1
            let char = filtered[filtered.index(filtered.startIndex, offsetBy: index)]
            Task {
                await center.receiverSubmitDigit(at: index, digit: char)
            }
        }
    }
}

private struct VaulteOtpPadSixSlotRow: View {
    let digits: [String]
    let slotStates: [VaulteOtpPadPairingSlotState]
    var placeholder: String = ""
    var compact: Bool = false

    private var slotHeight: CGFloat { compact ? 44 : 58 }
    private var cornerRadius: CGFloat { compact ? 12 : 16 }
    private var fontSize: CGFloat { compact ? 20 : 24 }

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            ForEach(0..<6, id: \.self) { index in
                let digit = index < digits.count ? digits[index] : ""
                let state = index < slotStates.count ? slotStates[index] : .idle
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(fill(for: state))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(stroke(for: state), lineWidth: state == .idle ? 0.8 : 1.4)
                        )
                        .frame(height: slotHeight)

                    Text(digit.isEmpty ? placeholder : digit)
                        .font(VaulteTypography.swiftUIFont(size: fontSize, weight: .bold))
                        .foregroundStyle(.white.opacity(digit.isEmpty ? 0.24 : 0.94))
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.08), value: state)
            }
        }
    }

    private func stroke(for state: VaulteOtpPadPairingSlotState) -> Color {
        switch state {
        case .idle: return Color.white.opacity(0.12)
        case .checking: return Color.white.opacity(0.45)
        case .correct: return Color.green.opacity(0.9)
        case .wrong: return Color.red.opacity(0.9)
        }
    }

    private func fill(for state: VaulteOtpPadPairingSlotState) -> Color {
        switch state {
        case .idle: return Color.white.opacity(0.04)
        case .checking: return Color.white.opacity(0.07)
        case .correct: return Color.green.opacity(0.12)
        case .wrong: return Color.red.opacity(0.14)
        }
    }
}
