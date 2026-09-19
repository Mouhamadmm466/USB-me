import Agent
import SwiftUI
import UniformTypeIdentifiers

@main
struct VoiceAgentApp: App {
    private let arguments = ProcessInfo.processInfo.arguments

    var body: some Scene {
        WindowGroup {
            if arguments.contains("-RunBenchmark") {
                BenchmarkView()
            } else if arguments.contains("-RunEval") {
                DeviceEvalView()
            } else if arguments.contains("-VoiceSelfTest") {
                #if KOKORO_TTS
                VoiceSelfTestView()
                #else
                Text("The voice self-test needs Kokoro (device build).")
                #endif
            } else if arguments.contains("-DesignGallery") {
                DesignGalleryView()
            } else {
                RootView()
            }
        }
    }
}

/// Routes between first run, the assistant and settings; owns the one `AppModel`.
struct RootView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            switch model.route {
            case .launching:
                AssistantScreen(presentation: AssistantPresentation(state: .booting), intents: .inert)
            case .onboarding:
                OnboardingFlow(models: model.downloads, actions: OnboardingActions(models: model.modelActions, finish: { model.finishOnboarding() }))
            case .assistant:
                AssistantScreen(
                    presentation: model.coordinator?.presentation ?? AssistantPresentation(state: .warmingModels, assistantText: model.warmUpMessage),
                    intents: model.assistantIntents
                )
            }
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsScreen(state: model.settingsState, actions: model.settingsActions, initialSection: model.settingsInitialSection)
                .fileImporter(isPresented: $model.isFolderPickerPresented, allowedContentTypes: [.folder]) { result in
                    if case let .success(url) = result { model.addSharedFolder(url) }
                }
        }
        .sheet(isPresented: $model.isMicrophoneSheetPresented) {
            MicrophonePermissionSheet(
                onContinue: { model.continueAfterMicrophoneExplainer() },
                onNotNow: { model.isMicrophoneSheetPresented = false }
            )
        }
        .environment(\.hapticsEnabled, model.settings.hapticsEnabled)
        .task { await model.start() }
    }
}
