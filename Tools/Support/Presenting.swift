#if os(iOS) && canImport(UIKit)
import UIKit

/// Returns the view controller that system UI (message composer, Quick Look) is presented from.
/// Supplied by the app's composition root.
public typealias ViewControllerPresenter = @MainActor @Sendable () -> UIViewController?

extension UIViewController {
    /// The top of the modal presentation chain starting at this controller.
    @MainActor
    var topMostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
