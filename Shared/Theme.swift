import DrawerCore
#if os(macOS)
import AppKit

var currentGraphicsContext: CGContext? { NSGraphicsContext.current?.cgContext }
/// CoreGraphics shadow offsets are in device space, which points up on the Mac.
let shadowOffsetDown: CGFloat = -1
#else
import UIKit

// AppKit names for the UIKit types the shared drawing code uses.
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSBezierPath = UIBezierPath

var currentGraphicsContext: CGContext? { UIGraphicsGetCurrentContext() }
let shadowOffsetDown: CGFloat = 1

extension UIColor {
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(red: r, green: g, blue: b, alpha: a) }
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var controlAccentColor: UIColor { .systemBlue }
}

extension UIBezierPath {
    convenience init(roundedRect rect: CGRect, xRadius: CGFloat, yRadius: CGFloat) { self.init(roundedRect: rect, cornerRadius: xRadius) }
    func line(to p: CGPoint) { addLine(to: p) }
    func curve(to p: CGPoint, controlPoint1 c1: CGPoint, controlPoint2 c2: CGPoint) { addCurve(to: p, controlPoint1: c1, controlPoint2: c2) }
}
#endif

enum Fonts {
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12)
    static let caption = NSFont.systemFont(ofSize: 10.5)
    static let member = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let edgeLabel = NSFont.systemFont(ofSize: 11)
    static let groupTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)

    static func italic(_ font: NSFont) -> NSFont {
        #if os(macOS)
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        #else
        font.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        #endif
    }

    static func font(for role: TextRole) -> NSFont {
        switch role {
        case .title: title
        case .body: body
        case .caption: caption
        case .member: member
        case .edgeLabel: edgeLabel
        }
    }
}

/// Font-accurate text measurement shared by geometry and rendering.
let appMeasurer: TextMeasurer = { text, role, maxWidth in
    let font = Fonts.font(for: role)
    let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
    let bounds = s.boundingRect(with: CGSize(width: maxWidth ?? 10_000, height: 10_000),
                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return Size(width: ceil(bounds.width), height: ceil(bounds.height))
}

extension NSColor {
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255; a = 1
        } else {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255; b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        var rf: CGFloat = 0, gf: CGFloat = 0, bf: CGFloat = 0, af: CGFloat = 0
        #if os(macOS)
        (usingColorSpace(.sRGB) ?? self).getRed(&rf, green: &gf, blue: &bf, alpha: &af)
        #else
        getRed(&rf, green: &gf, blue: &bf, alpha: &af)
        #endif
        let r = Int((rf * 255).rounded()), g = Int((gf * 255).rounded()), b = Int((bf * 255).rounded())
        let a = Int((af * 255).rounded())
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
        #else
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        #endif
    }
}

extension CGPoint {
    init(_ p: Point) { self.init(x: p.x, y: p.y) }
    var point: Point { Point(x: x, y: y) }
}

extension CGRect {
    init(_ r: Rect) { self.init(x: r.minX, y: r.minY, width: r.size.width, height: r.size.height) }
    var rect: Rect { Rect(x: minX, y: minY, width: width, height: height) }
}

/// Default colours for each element kind (light / dark).
struct NodePalette {
    var fill: NSColor
    var stroke: NSColor
    var text: NSColor
    var secondaryText: NSColor

    static let canvas = NSColor.dynamic(light: NSColor(srgbRed: 0.975, green: 0.976, blue: 0.98, alpha: 1),
                                        dark: NSColor(srgbRed: 0.11, green: 0.115, blue: 0.125, alpha: 1))
    static let grid = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.06))
    static let edge = NSColor.dynamic(light: NSColor(white: 0.30, alpha: 1), dark: NSColor(white: 0.72, alpha: 1))
    static let selection = NSColor.controlAccentColor

    static func `for`(_ kind: NodeKind) -> NodePalette {
        let white = NSColor.white
        let ink = NSColor.dynamic(light: NSColor(white: 0.12, alpha: 1), dark: NSColor(white: 0.92, alpha: 1))
        let subInk = NSColor.dynamic(light: NSColor(white: 0.38, alpha: 1), dark: NSColor(white: 0.66, alpha: 1))
        func c4(_ hex: String, stroke: String, text: NSColor = white) -> NodePalette {
            NodePalette(fill: NSColor(hex: hex)!, stroke: NSColor(hex: stroke)!, text: text, secondaryText: text.withAlphaComponent(0.85))
        }
        switch kind {
        case .person: return c4("#08427B", stroke: "#073B6F")
        case .personExt: return c4("#686868", stroke: "#4D4D4D")
        case .system, .systemDb, .systemQueue: return c4("#1168BD", stroke: "#3C7FC0")
        case .systemExt, .systemDbExt: return c4("#999999", stroke: "#8A8A8A")
        case .container, .containerDb, .containerQueue: return c4("#438DD5", stroke: "#3C7FC0")
        case .containerExt, .containerDbExt: return c4("#B3B3B3", stroke: "#A6A6A6")
        case .component4, .component4Db, .component4Queue: return c4("#85BBF0", stroke: "#78A8D8", text: NSColor(white: 0.05, alpha: 1))
        case .component4Ext: return c4("#CCCCCC", stroke: "#BFBFBF", text: NSColor(white: 0.05, alpha: 1))
        case .classType, .interfaceType, .abstractClass, .enumType:
            return NodePalette(fill: .dynamic(light: NSColor(hex: "#FFFBEA")!, dark: NSColor(hex: "#36321F")!),
                               stroke: .dynamic(light: NSColor(hex: "#A38A3A")!, dark: NSColor(hex: "#B39A50")!), text: ink, secondaryText: subInk)
        case .entity:
            return NodePalette(fill: .dynamic(light: NSColor(hex: "#F0F6FF")!, dark: NSColor(hex: "#1F2A3A")!),
                               stroke: .dynamic(light: NSColor(hex: "#4A78B5")!, dark: NSColor(hex: "#6B97D1")!), text: ink, secondaryText: subInk)
        case .group, .boundary:
            return NodePalette(fill: .dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.03)),
                               stroke: .dynamic(light: NSColor(white: 0.45, alpha: 1), dark: NSColor(white: 0.6, alpha: 1)), text: ink, secondaryText: subInk)
        case .note:
            return NodePalette(fill: NSColor(hex: "#FFF6B3")!, stroke: NSColor(hex: "#C9B458")!, text: NSColor(white: 0.1, alpha: 1), secondaryText: NSColor(white: 0.3, alpha: 1))
        case .actor, .seqBoundary, .seqControl, .seqEntity:
            return NodePalette(fill: .clear, stroke: ink, text: ink, secondaryText: subInk)
        default:
            return NodePalette(fill: .dynamic(light: .white, dark: NSColor(hex: "#2A2D33")!),
                               stroke: .dynamic(light: NSColor(hex: "#5A6B80")!, dark: NSColor(hex: "#8193A8")!), text: ink, secondaryText: subInk)
        }
    }
}
