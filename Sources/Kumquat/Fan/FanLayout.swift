import AppKit

/// Pure geometry of the radial fan: rings, petals (annular sectors) and hit testing.
/// All coordinates are relative to the fan centre, y up, angles in radians (0 = +x, CCW positive).
struct FanLayout {
    struct Ring {
        var inner: CGFloat
        var outer: CGFloat
        var count: Int
        /// Angular slots; at least 3 so one or two items still look like petals, not a full ring.
        var slots: Int { max(count, 3) }
        var span: CGFloat { 2 * .pi / CGFloat(slots) }
        /// Rotation (clockwise) of slot 0 away from 12 o'clock.
        var rotation: CGFloat {
            if count == 2 { return -span / 2 }      // two petals symmetric about the top
            return 0
        }
        var mid: CGFloat { (inner + outer) / 2 }
    }

    struct Petal {
        let index: Int          // index into the items array
        let ring: Int
        let startAngle: CGFloat // lower angle
        let endAngle: CGFloat   // higher angle
        let inner: CGFloat
        let outer: CGFloat
        var midAngle: CGFloat { (startAngle + endAngle) / 2 }
        var midRadius: CGFloat { (inner + outer) / 2 }
        /// Usable label width at the mid radius (chord minus padding).
        var labelWidth: CGFloat {
            let chord = 2 * midRadius * sin(min((endAngle - startAngle) / 2, .pi / 2))
            // Horizontal text in a petal beside the centre must also stay inside the ring's thickness.
            let c = abs(cos(midAngle))
            let radial = c > 0.01 ? (outer - inner) / c - 2 : .greatestFiniteMagnitude
            return max(20, min(chord - 12, radial))
        }
        var labelHeight: CGFloat { outer - inner - 6 }
        func labelCenter(_ c: CGPoint) -> CGPoint {
            return CGPoint(x: c.x + cos(midAngle) * midRadius, y: c.y + sin(midAngle) * midRadius)
        }
    }

    static let centerRadius: CGFloat = 54
    static let gap: CGFloat = 5            // straight gap between neighbouring petals, in points
    static let ringSpacing: CGFloat = 5
    static let cornerRadius: CGFloat = 7
    static let highlightGrow: CGFloat = 5
    static let maxInnerRingCount = 10

    let centerRadius: CGFloat
    let rings: [Ring]
    let petals: [Petal]
    /// Radius of the outermost drawn element, including the highlight growth.
    var outerRadius: CGFloat { (rings.last?.outer ?? centerRadius) + Self.highlightGrow }

    init(count: Int, hasSymbols: Bool) {
        centerRadius = Self.centerRadius
        guard count > 0 else { rings = []; petals = []; return }

        let thickness: CGFloat = hasSymbols ? 60 : 50
        let minArc: CGFloat = hasSymbols ? 64 : 54     // minimum arc length per petal at mid radius
        let firstInner = centerRadius + 8

        func ringFor(inner minInner: CGFloat, count n: Int) -> Ring {
            // Grow the radius if the petals would get too narrow.
            let neededMid = minArc * CGFloat(n) / (2 * .pi)
            let inner = max(minInner, neededMid - thickness / 2)
            return Ring(inner: inner, outer: inner + thickness, count: n)
        }

        var rs: [Ring] = []
        if count <= Self.maxInnerRingCount {
            rs = [ringFor(inner: firstInner, count: count)]
        } else {
            // Split proportionally to circumference so petals have similar arc lengths.
            let mid1 = firstInner + thickness / 2
            let mid2 = firstInner + thickness + Self.ringSpacing + thickness / 2
            var n1 = Int((CGFloat(count) * mid1 / (mid1 + mid2)).rounded())
            n1 = min(Self.maxInnerRingCount, max(4, n1))
            let r1 = ringFor(inner: firstInner, count: n1)
            let r2 = ringFor(inner: r1.outer + Self.ringSpacing, count: count - n1)
            rs = [r1, r2]
        }
        rings = rs

        var ps: [Petal] = []
        var index = 0
        for (ri, ring) in rs.enumerated() {
            let span = ring.span
            // Petal 0 centred at the top, proceeding clockwise. The outer ring is offset by half a petal
            // so its seams don't line up with the inner ring's.
            let offset: CGFloat = ring.rotation + ((ri % 2 == 1) ? span / 2 : 0)
            for i in 0..<ring.count {
                let centre = .pi / 2 - CGFloat(i) * span - offset
                ps.append(Petal(index: index, ring: ri,
                                startAngle: centre - span / 2, endAngle: centre + span / 2,
                                inner: ring.inner, outer: ring.outer))
                index += 1
            }
        }
        petals = ps
    }

    /// Petal under `p` (point relative to the fan centre), or nil.
    func petalIndex(at p: CGPoint) -> Int? {
        let r = hypot(p.x, p.y)
        guard r > centerRadius + 2 else { return nil }
        var base = 0
        for (ri, ring) in rings.enumerated() {
            let lower = ri == 0 ? centerRadius + 2 : ring.inner - Self.ringSpacing / 2
            let upper = ri == rings.count - 1 ? ring.outer + 14 : ring.outer + Self.ringSpacing / 2
            if r >= lower && r < upper {
                let offset: CGFloat = ring.rotation + ((ri % 2 == 1) ? ring.span / 2 : 0)
                var rel = (.pi / 2 - offset) - atan2(p.y, p.x)
                rel = rel.truncatingRemainder(dividingBy: 2 * .pi)
                if rel < 0 { rel += 2 * .pi }
                let i = Int((rel / ring.span + 0.5).rounded(.down)) % ring.slots
                return i < ring.count ? base + i : nil
            }
            base += ring.count
        }
        return nil
    }

    // MARK: Paths

    /// Rounded annular sector path for a petal, centred at `c`.
    static func path(for petal: Petal, center c: CGPoint, grow: CGFloat = 0) -> CGPath {
        let inner = petal.inner
        let outer = petal.outer + grow
        let r = cornerRadius
        let shrunk = sector(center: c, inner: inner + r, outer: outer - r,
                            start: petal.startAngle, end: petal.endAngle, gap: gap + 2 * r)
        let stroke = shrunk.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return shrunk.union(stroke)
    }

    /// Sharp annular sector with a constant-width straight gap on each side.
    static func sector(center c: CGPoint, inner: CGFloat, outer: CGFloat,
                       start: CGFloat, end: CGFloat, gap: CGFloat) -> CGPath {
        let half = gap / 2
        let dO = asin(min(1, half / max(outer, 1)))
        let dI = asin(min(1, half / max(inner, 1)))
        let p = CGMutablePath()
        let span = end - start
        if span - 2 * dI <= 0.001 {
            // Too narrow for the inner arc: degenerate to a wedge tip.
            let a = (start + end) / 2
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
        } else {
            p.move(to: CGPoint(x: c.x + cos(start + dI) * inner, y: c.y + sin(start + dI) * inner))
        }
        p.addArc(center: c, radius: outer, startAngle: start + dO, endAngle: end - dO, clockwise: false)
        if span - 2 * dI > 0.001 {
            p.addArc(center: c, radius: inner, startAngle: end - dI, endAngle: start + dI, clockwise: true)
        }
        p.closeSubpath()
        return p
    }
}
