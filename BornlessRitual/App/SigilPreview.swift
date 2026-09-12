//
//  SigilPreview.swift
//  Bornless Ritual — 2-D sigil preview (ARCHITECTURE §8 "sigil preview (2D Path)",
//  §4 sigil cells (6,4)→(4,2)→(1,6)→(6,2)→(6,4) on the Sun kamea; CORE_API `SigilPath`:
//  start circle radius 0.045, end bar 0.06 perpendicular to the last segment, drawn
//  even when the path is closed).
//
//  Role: SwiftUI `Path` drawing of a `SigilPath` over its kamea grid — cell numbers,
//  the traced polyline, the start circle and the end bar — in normalised coordinates
//  (x right, y down) scaled to a square. Also `TraceTemplateGlyph`, the small elemental
//  trace guide the HUD shows during the quarter stages.
//

import SwiftUI
import Foundation
import RitualCore

/// Sigil traced over the kamea grid.
struct SigilPreview: View {
    /// The sigil to draw.
    let sigil: SigilPath
    /// Whether to print the kamea numbers in the cells.
    var showNumbers: Bool = true
    /// Colour of the traced path and markers.
    var accent: Color = HUDStyle.gold
    /// Colour of the grid lines and numbers.
    var gridColor: Color = Color.white.opacity(0.35)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let origin = CGPoint(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2)
            let order = max(sigil.kamea.order, 1)
            let cell = side / CGFloat(order)
            ZStack(alignment: .topLeading) {
                // Highlighted cells on the path.
                ForEach(Array(sigil.points.enumerated()), id: \.offset) { item in
                    Rectangle()
                        .fill(accent.opacity(0.16))
                        .frame(width: cell, height: cell)
                        .offset(x: origin.x + CGFloat(item.element.col - 1) * cell,
                                y: origin.y + CGFloat(item.element.row - 1) * cell)
                }
                // Grid.
                Path { path in
                    for index in 0...order {
                        let offset = CGFloat(index) * cell
                        path.move(to: CGPoint(x: origin.x + offset, y: origin.y))
                        path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y + side))
                        path.move(to: CGPoint(x: origin.x, y: origin.y + offset))
                        path.addLine(to: CGPoint(x: origin.x + side, y: origin.y + offset))
                    }
                }
                .stroke(gridColor, lineWidth: 1)
                // Numbers.
                if showNumbers {
                    ForEach(0..<(order * order), id: \.self) { index in
                        let row = index / order
                        let col = index % order
                        Text(verbatim: "\(sigil.kamea.cells[row][col])")
                            .font(.system(size: max(cell * 0.3, 7), design: .rounded))
                            .foregroundStyle(gridColor)
                            .frame(width: cell, height: cell)
                            .offset(x: origin.x + CGFloat(col) * cell, y: origin.y + CGFloat(row) * cell)
                    }
                }
                // Traced path.
                Path { path in
                    let points = sigil.polyline.map { SigilPreview.point($0, origin: origin, side: side) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: max(side * 0.012, 1.5), lineCap: .round, lineJoin: .round))
                // Start circle.
                if let start = sigil.startMarkerCenter {
                    let centre = SigilPreview.point(start, origin: origin, side: side)
                    let radius = CGFloat(sigil.startMarkerRadius) * side
                    Path { path in
                        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                    }
                    .stroke(accent, lineWidth: max(side * 0.012, 1.5))
                }
                // End bar.
                if let bar = sigil.endBarSegment {
                    Path { path in
                        path.move(to: SigilPreview.point(bar.start, origin: origin, side: side))
                        path.addLine(to: SigilPreview.point(bar.end, origin: origin, side: side))
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: max(side * 0.016, 2), lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text("Sigil of \(sigil.reducedValues.map(String.init).joined(separator: ", "))"))
    }

    /// Maps a normalised (x right, y down) point into the square.
    static func point(_ normalized: RVec2, origin: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(normalized.x) * side, y: origin.y + CGFloat(normalized.y) * side)
    }

    /// "(6,4) → (4,2) → (1,6) → (6,2) → (6,4)".
    static func cellsDescription(_ sigil: SigilPath) -> String {
        sigil.points.map { "(\($0.row),\($0.col))" }.joined(separator: " → ")
    }
}

// MARK: - Trace template glyph

/// The elemental trace template (`SigilTemplates.path(for:)`) with its 24 checkpoints;
/// the first `hits` checkpoints are lit.
struct TraceTemplateGlyph: View {
    /// Element whose template is drawn.
    let element: RitualElement
    /// Checkpoints hit so far, in order.
    var hits: Int = 0
    /// Path and checkpoint colour.
    var tint: Color = HUDStyle.gold

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let origin = CGPoint(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2)
            let polyline = SigilTemplates.path(for: element)
            let checkpoints = SigilTemplates.checkpoints(for: element)
            ZStack {
                Path { path in
                    let points = polyline.map { SigilPreview.point($0, origin: origin, side: side) }
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(tint.opacity(0.45), style: StrokeStyle(lineWidth: max(side * 0.03, 1.5), lineCap: .round, lineJoin: .round))
                ForEach(Array(checkpoints.enumerated()), id: \.offset) { item in
                    let centre = SigilPreview.point(item.element, origin: origin, side: side)
                    let lit = item.offset < hits
                    Circle()
                        .fill(lit ? tint : tint.opacity(0.25))
                        .frame(width: lit ? side * 0.07 : side * 0.045, height: lit ? side * 0.07 : side * 0.045)
                        .position(centre)
                }
                if polyline.count > 1, let first = polyline.first {
                    // Start marker: where the finger goes down.
                    Circle()
                        .stroke(tint, lineWidth: 1.5)
                        .frame(width: side * 0.12, height: side * 0.12)
                        .position(SigilPreview.point(first, origin: origin, side: side))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text("\(element.rawValue) trace template, \(hits) of \(SigilTemplates.defaultCheckpointCount) checkpoints"))
    }
}
