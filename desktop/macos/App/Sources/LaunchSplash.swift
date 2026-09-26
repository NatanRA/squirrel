import SwiftUI

/// The launch animation: the squirrel hops up, fluffs out its tail, tilts its head and gives a
/// little hop of joy, then the app appears. About a second; tap to skip. With Reduce Motion it
/// shows the finished pose briefly instead. LaunchSplash.kt (Android, Windows) mirrors it.
struct LaunchSplash: View {
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set when the splash first appears: app startup can hold up the first frame, and the
    /// animation shouldn't run on while nothing is drawn.
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            let t = reduceMotion ? SquirrelMotion.duration : start.map { timeline.date.timeIntervalSince($0) } ?? 0
            let wordmark = SquirrelMotion.wordmark(t)
            VStack(spacing: 6) {
                SquirrelCanvas(time: t, background: background)
                    .frame(width: 190, height: 190)
                Text("Squirrel")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(argb: colorScheme == .dark ? 0xFFF2976F : 0xFFA8461F))
                    .opacity(wordmark)
                    .offset(y: 10 * (1 - wordmark))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFinished)
        .onAppear { start = .now }
        .task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.5 : SquirrelMotion.duration))
            onFinished()
        }
    }

    private var background: Color {
        Color(argb: colorScheme == .dark ? 0xFF1E1712 : 0xFFFFF7F0)
    }
}

/// The launch animation's timeline, in seconds: where each part of the squirrel is at time `t`.
enum SquirrelMotion {
    static let duration = 1.15

    /// Rises from below with a fade, overshoots, and lands with a squash.
    static func hop(_ t: Double) -> (y: Double, scaleX: Double, scaleY: Double, alpha: Double) {
        let y = t < 0.3 ? mix(70, -12, easeOut(progress(t, 0, 0.3))) : mix(-12, 0, easeIn(progress(t, 0.3, 0.4)))
        let squash = t < 0.48 ? easeOut(progress(t, 0.4, 0.48)) : 1 - progress(t, 0.48, 0.56)
        return (y, 1 + 0.06 * squash, 1 - 0.07 * squash, progress(t, 0, 0.15))
    }

    /// Grows out from its base while swinging up, overshoots, and settles.
    static func tail(_ t: Double) -> (scale: Double, degrees: Double, alpha: Double) {
        let grow = easeOut(progress(t, 0.12, 0.42))
        let settle = progress(t, 0.42, 0.52)
        return (mix(mix(0.2, 1.08, grow), 1, settle), mix(mix(-35, 6, grow), 0, settle), progress(t, 0.12, 0.2))
    }

    static func headDegrees(_ t: Double) -> Double {
        -8 * easeOut(progress(t, 0.6, 0.72)) + 8 * easeInOut(progress(t, 0.86, 0.98))
    }

    /// Body and hands only, so the head stays put while it hops.
    static func joy(_ t: Double) -> Double {
        -5 * easeOut(progress(t, 0.68, 0.76)) + 5 * easeIn(progress(t, 0.76, 0.84))
    }

    static func earDegrees(_ t: Double) -> Double {
        if t < 0.9 { return 14 * easeOut(progress(t, 0.86, 0.9)) }
        if t < 0.95 { return mix(14, -5, progress(t, 0.9, 0.95)) }
        return mix(-5, 0, progress(t, 0.95, 1))
    }

    static func wordmark(_ t: Double) -> Double { easeOut(progress(t, 0.45, 0.7)) }

    private static func progress(_ t: Double, _ from: Double, _ to: Double) -> Double {
        min(max((t - from) / (to - from), 0), 1)
    }
    private static func mix(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private static func easeIn(_ x: Double) -> Double { x * x * x }
    private static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
}

/// The squirrel from SquirrelArt, posed for time `t` of the launch animation.
struct SquirrelCanvas: View {
    let time: Double
    /// Behind the squirrel; also the colour of the outline that separates head and body from the tail.
    let background: Color

    var body: some View {
        Canvas { context, size in
            let t = time
            context.scaleBy(x: size.width / 240, y: size.height / 240)
            let hop = SquirrelMotion.hop(t)
            context.opacity = hop.alpha
            context.translateBy(x: 0, y: hop.y)
            context.transform(scaleX: hop.scaleX, y: hop.scaleY, around: SquirrelArt.allPivot)

            let tail = SquirrelMotion.tail(t)
            var tailContext = context
            tailContext.opacity = hop.alpha * tail.alpha
            tailContext.transform(degrees: tail.degrees, scale: tail.scale, around: SquirrelArt.tailPivot)
            draw(SquirrelArt.tail, in: tailContext)

            var body = context
            body.translateBy(x: 0, y: SquirrelMotion.joy(t))
            outline(SquirrelArt.bodyOutlinePaths, in: body)
            draw(SquirrelArt.body, in: body)

            var head = context
            head.transform(degrees: SquirrelMotion.headDegrees(t), scale: 1, around: SquirrelArt.headPivot)
            outline(SquirrelArt.headOutlinePaths, in: head)
            var ear = head
            ear.transform(degrees: SquirrelMotion.earDegrees(t), scale: 1, around: SquirrelArt.earPivot)
            draw(SquirrelArt.ear, in: ear)
            draw(SquirrelArt.head, in: head)

            var hands = context
            hands.translateBy(x: 0, y: SquirrelMotion.joy(t))
            draw(SquirrelArt.hands, in: hands)
        }
    }

    private func draw(_ shapes: [SquirrelShape], in context: GraphicsContext) {
        for shape in shapes {
            if let fill = shape.fill {
                context.fill(shape.path, with: .color(fill))
            }
            if let stroke = shape.stroke {
                context.stroke(shape.path, with: .color(stroke), style: StrokeStyle(lineWidth: shape.width, lineCap: .round))
            }
        }
    }

    private func outline(_ paths: [Path], in context: GraphicsContext) {
        for path in paths {
            context.fill(path, with: .color(background))
            context.stroke(path, with: .color(background),
                           style: StrokeStyle(lineWidth: SquirrelArt.outlineWidth, lineJoin: .round))
        }
    }
}

/// One filled or stroked shape of SquirrelArt.
struct SquirrelShape {
    let path: Path
    var fill: Color?
    var stroke: Color?
    var width: CGFloat = 0

    init(_ d: String, fill: UInt32, alpha: Double = 1) {
        path = Path(svgPath: d)
        self.fill = Color(argb: fill).opacity(alpha)
    }

    init(_ d: String, stroke: UInt32, width: CGFloat) {
        path = Path(svgPath: d)
        self.stroke = Color(argb: stroke)
        self.width = width
    }
}

extension SquirrelArt {
    static let bodyOutlinePaths = bodyOutline.map(Path.init(svgPath:))
    static let headOutlinePaths = headOutline.map(Path.init(svgPath:))
}

extension Path {
    /// Absolute M, L, Q, C and Z commands separated by spaces, as branding/squirrel.py writes them.
    init(svgPath d: String) {
        self.init()
        let tokens = d.split(separator: " ")
        var i = 0
        func point() -> CGPoint {
            defer { i += 2 }
            return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
        }
        while i < tokens.count {
            let command = tokens[i]
            i += 1
            switch command {
            case "M": move(to: point())
            case "L": addLine(to: point())
            case "Q":
                let control = point()
                addQuadCurve(to: point(), control: control)
            case "C":
                let control1 = point()
                let control2 = point()
                addCurve(to: point(), control1: control1, control2: control2)
            case "Z": closeSubpath()
            default: break
            }
        }
    }
}

extension Color {
    /// 0xAARRGGBB
    init(argb: UInt32) {
        self.init(.sRGB,
                  red: Double((argb >> 16) & 0xFF) / 255,
                  green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255,
                  opacity: Double((argb >> 24) & 0xFF) / 255)
    }
}

private extension GraphicsContext {
    mutating func transform(scaleX: Double, y scaleY: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y)
        scaleBy(x: scaleX, y: scaleY)
        translateBy(x: -pivot.x, y: -pivot.y)
    }

    mutating func transform(degrees: Double, scale: Double, around pivot: CGPoint) {
        translateBy(x: pivot.x, y: pivot.y)
        rotate(by: .degrees(degrees))
        scaleBy(x: scale, y: scale)
        translateBy(x: -pivot.x, y: -pivot.y)
    }
}
