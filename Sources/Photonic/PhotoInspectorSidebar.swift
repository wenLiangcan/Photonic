import AppKit
import MapKit
import SwiftUI

struct PhotoInspectorSidebar: View {
    let item: ViewerItem
    let close: () -> Void

    @State private var metadata: PhotoMetadata?
    @State private var metadataPage = 0

    private let metadataRowsPerPage = 8

    init(item: ViewerItem, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _metadata = State(initialValue: ImageMetadataLoader.shared.cachedMetadata(for: item.url))
    }

    var body: some View {
        VStack(spacing: 12) {
            exifCard
                .frame(maxHeight: 330)
            locationCard
                .frame(maxHeight: .infinity)
        }
        .frame(width: 338)
        .task(id: item.id) {
            metadataPage = 0
            if let cached = ImageMetadataLoader.shared.cachedMetadata(for: item.url) {
                metadata = cached
                return
            }
            let loaded = await ImageMetadataLoader.shared.metadata(for: item.url)
            guard !Task.isCancelled else { return }
            metadata = loaded
        }
    }

    private var exifCard: some View {
        InspectorCard {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("Photo Info", systemImage: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 25, height: 25)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.09), in: Circle())
                    .photonicTooltip("Close photo info", placement: .below)
                }

                Text(item.fileName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                if let metadata {
                    if metadata.rows.isEmpty {
                        InspectorEmptyState(
                            icon: "camera.metering.unknown",
                            title: "No EXIF information"
                        )
                    } else {
                        let pages = metadataPages(metadata.rows)
                        VStack(spacing: 7) {
                            VStack(spacing: 0) {
                                ForEach(pages[metadataPage]) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(row.label)
                                            .foregroundStyle(.white.opacity(0.44))
                                            .fixedSize(horizontal: true, vertical: false)
                                        Spacer(minLength: 10)
                                        Text(row.value)
                                            .foregroundStyle(.white.opacity(0.88))
                                            .multilineTextAlignment(.trailing)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: 190, alignment: .trailing)
                                            .layoutPriority(1)
                                    }
                                    .font(.system(size: 11.5))
                                    .padding(.vertical, 5)
                                    Divider().overlay(.white.opacity(0.06))
                                }
                                Spacer(minLength: 0)
                            }
                            .id(metadataPage)
                            .transition(.opacity)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 20)
                                    .onEnded { value in
                                        guard abs(value.translation.width) > abs(value.translation.height),
                                              abs(value.translation.width) > 35 else { return }
                                        let destination = value.translation.width < 0
                                            ? metadataPage + 1
                                            : metadataPage - 1
                                        guard pages.indices.contains(destination) else { return }
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            metadataPage = destination
                                        }
                                    }
                            )

                            if pages.count > 1 {
                                HStack(spacing: 7) {
                                    ForEach(pages.indices, id: \.self) { pageIndex in
                                        Button {
                                            withAnimation(.easeOut(duration: 0.18)) {
                                                metadataPage = pageIndex
                                            }
                                        } label: {
                                            Circle()
                                                .fill(.white.opacity(metadataPage == pageIndex ? 0.92 : 0.28))
                                                .frame(width: 6, height: 6)
                                                .contentShape(Circle().inset(by: -5))
                                        }
                                        .buttonStyle(.plain)
                                        .photonicTooltip("Photo info page \(pageIndex + 1) of \(pages.count)")
                                    }
                                }
                                .frame(height: 10)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Photo info pages")
                            }
                        }
                        .background {
                            MetadataPageWheelCapture { direction in
                                let destination = metadataPage + direction
                                guard pages.indices.contains(destination) else { return }
                                withAnimation(.easeOut(duration: 0.18)) {
                                    metadataPage = destination
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var locationCard: some View {
        InspectorCard(padding: 0) {
            if let location = metadata?.location {
                ZStack(alignment: .topLeading) {
                    PhotoLocationMap(location: location)
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Location", systemImage: "location.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(coordinateText(location))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.64))
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .padding(12)
                }
            } else if metadata != nil {
                InspectorEmptyState(
                    icon: "map",
                    title: "No location data",
                    subtitle: "This photo does not contain GPS coordinates."
                )
                .padding(20)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func coordinateText(_ location: PhotoMetadata.Location) -> String {
        var text = String(format: "%.5f, %.5f", location.latitude, location.longitude)
        if let altitude = location.altitude { text += String(format: "  •  %.0f m", altitude) }
        return text
    }

    private func metadataPages(_ rows: [PhotoMetadata.Row]) -> [[PhotoMetadata.Row]] {
        stride(from: 0, to: rows.count, by: metadataRowsPerPage).map { start in
            Array(rows[start..<min(start + metadataRowsPerPage, rows.count)])
        }
    }
}

private struct MetadataPageWheelCapture: NSViewRepresentable {
    let onPageChange: (Int) -> Void

    func makeNSView(context: Context) -> MetadataPageWheelView {
        let view = MetadataPageWheelView()
        view.onPageChange = onPageChange
        return view
    }

    func updateNSView(_ nsView: MetadataPageWheelView, context: Context) {
        nsView.onPageChange = onPageChange
    }
}

final class MetadataPageWheelView: NSView {
    var onPageChange: ((Int) -> Void)?

    private var accumulatedDelta = 0.0
    private var didChangePage = false
    private var lastPhaseLessChangeTime = -Double.infinity
    private var resetTask: Task<Void, Never>?

    func handleWheelEvent(_ event: NSEvent) {
        let rawX = Double(event.scrollingDeltaX)
        let rawY = Double(event.scrollingDeltaY)
        guard max(abs(rawX), abs(rawY)) > 0.001 else { return }

        let rawDelta = abs(rawY) >= abs(rawX) ? rawY : -rawX
        let adjustedDelta = event.isDirectionInvertedFromDevice ? -rawDelta : rawDelta

        if event.phase.contains(.began) {
            resetGestureState()
        }

        if !event.momentumPhase.isEmpty {
            scheduleReset()
            return
        }

        if event.phase.isEmpty {
            accumulatedDelta += adjustedDelta
            let threshold = event.hasPreciseScrollingDeltas ? 1.0 : 0.01
            let cooldownElapsed = event.timestamp - lastPhaseLessChangeTime >= 0.42
            if abs(accumulatedDelta) >= threshold, cooldownElapsed {
                changePage(for: accumulatedDelta)
                accumulatedDelta = 0
                lastPhaseLessChangeTime = event.timestamp
            }
            return
        }

        scheduleReset()
        accumulatedDelta += adjustedDelta
        let threshold = event.hasPreciseScrollingDeltas ? 30.0 : 0.01
        if !didChangePage, abs(accumulatedDelta) >= threshold {
            changePage(for: accumulatedDelta)
            didChangePage = true
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            scheduleReset(after: .milliseconds(80))
        }
    }

    private func changePage(for delta: Double) {
        onPageChange?(delta < 0 ? 1 : -1)
    }

    private func scheduleReset(after delay: Duration = .milliseconds(180)) {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.resetGestureState()
        }
    }

    private func resetGestureState() {
        resetTask?.cancel()
        resetTask = nil
        accumulatedDelta = 0
        didChangePage = false
    }
}

private struct PhotoLocationMap: View {
    let location: PhotoMetadata.Location

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var body: some View {
        Map(
            initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 2_500,
                longitudinalMeters: 2_500
            )),
            interactionModes: [.pan, .zoom]
        ) {
            Marker("Photo", systemImage: "camera.fill", coordinate: coordinate)
                .tint(PhotonicTheme.accent)
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .id(location.id)
    }
}

private struct InspectorCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    PhotonicTheme.chrome.opacity(0.50)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }
}

private struct InspectorEmptyState: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.40))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white.opacity(0.68))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
