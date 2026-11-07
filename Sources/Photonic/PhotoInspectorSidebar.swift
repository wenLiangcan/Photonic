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
        // Two independent floating widgets, iPadOS sidebar-widget style.
        // Not wrapped in a glass container so the cards never morph together.
        VStack(spacing: 12) {
            photoInfo
                .frame(maxHeight: 330)
            locationSection
                .frame(maxHeight: .infinity)
        }
        .frame(width: 320)
        // Swallow wheel events over the rest of the sidebar (gaps, the
        // no-location card) so they never zoom the photo underneath.
        .background {
            MetadataPageWheelCapture(onPageChange: nil)
        }
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

    private var photoInfo: some View {
        InspectorSection {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Label("Photo Info", systemImage: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(.primary.opacity(0.1), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close photo info")
                    .photonicTooltip("Close photo info", placement: .below)
                }

                Text(item.fileName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
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
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Spacer(minLength: 10)
                                        Text(row.value)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.trailing)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: 190, alignment: .trailing)
                                            .layoutPriority(1)
                                    }
                                    .font(.system(size: 11.5))
                                    .padding(.vertical, 5)
                                    Divider()
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
                                // Widget-style page dots.
                                HStack(spacing: 7) {
                                    ForEach(pages.indices, id: \.self) { pageIndex in
                                        Button {
                                            withAnimation(.easeOut(duration: 0.18)) {
                                                metadataPage = pageIndex
                                            }
                                        } label: {
                                            Circle()
                                                .fill(.primary.opacity(metadataPage == pageIndex ? 0.85 : 0.25))
                                                .frame(width: 6, height: 6)
                                                .contentShape(Circle().inset(by: -5))
                                        }
                                        .buttonStyle(.plain)
                                        .help("Photo info page \(pageIndex + 1) of \(pages.count)")
                                    }
                                }
                                .frame(height: 10)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Photo info page")
                                .accessibilityValue("\(metadataPage + 1) of \(pages.count)")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: metadataPage = min(metadataPage + 1, pages.count - 1)
                                    case .decrement: metadataPage = max(metadataPage - 1, 0)
                                    @unknown default: break
                                    }
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
        // Cover the whole Photo Info widget, not only the rows, so the wheel
        // pages anywhere over the card instead of falling through to zoom.
        .background {
            MetadataPageWheelCapture(onPageChange: changeMetadataPage)
        }
    }

    private func changeMetadataPage(by direction: Int) {
        guard let metadata else { return }
        let destination = metadataPage + direction
        guard metadataPages(metadata.rows).indices.contains(destination) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            metadataPage = destination
        }
    }

    private var locationSection: some View {
        InspectorSection(padding: 0) {
            if let location = metadata?.location {
                ZStack(alignment: .topLeading) {
                    PhotoLocationMap(location: location)
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Location", systemImage: "location.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(coordinateText(location))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .photonicGlass(in: RoundedRectangle(cornerRadius: 12))
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
    let onPageChange: ((Int) -> Void)?

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
    /// `nil` marks a passive region that only blocks image zoom.
    var onPageChange: ((Int) -> Void)?

    /// Live capture views. The app's wheel monitor locates them by window
    /// geometry, because Liquid Glass hosts SwiftUI content in layers whose
    /// intermediate views don't report the card bounds to a subview walk.
    private static let liveViews = NSHashTable<MetadataPageWheelView>.weakObjects()

    /// Returns the capture view under `locationInWindow`, preferring the
    /// active page switcher over passive blocking regions.
    static func view(at locationInWindow: NSPoint, in window: NSWindow) -> MetadataPageWheelView? {
        let hits = liveViews.allObjects.filter { view in
            view.window === window
                && !view.isHiddenOrHasHiddenAncestor
                && view.convert(view.bounds, to: nil).contains(locationInWindow)
        }
        return hits.first { $0.onPageChange != nil } ?? hits.first
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            Self.liveViews.remove(self)
            resetGestureState()
        } else {
            Self.liveViews.add(self)
        }
    }

    // Purely a wheel target; clicks go to the controls above or the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var accumulatedDelta = 0.0
    private var didChangePage = false
    private var lastPhaseLessChangeTime = -Double.infinity
    private var resetTask: Task<Void, Never>?

    func handleWheelEvent(_ event: NSEvent) {
        guard onPageChange != nil else { return }
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

private struct InspectorSection<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .photonicGlassCard(cornerRadius: 24)
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
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
