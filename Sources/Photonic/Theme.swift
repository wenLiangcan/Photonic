import SwiftUI

enum PhotonicTheme {
    static let chrome = Color(red: 0.105, green: 0.11, blue: 0.125)
    static let accent = Color(red: 0.38, green: 0.70, blue: 0.98)
}

enum PhotonicTooltipPlacement {
    case above
    case below

    var alignment: Alignment {
        switch self {
        case .above: .top
        case .below: .bottom
        }
    }

    var verticalOffset: CGFloat {
        switch self {
        case .above: -36
        case .below: 36
        }
    }
}

private struct PhotonicTooltipModifier: ViewModifier {
    let text: String
    let placement: PhotonicTooltipPlacement

    @State private var isPresented = false
    @State private var presentationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)
            .onHover { hovering in
                presentationTask?.cancel()
                if hovering {
                    presentationTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(420))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            isPresented = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.10)) {
                        isPresented = false
                    }
                }
            }
            .overlay(alignment: placement.alignment) {
                if isPresented {
                    tooltip
                        .offset(y: placement.verticalOffset)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .zIndex(isPresented ? 100 : 0)
            .onDisappear {
                presentationTask?.cancel()
                presentationTask = nil
                isPresented = false
            }
    }

    private var tooltip: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                PhotonicTheme.chrome.opacity(0.78),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.38), radius: 8, y: 4)
            .allowsHitTesting(false)
    }
}

extension View {
    func photonicTooltip(
        _ text: String,
        placement: PhotonicTooltipPlacement = .above
    ) -> some View {
        modifier(PhotonicTooltipModifier(text: text, placement: placement))
    }
}
