import Foundation

/// Finds the near-vertical and near-horizontal straight lines of a photo (building edges, door frames, horizons),
/// for Upright's "Level" and "Vertical". Pure and deterministic: a normalised Sobel gradient, then a Hough transform
/// restricted to two angle windows (within `windowDegrees` of vertical and of horizontal), peak by peak: take the
/// strongest accumulator cell, fit a straight line to the edge pixels that support it (total least squares, so the
/// angle is not limited by the accumulator's step), remove those pixels' votes, repeat. No Vision, so no flakiness.
///
/// Coordinates: the image is top-down (row 0 = top), and every line is expressed about the image CENTRE with y pointing
/// DOWN, as `x * cos(theta) + y * sin(theta) = rho` (`theta` is the angle of the line's normal). A near-vertical line has
/// `theta` near 0, a near-horizontal one near 90 degrees.
///
/// Meant for a downscaled proxy (about 768 px on the long side, `UprightDetector`): the work grows with the number of
/// edge pixels times the vote window.
enum UprightLineDetector {
    /// One detected line.
    struct Line: Equatable {
        /// Normal angle, radians (see the type's comment).
        let theta: Double
        let rho: Double
        /// Length in pixels the supporting edge pixels actually cover (solid runs, see `coverage`; scattered pixels or a
        /// dashed line cover far less than their end-to-end distance).
        let span: Double
        /// Number of supporting edge pixels.
        let votes: Int
    }

    /// Everything found in one image, in the proxy's own pixel units.
    struct Lines: Equatable {
        let width: Int
        let height: Int
        /// Within `windowDegrees` of vertical (`theta` near 0).
        let vertical: [Line]
        /// Within `windowDegrees` of horizontal (`theta` near 90 degrees).
        let horizontal: [Line]
    }

    /// Half-width of each family's angle window.
    static let windowDegrees = 30.0
    /// Accumulator step in theta.
    static let thetaStepDegrees = 0.25
    /// An edge pixel votes for the thetas within this many degrees of its own gradient direction.
    static let voteHalfWidthDegrees = 2.5
    /// A line must cover at least this fraction of the image's side along its family's axis (height for vertical
    /// lines, width for horizontal ones).
    static let minLengthFraction = 0.12
    /// Pixels along a line more than this fraction of the axis apart do not count as one continuous stretch.
    static let maxGapFraction = 0.01
    /// At least this fraction of the 1 px steps between a line's two ends must hold an edge pixel.
    static let minFill = 0.6
    /// At most this many lines per family.
    static let maxLinesPerFamily = 12

    // MARK: - Detection

    static func detect(in gray: FeatureMatcher.GrayImage) -> Lines {
        let edges = edgePixels(in: gray)
        let vertical = findLines(edges: edges, width: gray.width, height: gray.height, axisAngle: 0, axisLength: Double(gray.height))
        let horizontal = findLines(
            edges: edges, width: gray.width, height: gray.height, axisAngle: .pi / 2, axisLength: Double(gray.width))
        return Lines(width: gray.width, height: gray.height, vertical: vertical, horizontal: horizontal)
    }

    // MARK: - Edges

    private struct Edges {
        var x: [Float] = []
        var y: [Float] = []
        /// Gradient direction (the edge's normal), radians in [0, pi).
        var angle: [Float] = []
        var count: Int { x.count }
    }

    /// Pixels whose normalised Sobel magnitude (a step of height `d` gives `d`) exceeds a floor and 15% of the strongest.
    private static func edgePixels(in g: FeatureMatcher.GrayImage) -> Edges {
        var edges = Edges()
        let w = g.width, h = g.height
        guard w >= 3, h >= 3 else { return edges }
        var gx = [Float](repeating: 0, count: w * h)
        var gy = gx
        var maxMagnitude: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let a = g.at(x - 1, y - 1), b = g.at(x, y - 1), c = g.at(x + 1, y - 1)
                let d = g.at(x - 1, y), f = g.at(x + 1, y)
                let p = g.at(x - 1, y + 1), q = g.at(x, y + 1), r = g.at(x + 1, y + 1)
                let sx = ((c + 2 * f + r) - (a + 2 * d + p)) / 4
                let sy = ((p + 2 * q + r) - (a + 2 * b + c)) / 4
                gx[y * w + x] = sx
                gy[y * w + x] = sy
                maxMagnitude = max(maxMagnitude, (sx * sx + sy * sy).squareRoot())
            }
        }
        let threshold = max(0.04, 0.15 * maxMagnitude)
        let cx = Float(w) / 2 - 0.5, cy = Float(h) / 2 - 0.5
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let sx = gx[y * w + x], sy = gy[y * w + x]
                guard (sx * sx + sy * sy).squareRoot() >= threshold else { continue }
                var angle = atan2(sy, sx)
                if angle < 0 { angle += .pi }
                if angle >= .pi { angle -= .pi }
                edges.x.append(Float(x) - cx)
                edges.y.append(Float(y) - cy)
                edges.angle.append(angle)
            }
        }
        return edges
    }

    // MARK: - Hough

    private static func findLines(edges: Edges, width: Int, height: Int, axisAngle: Double, axisLength: Double) -> [Line] {
        guard edges.count > 0 else { return [] }
        let window = windowDegrees * .pi / 180
        let step = thetaStepDegrees * .pi / 180
        let voteHalf = Int((voteHalfWidthDegrees / thetaStepDegrees).rounded())
        let binCount = Int((2 * window / step).rounded()) + 1
        var cosines = [Double](repeating: 0, count: binCount)
        var sines = cosines
        for j in 0..<binCount {
            let theta = axisAngle - window + Double(j) * step
            cosines[j] = cos(theta)
            sines[j] = sin(theta)
        }
        let rhoMax = (Double(width * width + height * height)).squareRoot() / 2 + 2
        let rhoBins = Int((2 * rhoMax).rounded(.up)) + 2

        /// The theta bins pixel `i` votes for, or nil when its gradient is outside this family's window.
        func voteRange(_ i: Int) -> ClosedRange<Int>? {
            var d = Double(edges.angle[i]) - axisAngle
            d -= Double.pi * (d / Double.pi).rounded() // wrap into [-pi/2, pi/2]
            guard abs(d) <= window + Double(voteHalf) * step else { return nil }
            let centre = Int(((d + window) / step).rounded())
            let low = max(0, centre - voteHalf), high = min(binCount - 1, centre + voteHalf)
            return low <= high ? low...high : nil
        }
        func rhoIndex(_ i: Int, _ j: Int) -> Int {
            let rho = Double(edges.x[i]) * cosines[j] + Double(edges.y[i]) * sines[j]
            return min(max(Int((rho + rhoMax).rounded()), 0), rhoBins - 1)
        }

        var accumulator = [Int32](repeating: 0, count: binCount * rhoBins)
        var voted = [Bool](repeating: false, count: edges.count)
        for i in 0..<edges.count {
            guard let range = voteRange(i) else { continue }
            voted[i] = true
            for j in range { accumulator[j * rhoBins + rhoIndex(i, j)] += 1 }
        }
        var used = [Bool](repeating: false, count: edges.count)
        let minVotes = Int32(max(8, (minLengthFraction * axisLength).rounded(.up)))
        let minSpan = minLengthFraction * axisLength
        var lines: [Line] = []

        var attempts = 0
        while lines.count < maxLinesPerFamily, attempts < 3 * maxLinesPerFamily {
            attempts += 1
            var bestIndex = 0
            var bestVotes: Int32 = 0
            for index in 0..<accumulator.count where accumulator[index] > bestVotes {
                bestVotes = accumulator[index]
                bestIndex = index
            }
            guard bestVotes >= minVotes else { break }
            var theta = axisAngle - window + Double(bestIndex / rhoBins) * step
            var rho = Double(bestIndex % rhoBins) - rhoMax

            // Refit on the supporting pixels. The band must reach the whole Sobel flank on BOTH sides (about 2.5 px
            // from the line) even while the starting line is a quarter degree off: a band that cuts the flank
            // asymmetrically along the line tilts the fit.
            // `inliers` is always the set the CURRENT theta/rho were fitted from (a failed later pass keeps the last
            // successful one). That fallback has no dedicated test: a later pass starts from a line just fitted to at
            // least 8 pixels with the same band, so it cannot be made to drop below 8 with a drawn image.
            var inliers: [Int] = []
            for (band, angleTolerance) in [(3.4, 6.0), (3.4, 8.0), (3.4, 8.0)] {
                let candidates = supportingPixels(
                    edges: edges, used: used, theta: theta, rho: rho, band: band, angleTolerance: angleTolerance * .pi / 180)
                guard let refit = totalLeastSquares(edges: edges, indices: candidates, axisAngle: axisAngle) else { break }
                theta = refit.theta
                rho = refit.rho
                inliers = candidates
            }
            // The peak cell is consumed whatever happens, so a refused candidate cannot be picked again.
            accumulator[bestIndex] = 0
            guard !inliers.isEmpty else { continue }

            let (covered, longest) = coverage(
                edges: edges, inliers: inliers, theta: theta, maxGap: maxGapFraction * axisLength)
            let accepted = Int32(inliers.count) >= minVotes && longest >= minSpan
                && abs(theta - axisAngle) <= window + step
            // A refused candidate only takes its own votes back (so the same fragment is not picked again); its
            // pixels stay available, so a valid segment that shares them can still be found.
            for i in inliers where voted[i] {
                voted[i] = false
                if let range = voteRange(i) {
                    for j in range { accumulator[j * rhoBins + rhoIndex(i, j)] -= 1 }
                }
            }
            guard accepted else { continue }
            for i in inliers { used[i] = true }
            let duplicate = lines.contains { abs($0.theta - theta) < 1.5 * .pi / 180 && abs($0.rho - rho) < 4 }
            if !duplicate { lines.append(Line(theta: theta, rho: rho, span: covered, votes: inliers.count)) }
        }
        return lines
    }

    /// How much of the line is really there. The pixels' positions along it are sorted and cut into runs wherever
    /// consecutive ones are more than `maxGap` apart; a run is SOLID when it holds an edge pixel in at least
    /// `minFill` of its 1 px steps (so a bundle of short oriented strokes that happen to align is not solid, a real
    /// edge is). `covered` is the summed extent of the solid runs (what `Line.span` reports: stray far pixels and
    /// occlusion gaps neither count nor count against a line) and `longest` the longest solid run (a line needs one
    /// continuous stretch of at least the minimum length, not many tiny ones).
    private static func coverage(edges: Edges, inliers: [Int], theta: Double, maxGap: Double) -> (covered: Double, longest: Double) {
        let dx = -sin(theta), dy = cos(theta)
        let along = inliers.map { Double(edges.x[$0]) * dx + Double(edges.y[$0]) * dy }.sorted()
        guard let first = along.first else { return (0, 0) }
        var covered = 0.0, longest = 0.0
        var runStart = first, previous = first
        var bins = Set<Int>([Int(first.rounded(.down))])
        func close() {
            let extent = previous - runStart
            guard Double(bins.count) >= minFill * (extent + 1) else { return }
            covered += extent
            longest = max(longest, extent)
        }
        for value in along.dropFirst() {
            if value - previous > maxGap {
                close()
                runStart = value
                bins = []
            }
            bins.insert(Int(value.rounded(.down)))
            previous = value
        }
        close()
        return (covered, longest)
    }

    private static func supportingPixels(
        edges: Edges, used: [Bool], theta: Double, rho: Double, band: Double, angleTolerance: Double
    ) -> [Int] {
        let c = cos(theta), s = sin(theta)
        var result: [Int] = []
        for i in 0..<edges.count where !used[i] {
            guard abs(Double(edges.x[i]) * c + Double(edges.y[i]) * s - rho) <= band else { continue }
            var d = Double(edges.angle[i]) - theta
            d -= Double.pi * (d / Double.pi).rounded()
            if abs(d) <= angleTolerance { result.append(i) }
        }
        return result
    }

    /// Total-least-squares line through the pixels: the principal axis of their covariance. Needs at least 8 pixels.
    private static func totalLeastSquares(edges: Edges, indices: [Int], axisAngle: Double) -> (theta: Double, rho: Double)? {
        guard indices.count >= 8 else { return nil }
        var mx = 0.0, my = 0.0
        for i in indices { mx += Double(edges.x[i]); my += Double(edges.y[i]) }
        mx /= Double(indices.count)
        my /= Double(indices.count)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in indices {
            let dx = Double(edges.x[i]) - mx, dy = Double(edges.y[i]) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        guard sxx + syy > 1e-9 else { return nil }
        let directionAngle = 0.5 * atan2(2 * sxy, sxx - syy)
        var theta = directionAngle + .pi / 2
        theta -= Double.pi * ((theta - axisAngle) / Double.pi).rounded() // into (axis - pi/2, axis + pi/2]
        return (theta, mx * cos(theta) + my * sin(theta))
    }
}

extension UprightLineDetector.Line {
    /// How far this line is rotated COUNTER-clockwise (as seen on screen) from its ideal axis, in degrees. A vertical
    /// line whose top leans right is rotated clockwise, so its value is negative; a horizontal line whose right end is
    /// higher is rotated counter-clockwise, so its value is positive.
    var ccwTiltDegrees: Double {
        let axis = abs(theta) < .pi / 4 ? 0.0 : Double.pi / 2
        return -(theta - axis) * 180 / .pi
    }
}
