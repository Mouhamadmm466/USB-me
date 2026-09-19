import SwiftUI

@main
struct VoiceAgentApp: App {
    private let arguments = ProcessInfo.processInfo.arguments

    var body: some Scene {
        WindowGroup {
            if arguments.contains("-RunBenchmark") {
                BenchmarkView()
            } else if arguments.contains("-DesignGallery") {
                DesignGalleryView()
            } else {
                Text("Voice Agent")
            }
        }
    }
}
