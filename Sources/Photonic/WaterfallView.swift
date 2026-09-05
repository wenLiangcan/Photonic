import AppKit
import SwiftUI

struct WaterfallView: View {
    let isSizeAdjustmentActive: Bool

    @EnvironmentObject private var viewer: ViewerStore
    @Environment(\.displayScale) private var displayScale
    @State private var aspectRatios: [String: CGFloat] = [:]
    @State private var revealScheduled = false
    @State private var settledThumbnailPixelSize: Int?
    @State private var isResizing = false
    @State private var resizeSettlingTask: Task<Void, Never>?

    private let spacing: CGFloat = 12
    private let horizontalPadding: CGFloat = 18

    var body: some View {
        ScrollViewReader { scrollProxy in
            GeometryReader { proxy in
                let availableWidth = max(proxy.size.width - horizontalPadding * 2, 1)
                let layout = WaterfallLayoutResult(
                    items: viewer.items,
                    availableWidth: availableWidth,
                    preferredWidth: viewer.waterfallImageSize,
                    aspectRatios: aspectRatios,
                    spacing: spacing
                )
                let rawThumbnailPixelSize = Int(ceil(layout.itemWidth * displayScale))
                let desiredThumbnailPixelSize = max(128, Int(ceil(Double(rawThumbnailPixelSize) / 128)) * 128)
                let thumbnailPixelSize = settledThumbnailPixelSize ?? desiredThumbnailPixelSize

                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(layout.columns.indices, id: \.self) { column in
                            LazyVStack(spacing: spacing) {
                                ForEach(layout.columns[column]) { tile in
                                    WaterfallPhotoTile(
                                        item: tile.item,
                                        selected: tile.item == viewer.currentItem,
                                        size: CGSize(width: layout.itemWidth, height: tile.height),
                                        maxPixelSize: thumbnailPixelSize,
                                        loadingEnabled: !isResizing && !isSizeAdjustmentActive
                                    ) {
                                        viewer.showInSingleView(tile.item)
                                    }
                                    .id(tile.item.id)
                                }
                            }
                            .frame(width: layout.itemWidth)
                        }
                    }
                    .frame(width: availableWidth, alignment: .top)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 64)
                    .padding(.bottom, 104)
                }
                .scrollIndicators(.visible)
                .onChange(of: proxy.size) { _, _ in
                    scheduleResizeSettling(
                        at: desiredThumbnailPixelSize,
                        using: scrollProxy
                    )
                }
                .onChange(of: viewer.waterfallImageSize) { _, _ in
                    if !isSizeAdjustmentActive {
                        scheduleThumbnailLoading(at: desiredThumbnailPixelSize)
                    }
                }
                .onChange(of: desiredThumbnailPixelSize) { _, newSize in
                    if !isSizeAdjustmentActive {
                        scheduleThumbnailLoading(at: newSize)
                    }
                }
                .onChange(of: isSizeAdjustmentActive) { _, isAdjusting in
                    if !isAdjusting {
                        settledThumbnailPixelSize = desiredThumbnailPixelSize
                    }
                }
                .onChange(of: viewer.waterfallNavigationCommand) { _, command in
                    guard let command,
                          let destination = layout.destination(
                            from: viewer.currentItem,
                            moving: command.direction
                          ) else { return }
                    viewer.selectInWaterfall(destination)
                }
            }
            .onAppear {
                revealCurrentImage(using: scrollProxy)
            }
            .onDisappear {
                resizeSettlingTask?.cancel()
            }
            .onChange(of: viewer.currentItem?.id) { _, _ in
                revealCurrentImage(using: scrollProxy)
            }
            .onChange(of: viewer.waterfallImageSize) { _, _ in
                revealCurrentImage(using: scrollProxy)
            }
            .task(id: viewer.items.map(\.id).joined(separator: "\u{0}")) {
                let ratios = await WaterfallImageLoader.shared.aspectRatios(for: viewer.items)
                guard !Task.isCancelled else { return }
                aspectRatios = ratios
                revealCurrentImage(using: scrollProxy)
            }
        }
    }

    private func revealCurrentImage(using scrollProxy: ScrollViewProxy) {
        guard !revealScheduled, let currentID = viewer.currentItem?.id else { return }
        revealScheduled = true
        Task { @MainActor in
            await Task.yield()
            scrollProxy.scrollTo(currentID, anchor: .center)
            revealScheduled = false
        }
    }

    private func scheduleThumbnailLoading(at pixelSize: Int) {
        isResizing = true
        resizeSettlingTask?.cancel()
        resizeSettlingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            settledThumbnailPixelSize = pixelSize
            isResizing = false
        }
    }

    private func scheduleResizeSettling(
        at pixelSize: Int,
        using scrollProxy: ScrollViewProxy
    ) {
        isResizing = true
        resizeSettlingTask?.cancel()
        resizeSettlingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            settledThumbnailPixelSize = pixelSize
            isResizing = false
            revealCurrentImage(using: scrollProxy)
        }
    }
}

private struct WaterfallPhotoTile: View {
    let item: ViewerItem
    let selected: Bool
    let size: CGSize
    let maxPixelSize: Int
    let loadingEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.18)

                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.22))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.70)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .opacity(isHovering ? 1 : 0)

                Text(item.fileName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .padding(10)
                    .opacity(isHovering ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        .frame(width: size.width, height: size.height)
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    selected ? PhotonicTheme.accent.opacity(0.92) : .white.opacity(isHovering ? 0.20 : 0.08),
                    lineWidth: selected ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(isHovering ? 0.42 : 0.28), radius: isHovering ? 14 : 8, y: 5)
        .scaleEffect(isHovering ? 1.008 : 1)
        .zIndex(isHovering ? 1 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .photonicTooltip(item.fileName)
        .accessibilityLabel(item.fileName)
        .task(id: ThumbnailRequest(
            itemID: item.id,
            maxPixelSize: maxPixelSize,
            loadingEnabled: loadingEnabled
        )) {
            guard loadingEnabled else { return }
            guard let loaded = await WaterfallImageLoader.shared.thumbnail(
                for: item.url,
                maxPixelSize: maxPixelSize
            ), !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                thumbnail = loaded
            }
        }
    }
}

private struct ThumbnailRequest: Hashable {
    let itemID: String
    let maxPixelSize: Int
    let loadingEnabled: Bool
}

@MainActor
private struct WaterfallLayoutResult {
    struct Tile: Identifiable {
        let item: ViewerItem
        let height: CGFloat
        let centerY: CGFloat

        var id: String { item.id }
    }

    let columns: [[Tile]]
    let itemWidth: CGFloat

    func destination(
        from currentItem: ViewerItem?,
        moving direction: WaterfallNavigationDirection
    ) -> ViewerItem? {
        guard let currentItem,
              let columnIndex = columns.firstIndex(where: { column in
                  column.contains { $0.item == currentItem }
              }),
              let rowIndex = columns[columnIndex].firstIndex(where: { $0.item == currentItem }) else {
            return columns.first?.first?.item
        }

        switch direction {
        case .up:
            guard rowIndex > 0 else { return nil }
            return columns[columnIndex][rowIndex - 1].item
        case .down:
            guard rowIndex + 1 < columns[columnIndex].count else { return nil }
            return columns[columnIndex][rowIndex + 1].item
        case .left, .right:
            let neighborIndex = direction == .left ? columnIndex - 1 : columnIndex + 1
            guard columns.indices.contains(neighborIndex) else { return nil }
            let currentCenter = columns[columnIndex][rowIndex].centerY
            return columns[neighborIndex]
                .min { abs($0.centerY - currentCenter) < abs($1.centerY - currentCenter) }?
                .item
        }
    }

    init(
        items: [ViewerItem],
        availableWidth: CGFloat,
        preferredWidth: Double,
        aspectRatios: [String: CGFloat],
        spacing: CGFloat
    ) {
        let requestedWidth = min(max(CGFloat(preferredWidth), 1), availableWidth)
        let columnCount = max(1, Int((availableWidth + spacing) / (requestedWidth + spacing)))
        var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
        var placedColumns = Array(repeating: [Tile](), count: columnCount)

        for item in items {
            let column = columnHeights.indices.min { columnHeights[$0] < columnHeights[$1] } ?? 0
            let aspectRatio = min(max(aspectRatios[item.id] ?? 4 / 3, 0.45), 2.8)
            let itemHeight = requestedWidth / aspectRatio
            placedColumns[column].append(Tile(
                item: item,
                height: itemHeight,
                centerY: columnHeights[column] + itemHeight / 2
            ))
            columnHeights[column] += itemHeight + spacing
        }

        columns = placedColumns
        itemWidth = requestedWidth
    }
}
