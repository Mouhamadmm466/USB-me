import SwiftUI
import UIKit

/// One-time setup for the design system: registers DM Sans with Core Text and applies it to
/// the UIKit chrome that SwiftUI fonts cannot reach (navigation bar titles, bar buttons).
/// Idempotent. Call it once in `App.init()`; the screens in `App/UI` also call it from their
/// initialisers, so it is safe if the app forgets.
@MainActor
enum DesignSystemAppearance {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        _ = DMSans.isRegistered

        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [.font: UIFont.dm(.headline)]
        navigationBar.largeTitleTextAttributes = [.font: UIFont.dm(.largeTitle)]

        let barButton = UIBarButtonItem.appearance()
        for state: UIControl.State in [.normal, .highlighted, .disabled, .focused] {
            barButton.setTitleTextAttributes([.font: UIFont.dm(.body)], for: state)
        }
    }
}
