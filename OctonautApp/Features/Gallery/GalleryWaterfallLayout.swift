import UIKit

/// Lays gallery tiles out in ragged columns, placing each one once.
///
/// This is the same placement rule the `LazyVStack` grid arrived at, moved
/// somewhere it can be held onto. The rule was hard-won and is worth restating,
/// because a layout object makes it easy to get wrong again: **a tile that has
/// been placed keeps its place.** Recomputing from scratch is not a small waste
/// but a visible bug -- a tile already on screen gets handed a different column
/// by the next pass, so it does not resize, it *relocates*, taking everything
/// below it in both columns with it. Instrumented on device, that was 13 to 24
/// tiles moving column on every single pass, and the inputs that provoked it
/// all move while the reader is looking: the list grows with pagination, the
/// width arrives late, and ratios firm up as images are measured.
///
/// So `prepare()` only ever extends. Placement is thrown away for exactly three
/// reasons, each of which genuinely is a different layout: the width changed,
/// the column count changed, or the list got shorter (a refresh).
///
/// ## Why the scan can be a binary search
///
/// Each item goes to whichever column is shortest, so its `minY` is the minimum
/// of the column heights at that moment -- and that minimum never decreases as
/// items are added. `minY` is therefore non-decreasing in index order, which is
/// what makes `layoutAttributesForElements` a binary search rather than a walk
/// over every tile placed so far. On a grid paged out to a few thousand tiles
/// that is the difference between a constant cost per frame and a rising one.
///
/// The backward walk that follows the search terminates quickly for a reason
/// worth naming: tile heights are bounded, because `GalleryMediaItem` clamps
/// every ratio into 9:16...16:9. Without that clamp a single 1:8 infographic
/// would be 1,500 points tall at this column width and the walk would have to
/// go back as far as it reached.
final class GalleryWaterfallLayout: UICollectionViewLayout {
    var columnCount: Int = 2
    var spacing: CGFloat = 4
    var horizontalInset: CGFloat = 4

    /// The shape item `index` should be laid out at, asked of the grid rather
    /// than stored, so a ratio that firms up is picked up by `relayout(from:)`
    /// without the layout having to hold a copy of the model.
    var aspectRatio: (Int) -> CGFloat = { _ in GalleryMediaItem.fallbackAspectRatio }

    private var placed: [UICollectionViewLayoutAttributes] = []
    /// The column each placed tile went in. Kept so placement can be unwound
    /// from an index without re-deriving a column from an x coordinate.
    private var placedColumns: [Int] = []
    private var columnHeights: [CGFloat] = []
    private var contentHeight: CGFloat = 0
    private var layoutWidth: CGFloat = 0

    /// How many tiles have been given a position. The grid reads this to know
    /// whether a newly measured ratio belongs to a tile already placed.
    var placedCount: Int { placed.count }

    /// The width one tile is laid out at.
    ///
    /// Exposed because it is also the width a tile asks Reddit for a copy at,
    /// and the cell cannot read it from its own bounds: the collection view
    /// applies the layout attributes' frame *after* `cellForItemAt` returns,
    /// so during configuration a recycled cell is still the size of whatever
    /// tile had it last.
    ///
    /// Falls back to the collection view's own width before the first
    /// `prepare` has recorded one, so a cell configured early asks for a copy
    /// sized to roughly the right tile rather than to a single point.
    var tileWidth: CGFloat {
        let width = layoutWidth > 0 ? layoutWidth : (collectionView?.bounds.width ?? 0)
        let columns = max(1, columnCount)
        let available = width - horizontalInset * 2 - spacing * CGFloat(columns - 1)
        return max(1, (available / CGFloat(columns)).rounded(.down))
    }

    /// Room kept below the tiles for the status footer -- "Loading more", or
    /// the end of the listing. Zero hides it.
    var footerHeight: CGFloat = 0

    override var collectionViewContentSize: CGSize {
        CGSize(width: layoutWidth, height: contentHeight + footerHeight)
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String, at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard elementKind == UICollectionView.elementKindSectionFooter, footerHeight > 0 else {
            return nil
        }
        let attributes = UICollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = CGRect(
            x: 0, y: contentHeight, width: layoutWidth, height: footerHeight)
        return attributes
    }

    override func prepare() {
        super.prepare()
        guard let collectionView, collectionView.bounds.width > 0 else { return }
        let width = collectionView.bounds.width
        let total = collectionView.numberOfItems(inSection: 0)

        if width != layoutWidth || columnHeights.count != columnCount || total < placed.count {
            layoutWidth = width
            resetPlacement()
        }
        guard total > placed.count else { return }
        place(from: placed.count, to: total)
    }

    /// Throws away the placement of `index` and everything after it, so those
    /// tiles are laid out again on the next pass.
    ///
    /// For a ratio that arrived late. Rare by design -- Reddit publishes
    /// dimensions for images and video, and the gallery reads a size per page,
    /// so the only tiles that ever measure their own shape are the ones that
    /// published none. Everything before `index` keeps its place, which is the
    /// property that matters.
    func relayout(from index: Int) {
        guard index >= 0, index < placed.count else { return }
        for position in index..<placed.count {
            let column = placedColumns[position]
            let frame = placed[position].frame
            // Unwind the column this tile added to, back to its top edge.
            columnHeights[column] = min(columnHeights[column], frame.minY)
        }
        placed.removeSubrange(index...)
        placedColumns.removeSubrange(index...)
        contentHeight = columnHeights.max() ?? 0
        invalidateLayout()
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        placed.indices.contains(indexPath.item) ? placed[indexPath.item] : nil
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !placed.isEmpty else { return nil }
        // First tile whose top is past the bottom of the rect: everything from
        // here on is below the viewport.
        let end = firstIndex { $0.frame.minY > rect.maxY } ?? placed.count
        // First tile whose top is at or past the top of the rect, then back up
        // over the ones that start above it and are tall enough to reach in.
        var start = firstIndex { $0.frame.minY >= rect.minY } ?? placed.count
        while start > 0, placed[start - 1].frame.maxY >= rect.minY {
            start -= 1
        }
        var result = start < end ? Array(placed[start..<end]) : []
        if footerHeight > 0,
           rect.maxY >= contentHeight,
           let footer = layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionFooter,
            at: IndexPath(item: 0, section: 0)) {
            result.append(footer)
        }
        return result
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != layoutWidth
    }

    /// Binary search over `minY`, which is non-decreasing in index order.
    private func firstIndex(where predicate: (UICollectionViewLayoutAttributes) -> Bool) -> Int? {
        var low = 0
        var high = placed.count
        while low < high {
            let middle = (low + high) / 2
            if predicate(placed[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low < placed.count ? low : nil
    }

    /// Throws away every placement. For a list that changed identity rather
    /// than grew -- a refresh, or a different feed -- where keeping positions
    /// would mean keeping them for tiles that are no longer there.
    func reset() {
        resetPlacement()
        invalidateLayout()
    }

    private func resetPlacement() {
        placed.removeAll(keepingCapacity: true)
        placedColumns.removeAll(keepingCapacity: true)
        columnHeights = Array(repeating: 0, count: max(1, columnCount))
        contentHeight = 0
    }

    private func place(from start: Int, to end: Int) {
        if columnHeights.count != columnCount {
            columnHeights = Array(repeating: 0, count: max(1, columnCount))
        }
        let tileWidth = self.tileWidth

        for index in start..<end {
            let column = shortestColumn()
            // The clamp is the model's, applied here too because the layout
            // must not be able to produce a height the tile would refuse to
            // draw at -- the two have to agree or the image is letterboxed
            // inside a box of the wrong shape.
            let ratio = GalleryMediaItem.clamped(aspectRatio(index))
            let height = (tileWidth / max(ratio, 0.05)).rounded()
            let attributes = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(
                x: horizontalInset + (tileWidth + spacing) * CGFloat(column),
                y: columnHeights[column],
                width: tileWidth,
                height: height)
            placed.append(attributes)
            placedColumns.append(column)
            columnHeights[column] += height + spacing
        }
        contentHeight = columnHeights.max() ?? 0
    }

    /// Leftmost of the columns that are within a hair of the shortest, rather
    /// than strictly the shortest. Ties go left, which keeps reading order
    /// natural where several tiles are the same height.
    private func shortestColumn() -> Int {
        let shortest = columnHeights.min() ?? 0
        return columnHeights.indices.first { columnHeights[$0] <= shortest + spacing } ?? 0
    }
}
