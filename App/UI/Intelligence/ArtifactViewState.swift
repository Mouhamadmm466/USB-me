import Foundation
import Intelligence

/// An artifact ready to be shown, with the names of what it was built from.
struct ArtifactViewState: Identifiable, Equatable {
    var artifact: Artifact
    var sources: [String]

    var id: UUID { artifact.id }
}
