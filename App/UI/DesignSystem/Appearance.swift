import SwiftUI
import UIKit

/// UIKit chrome that SwiftUI fonts cannot reach (navigation bar titles and bar buttons).
/// Idempotent; call once at launch before the first navigation bar is created. The screens
/// that own a navigation stack also call it, so it is safe if the app forgets.
@MainActor
enum DesignSystemAppearance {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let navigationBar = UINavigationBar.appearance()
        navigationBar.titleTextAttributes = [.font: UIFont.dm(.headline)]
        navigationBar.largeTitleTextAttributes = [.font: UIFont.dm(.largeTitle)]

        let barButton = UIBarButtonItem.appearance()
        for state: UIControl.State in [.normal, .highlighted, .disabled, .focused] {
            barButton.setTitleTextAttributes([.font: UIFont.dm(.body)], for: state)
        }
    }
}
