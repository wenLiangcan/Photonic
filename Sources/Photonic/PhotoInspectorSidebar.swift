import MapKit
import SwiftUI

struct PhotoInspectorSidebar: View {
    let item: ViewerItem
    let close: () -> Void

    @State private var metadata: PhotoMetadata?

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
                    .help("Close photo info")
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
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(metadata.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(row.label)
                                            .foregroundStyle(.white.opacity(0.44))
                                        Spacer(minLength: 10)
                                        Text(row.value)
                                            .foregroundStyle(.white.opacity(0.88))
                                            .multilineTextAlignment(.trailing)
                                    }
                                    .font(.system(size: 11.5))
                                    .padding(.vertical, 7)
                                    Divider().overlay(.white.opacity(0.06))
                                }
                            }
                        }
                        .scrollIndicators(.never)
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
