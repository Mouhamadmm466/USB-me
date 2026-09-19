#if os(iOS) && canImport(MessageUI) && canImport(UIKit)
import MessageUI
import UIKit

/// Presents `MFMessageComposeViewController` and reports exactly what MessageUI returned.
///
/// The user reviews, edits and sends in Apple's UI; this type only reports `.sent` when the
/// delegate receives `MessageComposeResult.sent`.
@MainActor
public final class SystemMessageComposer: NSObject, MessageComposing {
    private let presenter: ViewControllerPresenter
    private var continuation: CheckedContinuation<MessageComposeOutcome, Never>?
    private weak var activeController: MFMessageComposeViewController?

    public init(presenter: @escaping ViewControllerPresenter) {
        self.presenter = presenter
    }

    public func canSendText() async -> Bool {
        MFMessageComposeViewController.canSendText()
    }

    public func compose(recipients: [String], body: String) async -> MessageComposeOutcome {
        guard MFMessageComposeViewController.canSendText() else { return .unavailable }
        // One composer at a time: a second request while the sheet is up never presents.
        guard continuation == nil, let host = presenter()?.topMostPresented else { return .unavailable }

        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = body
        controller.messageComposeDelegate = self
        activeController = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            host.present(controller, animated: true)
        }
    }

    fileprivate func finish(_ controller: MFMessageComposeViewController, result: MessageComposeResult) {
        let outcome: MessageComposeOutcome
        switch result {
        case .sent: outcome = .sent
        case .cancelled: outcome = .cancelled
        case .failed: outcome = .failed
        @unknown default: outcome = .failed
        }
        controller.dismiss(animated: true)
        activeController = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: outcome)
    }
}

extension SystemMessageComposer: MFMessageComposeViewControllerDelegate {
    // MessageUI's delegate protocol is not actor-annotated, but UIKit always calls it on the main thread.
    public nonisolated func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        MainActor.assumeIsolated {
            finish(controller, result: result)
        }
    }
}
#endif
