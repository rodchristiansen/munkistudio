import SwiftUI
import Core

/// One drawn segment of a commit-graph row. `upperHalf` segments span the
/// row's top edge to its vertical middle; the rest span middle to bottom.
struct GraphSegment: Hashable {
    var fromColumn: Int
    var toColumn: Int
    var upperHalf: Bool
    var colorIndex: Int
}

/// Per-commit graph geometry, parallel to the commit list.
struct GraphRow: Hashable {
    var dotColumn: Int
    var dotColorIndex: Int
    var segments: [GraphSegment]
}

enum CommitGraphBuilder {
    /// Compute lane geometry for `commits` (newest first). Lanes hold a
    /// fixed column for their lifetime, so passing lines stay vertical —
    /// only the commit dot's parent links and convergences bend.
    static func build(_ commits: [GitCommit]) -> (rows: [GraphRow], laneCount: Int) {
        var lanes: [String?] = []
        var laneColor: [Int] = []
        var rows: [GraphRow] = []
        var nextColor = 0
        var laneCount = 1

        func takeColor() -> Int { defer { nextColor += 1 }; return nextColor }
        func freeColumn() -> Int {
            if let i = lanes.firstIndex(where: { $0 == nil }) { return i }
            lanes.append(nil)
            laneColor.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            let entry = lanes
            let occupied = entry.indices.filter { entry[$0] == commit.sha }
            let col: Int
            if let first = occupied.first {
                col = first
            } else {
                col = freeColumn()
                lanes[col] = commit.sha
                laneColor[col] = takeColor()
            }
            let dotColor = laneColor[col]

            var segments: [GraphSegment] = []
            // Top half: every entry lane drops into this row.
            for i in entry.indices {
                guard let sha = entry[i] else { continue }
                let target = (sha == commit.sha) ? col : i
                segments.append(GraphSegment(fromColumn: i, toColumn: target, upperHalf: true, colorIndex: laneColor[i]))
            }

            // Converged lanes free up; `col` continues as the first parent.
            for i in occupied { lanes[i] = nil }
            let parents = commit.parents
            lanes[col] = parents.first
            var fromDot: Set<Int> = [col]
            for parent in parents.dropFirst() {
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    fromDot.insert(existing)
                } else {
                    let nc = freeColumn()
                    lanes[nc] = parent
                    laneColor[nc] = takeColor()
                    fromDot.insert(nc)
                }
            }

            // Bottom half: every exit lane leaves this row.
            for i in lanes.indices {
                guard lanes[i] != nil else { continue }
                if i == col {
                    if parents.first != nil {
                        segments.append(GraphSegment(fromColumn: col, toColumn: col, upperHalf: false, colorIndex: dotColor))
                    }
                } else if fromDot.contains(i) {
                    segments.append(GraphSegment(fromColumn: col, toColumn: i, upperHalf: false, colorIndex: laneColor[i]))
                } else {
                    segments.append(GraphSegment(fromColumn: i, toColumn: i, upperHalf: false, colorIndex: laneColor[i]))
                }
            }

            rows.append(GraphRow(dotColumn: col, dotColorIndex: dotColor, segments: segments))
            laneCount = max(laneCount, lanes.count)
        }
        return (rows, laneCount)
    }
}

/// Stable palette for graph lanes and ref badges — cycled by index.
enum GraphPalette {
    static let colors: [Color] = [.blue, .pink, .green, .orange, .purple, .teal, .red, .indigo]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Leading graph column drawn for one commit row.
struct GraphCell: View {
    let row: GraphRow
    let laneCount: Int
    let rowHeight: CGFloat

    private let laneWidth: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            func x(_ column: Int) -> CGFloat {
                CGFloat(column) * laneWidth + laneWidth / 2
            }
            let mid = size.height / 2
            for segment in row.segments {
                var path = Path()
                if segment.upperHalf {
                    path.move(to: CGPoint(x: x(segment.fromColumn), y: 0))
                    path.addLine(to: CGPoint(x: x(segment.toColumn), y: mid))
                } else {
                    path.move(to: CGPoint(x: x(segment.fromColumn), y: mid))
                    path.addLine(to: CGPoint(x: x(segment.toColumn), y: size.height))
                }
                context.stroke(path, with: .color(GraphPalette.color(segment.colorIndex)), lineWidth: 2)
            }
            let center = CGPoint(x: x(row.dotColumn), y: mid)
            let radius: CGFloat = 4.5
            let dotRect = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(GraphPalette.color(row.dotColorIndex)))
        }
        .frame(width: max(CGFloat(laneCount) * laneWidth, laneWidth), height: rowHeight)
    }
}
