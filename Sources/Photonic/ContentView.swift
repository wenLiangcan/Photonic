import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewer: ViewerStore
    @State private var didRequestInitialImage = false

    var body: some View {
        ZStack {
            // The blur is supplied by the AppKit NSVisualEffectView behind this
            // transparent hosting view. This layer only adds a restrained dim.
            Color.black.opacity(viewer.currentItem == nil ? 0.20 : 0.30)
                .ignoresSafeArea()

            if viewer.currentItem != nil {
                PhotoViewer()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                EmptyViewer()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.22), value: viewer.currentItem?.id)
        .task {
            guard !didRequestInitialImage else { return }
            didRequestInitialImage = true
            try? await Task.sleep(for: .milliseconds(180))
            if viewer.currentItem == nil { viewer.presentOpenPanel() }
        }
    }
}

private struct EmptyViewer: View {
    @EnvironmentObject private var viewer: ViewerStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.055))
                        .frame(width: 108, height: 108)
                    Circle()
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                        .frame(width: 108, height: 108)
                    Image(systemName: "photo")
                        .font(.system(size: 43, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.88))
                }

                VStack(spacing: 7) {
                    Text("Open an image or folder")
                        .font(.system(size: 22, weight: .medium))
                    Text("Choose a photograph or a folder to begin")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.48))
                }

                Button(action: { viewer.presentOpenPanel() }) {
                    Label("Choose Image or Folder…", systemImage: "folder")
                        .font(.system(size: 12.5, weight: .medium))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.white.opacity(0.16))

                Text("⌘O")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(50)

            Button { NSApp.keyWindow?.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.24), in: Circle())
                    .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.82))
            .help("Close window")
            .padding(18)
        }
    }
}
