import Agent
import Core
import SwiftUI

/// Everything the person can ask of the assistant screen. The screen never decides anything
/// itself; it only reports intents.
struct AssistantIntents {
    /// Mic button: start a session when inactive, end it when active.
    var toggleSession: @MainActor () -> Void
    /// Confirm on the action card, bound to the card's `id` and `version`.
    var confirm: @MainActor (_ id: UUID, _ version: Int) -> Void
    /// Cancel on the action card.
    var cancel: @MainActor (_ id: UUID) -> Void
    /// A clarification chip was tapped (`ClarificationChoice.id`).
    var chooseClarification: @MainActor (_ id: String) -> Void
    /// Typed input (already trimmed, never empty).
    var submitText: @MainActor (_ text: String) -> Void
    /// The gear button, and "Choose folder" on a shared-folder permission card.
    var openSettings: @MainActor () -> Void
    /// "Open Settings" on a permission card whose `requiresSettings` is true.
    var openSystemSettings: @MainActor (_ kind: PermissionKind) -> Void
    /// "Not now" on a permission card.
    var dismissPermission: @MainActor () -> Void
    /// The history sheet opened (the screen presents it from `presentation.turns`).
    var showHistory: @MainActor () -> Void

    init(
        toggleSession: @escaping @MainActor () -> Void,
        confirm: @escaping @MainActor (_ id: UUID, _ version: Int) -> Void,
        cancel: @escaping @MainActor (_ id: UUID) -> Void,
        chooseClarification: @escaping @MainActor (_ id: String) -> Void,
        submitText: @escaping @MainActor (_ text: String) -> Void,
        openSettings: @escaping @MainActor () -> Void,
        openSystemSettings: @escaping @MainActor (_ kind: PermissionKind) -> Void,
        dismissPermission: @escaping @MainActor () -> Void,
        showHistory: @escaping @MainActor () -> Void = {}
    ) {
        self.toggleSession = toggleSession
        self.confirm = confirm
        self.cancel = cancel
        self.chooseClarification = chooseClarification
        self.submitText = submitText
        self.openSettings = openSettings
        self.openSystemSettings = openSystemSettings
        self.dismissPermission = dismissPermission
        self.showHistory = showHistory
    }

    /// Does nothing (previews and the design gallery).
    static var inert: AssistantIntents {
        AssistantIntents(
            toggleSession: {}, confirm: { _, _ in }, cancel: { _ in }, chooseClarification: { _ in },
            submitText: { _ in }, openSettings: {}, openSystemSettings: { _ in }, dismissPermission: {}
        )
    }
}

/// The primary screen: the orb and its state, what was heard, what the assistant says, and
/// the cards that need the person (action, clarification, permission).
struct AssistantScreen: View {
    let presentation: AssistantPresentation
    let intents: AssistantIntents

    @State private var inputMode: AssistantInputMode
    @State private var draft = ""
    @State private var isHistoryPresented: Bool
    @State private var visibleBanner: ResultBanner?
    @FocusState private var isFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - inputMode: Starting input mode (UI state; the gallery uses `.keyboard`).
    ///   - showsHistory: Starts with the history sheet open (gallery).
    init(
        presentation: AssistantPresentation,
        intents: AssistantIntents,
        inputMode: AssistantInputMode = .voice,
        showsHistory: Bool = false
    ) {
        self.presentation = presentation
        self.intents = intents
        _inputMode = State(initialValue: inputMode)
        _isHistoryPresented = State(initialValue: showsHistory)
    }

    private var state: AgentState { presentation.state }

    /// A card needs the person: the orb steps back to make room.
    private var needsAttention: Bool {
        presentation.actionCard != nil || !presentation.clarificationChoices.isEmpty || presentation.permissionPrompt != nil
    }

    private var layoutAnimation: Animation { Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion) }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        stage(width: proxy.size.width)

                        ConversationTextView(
                            state: state,
                            partialTranscript: presentation.partialTranscript,
                            lastUserUtterance: presentation.lastUserUtterance,
                            assistantText: presentation.assistantText,
                            isCompact: needsAttention
                        )
                        .padding(.horizontal, Spacing.xxl + 4)
                        .padding(.top, needsAttention ? Spacing.m : Spacing.xxl)

                        cards
                            .frame(maxWidth: Measure.content)
                            .padding(.horizontal, Spacing.screenMargin)
                            .padding(.top, Spacing.xxl)
                            .id(CardsAnchor.id)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: needsAttention ? .top : .center)
                    .padding(.bottom, Spacing.l)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: presentation.actionCard?.id) { _, newValue in
                    guard newValue != nil else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        withAnimation(layoutAnimation) { scroller.scrollTo(CardsAnchor.id, anchor: .bottom) }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let banner = visibleBanner {
                    ResultBannerView(banner: banner)
                        .padding(.horizontal, Spacing.screenMargin)
                        .padding(.top, Spacing.xs)
                        .transition(.drop(reduceMotion: reduceMotion))
                        .onTapGesture { withAnimation(layoutAnimation) { visibleBanner = nil } }
                }
            }
        }
        .edgeBar(.top) {
            AssistantTopBar(onOpenSettings: intents.openSettings)
        }
        .edgeBar(.bottom) {
            AssistantBottomBar(
                isSessionActive: presentation.isSessionActive,
                canStartSession: !state.isPreparing,
                mode: $inputMode,
                draft: $draft,
                isFieldFocused: $isFieldFocused,
                onToggleSession: intents.toggleSession,
                onSubmit: { text in
                    isFieldFocused = false
                    intents.submitText(text)
                },
                onShowHistory: {
                    isHistoryPresented = true
                    intents.showHistory()
                }
            )
        }
        .background {
            AmbientBackdrop(tone: state.orbMode.tone, focusY: needsAttention ? 0.16 : 0.36)
                .ignoresSafeArea()
        }
        .animation(layoutAnimation, value: needsAttention)
        .animation(layoutAnimation, value: presentation.actionCard)
        .animation(layoutAnimation, value: presentation.clarificationChoices)
        .animation(layoutAnimation, value: presentation.permissionPrompt)
        .animation(layoutAnimation, value: presentation.partialTranscript == nil)
        .animation(layoutAnimation, value: presentation.assistantText)
        .sheet(isPresented: $isHistoryPresented) {
            HistorySheet(turns: presentation.turns)
        }
        .task(id: presentation.resultBanner) { await showBanner(presentation.resultBanner) }
        .onChange(of: state) { _, newState in
            if newState.announcesToVoiceOver {
                AccessibilityNotification.Announcement(newState.displayLabel).post()
            }
        }
        .haptic(trigger: presentation.actionCard?.id) { old, new in
            new != nil && new != old ? .impact(flexibility: .soft, intensity: 0.8) : nil
        }
        .haptic(trigger: presentation.resultBanner) { _, new in
            switch new?.style {
            case .success: .success
            case .failure: .error
            case .cancelled: .impact(weight: .light)
            case nil: nil
            }
        }
    }

    // MARK: Stage

    private func stage(width: CGFloat) -> some View {
        let heroSize = min(248, max(160, width * 0.6))
        let size = needsAttention ? 104 : heroSize
        return VStack(spacing: needsAttention ? Spacing.s : Spacing.l) {
            OrbView(mode: state.orbMode, inputLevel: presentation.inputLevel, outputLevel: presentation.outputLevel)
                .frame(width: size, height: size)
            Text(state.displayLabel)
                .textStyle(needsAttention ? .headline : .title3, weight: .semibold)
                .foregroundStyle(state == .error ? Palette.danger : Palette.ink)
                .contentTransition(.opacity)
                .animation(Motion.adaptive(.easeInOut(duration: 0.25), reduceMotion: reduceMotion), value: state.displayLabel)
                .accessibilityLabel("Status: \(state.displayLabel)")
        }
        .padding(.top, needsAttention ? Spacing.xs : 0)
    }

    // MARK: Cards

    @ViewBuilder
    private var cards: some View {
        VStack(spacing: Spacing.l) {
            if let card = presentation.actionCard {
                ActionCardView(
                    card: card,
                    onConfirm: { intents.confirm(card.id, card.version) },
                    onCancel: { intents.cancel(card.id) }
                )
                .id("\(card.id)-\(card.version)")
                .transition(.rise(reduceMotion: reduceMotion))
            }
            if !presentation.clarificationChoices.isEmpty {
                ClarificationChoicesView(choices: presentation.clarificationChoices, onChoose: intents.chooseClarification)
                    .transition(.rise(reduceMotion: reduceMotion))
            }
            if let prompt = presentation.permissionPrompt {
                PermissionCardView(
                    prompt: prompt,
                    onOpenSystemSettings: { intents.openSystemSettings(prompt.kind) },
                    onChooseFolder: intents.openSettings,
                    onDismiss: intents.dismissPermission
                )
                .transition(.rise(reduceMotion: reduceMotion))
            }
        }
    }

    private enum CardsAnchor { static let id = "assistant.cards" }

    private func showBanner(_ banner: ResultBanner?) async {
        withAnimation(layoutAnimation) { visibleBanner = banner }
        guard banner != nil else { return }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        withAnimation(layoutAnimation) { visibleBanner = nil }
    }
}

/// A faint wash of the state colour behind the orb, so the whole screen reads the state.
struct AmbientBackdrop: View {
    let tone: Tone
    var focusY: CGFloat = 0.36

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Palette.canvas
            RadialGradient(
                colors: [tone.color.opacity(colorScheme == .dark ? 0.2 : 0.1), tone.color.opacity(0)],
                center: UnitPoint(x: 0.5, y: focusY),
                startRadius: 0,
                endRadius: 360
            )
        }
        .animation(Motion.gentle, value: tone)
        .animation(Motion.smooth, value: focusY)
        .accessibilityHidden(true)
    }
}

#Preview("Assistant — confirmation") {
    AssistantScreen(presentation: GallerySamples.presentation(for: .waitingForConfirmation), intents: .inert)
}

#Preview("Assistant — listening") {
    AssistantScreen(presentation: GallerySamples.presentation(for: .listening), intents: .inert)
}
