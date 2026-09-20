import SwiftUI

/// Title, the on-device promise, and Settings.
struct AssistantTopBar: View {
    let onOpenSettings: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s + 2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s + 2) {
                    title
                    PrivacyPill()
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    title
                    PrivacyPill()
                }
            }
            Spacer(minLength: Spacing.s)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glassCircle(diameter: 42))
            .accessibilityLabel("Settings")
            .accessibilityShowsLargeContentViewer()
        }
        .padding(.horizontal, Spacing.screenMargin)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.s + 2)
    }

    private var title: some View {
        Text("Voice Agent")
            .textStyle(.title3, weight: .bold)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }
}

/// "On-device": everything runs on this iPhone.
struct PrivacyPill: View {
    var body: some View {
        StatusPill("On-device", systemImage: "lock.fill", tone: .clay)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("On-device. Everything runs on this iPhone.")
    }
}

/// How the person talks to the assistant: voice (default) or keyboard.
enum AssistantInputMode: Sendable {
    case voice
    case keyboard
}

/// Mic button in the middle; keyboard and history on either side. In keyboard mode the bar
/// becomes a text field with a send button.
struct AssistantBottomBar: View {
    let isSessionActive: Bool
    let canStartSession: Bool
    /// State colour for the mic halo.
    var tint: Color = Palette.clay
    @Binding var mode: AssistantInputMode
    @Binding var draft: String
    var isFieldFocused: FocusState<Bool>.Binding
    let onToggleSession: @MainActor () -> Void
    let onSubmit: @MainActor (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch mode {
            case .voice: voiceBar
            case .keyboard: keyboardBar
            }
        }
        .padding(.horizontal, Spacing.screenMargin)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .animation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion), value: mode)
        .onChange(of: mode) { _, newMode in
            // Focus once the field exists (it is created by this same mode change).
            guard newMode == .keyboard else { return }
            Task { @MainActor in isFieldFocused.wrappedValue = true }
        }
    }

    private var voiceBar: some View {
        HStack(alignment: .center) {
            Button {
                mode = .keyboard
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.glassCircle(diameter: 50))
            .accessibilityLabel("Type a request")
            .accessibilityIdentifier("typeRequest")
            .accessibilityShowsLargeContentViewer()

            Spacer(minLength: Spacing.l)
            MicButton(isActive: isSessionActive, tint: tint, action: onToggleSession)
                .disabled(!canStartSession && !isSessionActive)
            Spacer(minLength: Spacing.l)

            // Balances the keyboard button so the microphone sits in the middle of the screen
            // rather than in the middle of what is left of it.
            Color.clear
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.s)
        .transition(.opacity)
    }

    private var keyboardBar: some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: Spacing.s + 2) {
            HStack(spacing: Spacing.s) {
                TextField("Type a request", text: $draft)
                    .textStyle(.body)
                    .foregroundStyle(Palette.ink)
                    .focused(isFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel("Request")
                    .accessibilityIdentifier("requestField")
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? Palette.inkInverse : Palette.inkTertiary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? Palette.ink : Palette.fill))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendRequest")
            }
            .padding(.leading, 18)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .frame(minHeight: 50)
            .glassSurface(Capsule(style: .continuous))

            Button {
                isFieldFocused.wrappedValue = false
                mode = .voice
            } label: {
                Image(systemName: "mic.fill")
            }
            .buttonStyle(.glassCircle(diameter: 50))
            .accessibilityLabel("Talk instead")
            .accessibilityShowsLargeContentViewer()
        }
        .transition(.opacity)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit(text)
        draft = ""
    }
}

/// The large ink button that starts and ends a conversation.
struct MicButton: View {
    let isActive: Bool
    /// The halo shown while a conversation is active takes the assistant's state colour.
    var tint: Color = Palette.clay
    let action: @MainActor () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(isActive ? 0.55 : 0), lineWidth: 3)
                    .padding(-8)
                Circle()
                    .fill(isEnabled ? Palette.ink : Palette.fill)
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: isActive ? 22 : 27, weight: .semibold))
                    .foregroundStyle(isEnabled ? Palette.inkInverse : Palette.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 74, height: 74)
            .contentShape(Circle())
        }
        .buttonStyle(MicPressStyle())
        .animation(Motion.adaptive(Motion.snappy, reduceMotion: reduceMotion), value: isActive)
        .haptic(.impact(weight: .medium), trigger: taps)
        .accessibilityLabel(isActive ? "Stop" : "Talk")
        .accessibilityHint(isActive ? "Ends the conversation." : "Starts listening.")
        .accessibilityShowsLargeContentViewer()
    }
}

private struct MicPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MicPressBody(configuration: configuration)
    }
}

private struct MicPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
