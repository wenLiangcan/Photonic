import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewer: ViewerStore

    var body: some View {
        ZStack {
            // Keep the media plane quiet while chrome follows the system appearance.
            Color(nsColor: .windowBackgroundColor).opacity(0.45)
                .ignoresSafeArea()

            if viewer.currentItem != nil {
                PhotoViewer()
                    .transition(.opacity)
            } else {
                EmptyViewer()
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.14), value: viewer.currentItem != nil)
    }
}

private struct EmptyViewer: View {
    @EnvironmentObject private var viewer: ViewerStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 18) {
                Image(systemName: "photo")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)

                VStack(spacing: 7) {
                    Text("Open an image or folder")
                        .font(.system(size: 22, weight: .medium))
                    Text("Choose a photograph or a folder to begin")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                Button(action: { viewer.presentOpenPanel() }) {
                    Label("Choose Image or Folder…", systemImage: "folder")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 4)
                }
                .photonicGlassButton(prominent: true)
                .controlSize(.large)

                Text("⌘O")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(50)

            Button { NSApp.keyWindow?.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .photonicGlassButton()
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close window")
            .photonicTooltip("Close window", placement: .below)
            .padding(18)
        }
    }
}
