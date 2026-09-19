import SwiftUI

/// Lays subviews out in rows, wrapping to a new row when the next one does not fit.
/// Used for clarification chips; at large text sizes each chip simply takes its own row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let leftover = bounds.width - row.width
            var x: CGFloat = switch alignment {
            case .center: bounds.minX + leftover / 2
            case .trailing: bounds.minX + leftover
            default: bounds.minX
            }
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let fitted = CGSize(width: min(size.width, maxWidth), height: size.height)
            let needed = current.items.isEmpty ? fitted.width : current.width + spacing + fitted.width
            if needed > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? fitted.width : current.width + spacing + fitted.width
            current.height = max(current.height, fitted.height)
            current.items.append((index, fitted))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
