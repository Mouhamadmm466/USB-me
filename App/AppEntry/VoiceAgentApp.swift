import SwiftUI

@main
struct VoiceAgentApp: App {
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-DesignGallery") {
                DesignGalleryView()
            } else {
                Text("Voice Agent")
            }
        }
    }
}
