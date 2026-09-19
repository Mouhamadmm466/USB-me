import SwiftUI

extension View {
    /// Liquid Glass on iOS 26; an ultra-thin material with a hairline outline on iOS 18.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint.opacity(0.18)) }
                    shape.stroke(Palette.hairline, lineWidth: 0.5)
                }
            }
        }
    }

    /// Pins a bar to the top or bottom edge. On iOS 26 it is a `safeAreaBar`, so scrolled
    /// content blurs beneath it (`hardEdge` makes that backing opaque enough for text-heavy
    /// bars); on iOS 18 the bar sits on a fade of the canvas.
    func edgeBar<Bar: View>(_ edge: VerticalEdge, hardEdge: Bool = false, @ViewBuilder bar: () -> Bar) -> some View {
        modifier(EdgeBarModifier(edge: edge, hardEdge: hardEdge, bar: bar()))
    }
}

private struct EdgeBarModifier<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let hardEdge: Bool
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(hardEdge ? .hard : .automatic, for: edge == .top ? .top : .bottom)
                .safeAreaBar(edge: edge, spacing: 0) { bar }
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) {
                bar.background {
                    LinearGradient(
                        stops: [
                            .init(color: Palette.canvas, location: 0),
                            .init(color: Palette.canvas.opacity(0.92), location: 0.55),
                            .init(color: Palette.canvas.opacity(0), location: 1),
                        ],
                        startPoint: edge == .top ? .top : .bottom,
                        endPoint: edge == .top ? .bottom : .top
                    )
                    .ignoresSafeArea(edges: edge == .top ? .top : .bottom)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
