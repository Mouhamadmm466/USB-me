@testable import Audio
import Telemetry
import Testing

@Suite struct AudioRouterTests {
    private func route(_ output: AudioPortType, _ input: AudioPortType = .builtInMic, hardware: Bool = false) -> AudioRoute {
        AudioRouter.classify(
            outputs: [AudioPortDescriptor(output, hasHardwareVoiceCallProcessing: hardware)],
            inputs: [AudioPortDescriptor(input)]
        )
    }

    @Test(arguments: [
        (AudioPortType.builtInSpeaker, AudioRouteKind.builtInSpeaker, EchoRisk.high, false),
        (.builtInReceiver, .builtInReceiver, .medium, true),
        (.headphones, .wired, .low, true),
        (.bluetoothHFP, .bluetoothHFP, .low, true),
        (.bluetoothA2DP, .bluetoothA2DP, .medium, true),
        (.bluetoothLE, .bluetoothLE, .low, true),
        (.airPlay, .airPlay, .high, false),
        (.carAudio, .carAudio, .high, false),
        (.usbAudio, .usb, .medium, false),
        (.hdmi, .external, .high, false),
        (.lineOut, .external, .high, false),
        (.virtual, .unknown, .medium, false),
    ])
    func classifiesOutputsWithEchoRisk(port: AudioPortType, kind: AudioRouteKind, risk: EchoRisk, isPrivate: Bool) {
        let classified = route(port)
        #expect(classified.kind == kind)
        #expect(classified.echoRisk == risk)
        #expect(classified.isPrivateListening == isPrivate)
    }

    @Test func classifiesInputs() {
        #expect(route(.headphones, .headsetMic).input == .wiredMic)
        #expect(route(.bluetoothHFP, .bluetoothHFP).input == .bluetoothHFP)
        #expect(route(.carAudio, .carAudio).input == .carAudio)
        #expect(route(.builtInSpeaker, .continuityMicrophone).input == .continuity)
        #expect(AudioRouter.classify(outputs: [AudioPortDescriptor(.builtInSpeaker)], inputs: []).input == .none)
    }

    @Test func hardwareVoiceProcessingLowersEchoRiskOneStep() {
        #expect(route(.carAudio, .carAudio, hardware: true).echoRisk == .medium)
        #expect(route(.bluetoothA2DP, hardware: true).echoRisk == .low)
        #expect(route(.bluetoothHFP, hardware: true).echoRisk == .low)
    }

    @Test func theRiskiestOutputDecidesWhenAudioIsMirrored() {
        let mirrored = AudioRouter.classify(
            outputs: [AudioPortDescriptor(.headphones), AudioPortDescriptor(.hdmi)],
            inputs: [AudioPortDescriptor(.builtInMic)]
        )
        #expect(mirrored.kind == .wired)
        #expect(mirrored.echoRisk == .high)
    }

    @Test func noOutputPortsMeansNoRoute() {
        let empty = AudioRouter.classify(outputs: [], inputs: [])
        #expect(empty.kind == AudioRouteKind.none)
        #expect(empty.input == AudioInputKind.none)
        #expect(!empty.isPrivateListening)
    }

    // MARK: - Route-change policy

    @Test func unpluggingHeadphonesStopsPlaybackSoAPrivateReplyNeverMovesToTheSpeaker() {
        let response = AudioRouter.response(
            to: .oldDeviceUnavailable,
            previous: route(.headphones, .headsetMic),
            current: route(.builtInSpeaker)
        )
        #expect(response.contains(.stopPlayback))
        #expect(response.contains(.verifyEngineRunning))
        #expect(response.contains(.refreshEchoPolicy))
    }

    @Test func losingAirPodsToTheReceiverKeepsTalkingPrivately() {
        let response = AudioRouter.response(to: .oldDeviceUnavailable, previous: route(.bluetoothHFP, .bluetoothHFP), current: route(.builtInReceiver))
        #expect(!response.contains(.stopPlayback))
        #expect(response.contains(.verifyEngineRunning))
    }

    @Test func unknownPreviousRouteIsTreatedAsPrivate() {
        #expect(AudioRouter.response(to: .oldDeviceUnavailable, previous: nil, current: route(.builtInSpeaker)).contains(.stopPlayback))
    }

    @Test func connectingADeviceKeepsPlayingAndChecksTheEngine() {
        let response = AudioRouter.response(to: .newDeviceAvailable, previous: route(.builtInSpeaker), current: route(.bluetoothHFP, .bluetoothHFP))
        #expect(response == [.refreshEchoPolicy, .verifyEngineRunning])
    }

    @Test func categoryChangeReappliesTheSessionConfiguration() {
        let response = AudioRouter.response(to: .categoryChange, previous: route(.builtInSpeaker), current: route(.builtInSpeaker))
        #expect(response == [.refreshEchoPolicy, .reapplySessionConfiguration, .verifyEngineRunning])
    }

    @Test func overrideAndConfigurationChangesOnlyRefreshEchoPolicy() {
        #expect(AudioRouter.response(to: .override, previous: route(.builtInReceiver), current: route(.builtInSpeaker)) == [.refreshEchoPolicy])
        #expect(AudioRouter.response(to: .routeConfigurationChange, previous: nil, current: route(.builtInSpeaker)) == [.refreshEchoPolicy])
    }

    @Test func wakeAndUnknownReasonsVerifyTheEngine() {
        #expect(AudioRouter.response(to: .wakeFromSleep, previous: nil, current: route(.builtInSpeaker)) == [.refreshEchoPolicy, .verifyEngineRunning])
        #expect(AudioRouter.response(to: .unknown, previous: nil, current: route(.builtInSpeaker)) == [.refreshEchoPolicy, .verifyEngineRunning])
    }

    @Test func noSuitableRouteStopsEverything() {
        let response = AudioRouter.response(
            to: .noSuitableRouteForCategory,
            previous: route(.builtInSpeaker),
            current: AudioRouter.classify(outputs: [], inputs: [])
        )
        #expect(response.isSuperset(of: [.stopPlayback, .suspendCapture]))
    }

    @Test func missingInputSuspendsCaptureWhateverTheReason() {
        let noInput = AudioRouter.classify(outputs: [AudioPortDescriptor(.builtInSpeaker)], inputs: [])
        #expect(AudioRouter.response(to: .override, previous: nil, current: noInput).contains(.suspendCapture))
    }

    @Test func routeTelemetryIsAClosedVocabulary() {
        let event = TelemetryEvent.audioRoute(kind: SafeLabel(route(.bluetoothHFP, .bluetoothHFP).kind))
        #expect(event.renderedLine == "audio-route bluetoothHFP")
        #expect(SafeLabel(EchoRisk.high).description == "high")
    }
}
