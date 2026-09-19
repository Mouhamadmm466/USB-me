import SwiftUI

/// The pages of the first run, in order.
enum OnboardingPage: Int, CaseIterable, Sendable, Comparable {
    /// Private by design: what runs where, what it can and never does.
    case privacy
    /// Download the voice models.
    case models
    /// Ready: the microphone is requested on the first tap.
    case ready

    static func < (lhs: OnboardingPage, rhs: OnboardingPage) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct OnboardingActions {
    var models: ModelDownloadActions
    /// "Start" on the last page. Mark onboarding complete and show the assistant.
    var finish: @MainActor () -> Void

    init(models: ModelDownloadActions, finish: @escaping @MainActor () -> Void) {
        self.models = models
        self.finish = finish
    }

    static var inert: OnboardingActions { OnboardingActions(models: .inert, finish: {}) }
}

/// First run: explains the local, private architecture, downloads the models, and hands over
/// to the assistant. The microphone is not requested here; the last page says it will be
/// asked for on the first tap.
struct OnboardingFlow: View {
    let models: ModelDownloadViewState
    let actions: OnboardingActions

    @State private var page: OnboardingPage
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(models: ModelDownloadViewState, actions: OnboardingActions, initialPage: OnboardingPage = .privacy) {
        self.models = models
        self.actions = actions
        _page = State(initialValue: initialPage)
        DesignSystemAppearance.install()
    }

    var body: some View {
        ZStack {
            switch page {
            case .privacy:
                PrivacyPage(onContinue: { go(to: .models) })
                    .transition(pageTransition)
            case .models:
                ModelsPage(state: models, actions: actions.models, onContinue: { go(to: .ready) })
                    .transition(pageTransition)
            case .ready:
                ReadyPage(onStart: actions.finish)
                    .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgeBar(.top) { header }
        .background(Palette.canvas.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button {
                if let previous = OnboardingPage(rawValue: page.rawValue - 1) { go(to: previous) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glassCircle(diameter: 40))
            .opacity(page == .privacy ? 0 : 1)
            .disabled(page == .privacy)
            .accessibilityLabel("Back")
            .accessibilityHidden(page == .privacy)

            Spacer()
            PageIndicator(count: OnboardingPage.allCases.count, current: page.rawValue)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, Spacing.screenMargin)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.s)
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertion: Edge = movingForward ? .trailing : .leading
        let removal: Edge = movingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertion).combined(with: .opacity),
            removal: .move(edge: removal).combined(with: .opacity)
        )
    }

    private func go(to next: OnboardingPage) {
        movingForward = next > page
        withAnimation(Motion.adaptive(Motion.smooth, reduceMotion: reduceMotion)) { page = next }
    }
}

/// Three short capsules; the current one is long and ink.
private struct PageIndicator: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == current ? Palette.ink : Palette.fill)
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(Motion.smooth, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The shared page scaffold: scrolling content above a pinned action area.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: Measure.content)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.xxl)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .edgeBar(.bottom) {
            VStack(spacing: Spacing.s) { actions }
                .frame(maxWidth: Measure.content)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.m)
                .padding(.bottom, Spacing.s)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Large onboarding headline with an optional supporting paragraph.
struct OnboardingHeadline: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Spacing.m) {
            Text(title)
                .textStyle(.display)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if let message {
                Text(message)
                    .textStyle(.body)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

#Preview("Onboarding") {
    OnboardingFlow(models: GallerySamples.downloadsInProgress, actions: .inert)
}
