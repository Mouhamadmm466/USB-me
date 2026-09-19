import Foundation

/// Opens a file inside an authorized scope (Quick Look on iOS). Returns whether a viewer was
/// actually presented.
public protocol FileOpening: Sendable {
    func open(_ url: URL) async -> Bool
}

#if os(iOS) && canImport(QuickLook) && canImport(UIKit)
import QuickLook
import UIKit

/// Presents `QLPreviewController` from the view controller returned by `presenter`.
@MainActor
public final class SystemFileOpener: FileOpening {
    private let presenter: ViewControllerPresenter
    /// `QLPreviewController.dataSource` is weak; keep the current one alive.
    private var dataSource: PreviewDataSource?

    public init(presenter: @escaping ViewControllerPresenter) {
        self.presenter = presenter
    }

    public func open(_ url: URL) async -> Bool {
        let item = url as NSURL
        guard QLPreviewController.canPreview(item), let host = presenter()?.topMostPresented else { return false }
        let source = PreviewDataSource(item: item)
        let controller = QLPreviewController()
        controller.dataSource = source
        dataSource = source
        host.present(controller, animated: true)
        return true
    }
}

@MainActor
private final class PreviewDataSource: NSObject, QLPreviewControllerDataSource {
    private let item: NSURL

    init(item: NSURL) {
        self.item = item
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        item
    }
}
#endif
