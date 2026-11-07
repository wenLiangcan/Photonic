import SwiftUI

enum PhotonicTheme {
    static let accent = Color.accentColor
}

enum PhotonicTooltipPlacement {
    case above
    case below
}

/// Keep native tooltips out of the view hierarchy so they don't clip or steal hits.
extension View {
    func photonicTooltip(
        _ text: String,
        placement: PhotonicTooltipPlacement = .above
    ) -> some View {
        help(text)
    }

    func photonicGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(PhotonicGlassModifier(shape: shape, interactive: interactive))
    }

    /// A floating glass widget, like iPadOS sidebar widgets. Content (including
    /// opaque content such as maps) is clipped to the card shape and sits on glass.
    func photonicGlassCard(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape)
            .photonicGlass(in: shape)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    @ViewBuilder
    func photonicGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct PhotonicGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
            } else if reduceTransparency {
                content.background(Color(nsColor: .windowBackgroundColor), in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            if contrast == .increased {
                shape.stroke(.primary.opacity(0.5), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Only wrap neighboring floating controls, never the photo canvas.
struct PhotonicGlassGroup<Content: View>: View {
    /// Glass shapes closer than this blend together; keep it below the layout
    /// spacing when controls should read as separate circles.
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
