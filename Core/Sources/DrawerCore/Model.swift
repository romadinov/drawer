import Foundation

// MARK: - Persistent document state

/// Everything that is saved in a `.drawer` file.
///
/// The spec text is the source of truth for *what* is in the diagram (elements,
/// relationships, labels). The drawing owns *where* things are and how they look
/// (positions, sizes, waypoints, colours) plus free-form decorations that have
/// no equivalent in PlantUML or Mermaid.
public struct DrawingState: Codable, Equatable, Sendable {
    public var language: SpecLanguage
    public var spec: String
    public var layout: [String: NodeLayout]
    public var edgeLayout: [String: EdgeLayout]
    public var styles: [String: ElementStyle]
    public var decorations: [Decoration]

    public init(
        language: SpecLanguage = .plantUML,
        spec: String = "",
        layout: [String: NodeLayout] = [:],
        edgeLayout: [String: EdgeLayout] = [:],
        styles: [String: ElementStyle] = [:],
        decorations: [Decoration] = []
    ) {
        self.language = language
        self.spec = spec
        self.layout = layout
        self.edgeLayout = edgeLayout
        self.styles = styles
        self.decorations = decorations
    }
}

public enum SpecLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case plantUML
    case mermaid

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .plantUML: "PlantUML"
        case .mermaid: "Mermaid"
        }
    }
    public var fileExtension: String {
        switch self {
        case .plantUML: "puml"
        case .mermaid: "mmd"
        }
    }
}

public struct Point: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
}

public struct Size: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct Rect: Codable, Equatable, Hashable, Sendable {
    public var origin: Point
    public var size: Size
    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x: x, y: y)
        size = Size(width: width, height: height)
    }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var center: Point { Point(x: midX, y: midY) }

    public func union(_ other: Rect) -> Rect {
        let x0 = min(minX, other.minX), y0 = min(minY, other.minY)
        let x1 = max(maxX, other.maxX), y1 = max(maxY, other.maxY)
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    public func insetBy(_ d: Double) -> Rect {
        Rect(x: minX + d, y: minY + d, width: size.width - 2 * d, height: size.height - 2 * d)
    }
    public func intersects(_ o: Rect) -> Bool {
        minX < o.maxX && o.minX < maxX && minY < o.maxY && o.minY < maxY
    }
    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

/// Position of a node (top-left corner) and an optional user-chosen size.
/// When `size` is nil the node uses its intrinsic size computed from its text.
public struct NodeLayout: Codable, Equatable, Sendable {
    public var position: Point
    public var size: Size?
    public init(position: Point, size: Size? = nil) {
        self.position = position
        self.size = size
    }
}

public enum EdgeRouting: String, Codable, CaseIterable, Sendable {
    case straight, orthogonal, curved
}

public struct EdgeLayout: Codable, Equatable, Sendable {
    public var waypoints: [Point]
    public var routing: EdgeRouting
    public var labelOffset: Point
    /// Sequence diagrams: extra vertical space above this message.
    public var extraSpacing: Double?
    public init(waypoints: [Point] = [], routing: EdgeRouting = .straight, labelOffset: Point = .zero, extraSpacing: Double? = nil) {
        self.waypoints = waypoints
        self.routing = routing
        self.labelOffset = labelOffset
        self.extraSpacing = extraSpacing
    }
}

/// Colours are stored as `#RRGGBB` (or `#RRGGBBAA`) strings.
public struct ElementStyle: Codable, Equatable, Sendable {
    public var fill: String?
    public var stroke: String?
    public var text: String?
    public var lineWidth: Double?
    public var dashed: Bool?
    public init(fill: String? = nil, stroke: String? = nil, text: String? = nil, lineWidth: Double? = nil, dashed: Bool? = nil) {
        self.fill = fill
        self.stroke = stroke
        self.text = text
        self.lineWidth = lineWidth
        self.dashed = dashed
    }
    public var isEmpty: Bool { fill == nil && stroke == nil && text == nil && lineWidth == nil && dashed == nil }
}

/// Free-form embellishment that exists only in the drawing.
public struct Decoration: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, rectangle, roundedRectangle, ellipse, line, arrow, note
    }
    public var id: UUID
    public var kind: Kind
    /// For lines/arrows the frame's origin is the start point and origin+size the end point (size may be negative).
    public var frame: Rect
    public var text: String
    public var fontSize: Double
    public var style: ElementStyle

    public init(id: UUID = UUID(), kind: Kind, frame: Rect, text: String = "", fontSize: Double = 13, style: ElementStyle = ElementStyle()) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.text = text
        self.fontSize = fontSize
        self.style = style
    }
}

// MARK: - Parsed (derived) model

public enum DiagramFamily: String, Sendable, CaseIterable {
    case flowchart   // Mermaid flowchart / PlantUML component, deployment, use case
    case classDiagram
    case erDiagram
    case c4
    case sequence

    public var displayName: String {
        switch self {
        case .flowchart: "Flow / Component"
        case .classDiagram: "UML Class"
        case .erDiagram: "Entity-Relationship"
        case .c4: "C4"
        case .sequence: "Sequence"
        }
    }
}

public enum Direction: String, Sendable {
    case topDown, leftRight, bottomUp, rightLeft
    public var isHorizontal: Bool { self == .leftRight || self == .rightLeft }
}

public enum NodeKind: String, Codable, Sendable, CaseIterable {
    // generic shapes
    case box, rounded, stadium, circle, diamond, hexagon, parallelogram, database, queue, cloud, folder, note, actor, usecase, component, node, artifact
    // UML
    case classType, interfaceType, abstractClass, enumType
    // ER
    case entity
    // C4
    case person, personExt, system, systemExt, systemDb, systemDbExt, systemQueue, container, containerExt, containerDb, containerDbExt, containerQueue, component4, component4Ext, component4Db, component4Queue
    // sequence participants
    case participant, seqBoundary, seqControl, seqEntity, collections
    // groups
    case group, boundary

    public var isGroup: Bool { self == .group || self == .boundary }
    public var isClassifier: Bool { [.classType, .interfaceType, .abstractClass, .enumType].contains(self) }
    public var isC4: Bool {
        switch self {
        case .person, .personExt, .system, .systemExt, .systemDb, .systemDbExt, .systemQueue, .container, .containerExt, .containerDb, .containerDbExt, .containerQueue, .component4, .component4Ext, .component4Db, .component4Queue: true
        default: false
        }
    }
    public var isC4External: Bool { [.personExt, .systemExt, .systemDbExt, .containerExt, .containerDbExt, .component4Ext].contains(self) }
    public var isCylinder: Bool { [.database, .systemDb, .systemDbExt, .containerDb, .containerDbExt, .component4Db].contains(self) }
    public var isQueueShape: Bool { [.queue, .systemQueue, .containerQueue, .component4Queue].contains(self) }
    /// Drawn as an icon with the label underneath (stick figure, boundary/control/entity circles).
    public var isIconWithLabel: Bool { [.actor, .seqBoundary, .seqControl, .seqEntity].contains(self) }

    public var displayName: String {
        switch self {
        case .box: "Box"
        case .rounded: "Rounded Box"
        case .stadium: "Stadium"
        case .circle: "Circle"
        case .diamond: "Decision"
        case .hexagon: "Hexagon"
        case .parallelogram: "Parallelogram"
        case .database: "Database"
        case .queue: "Queue"
        case .cloud: "Cloud"
        case .folder: "Folder"
        case .note: "Note"
        case .actor: "Actor"
        case .usecase: "Use Case"
        case .component: "Component"
        case .node: "Node"
        case .artifact: "Artifact"
        case .classType: "Class"
        case .interfaceType: "Interface"
        case .abstractClass: "Abstract Class"
        case .enumType: "Enum"
        case .entity: "Entity"
        case .person: "Person"
        case .personExt: "External Person"
        case .system: "Software System"
        case .systemExt: "External System"
        case .systemDb: "System Database"
        case .systemDbExt: "External System DB"
        case .systemQueue: "System Queue"
        case .container: "Container"
        case .containerExt: "External Container"
        case .containerDb: "Container Database"
        case .containerDbExt: "External Container DB"
        case .containerQueue: "Container Queue"
        case .component4: "C4 Component"
        case .component4Ext: "External C4 Component"
        case .component4Db: "C4 Component DB"
        case .component4Queue: "C4 Component Queue"
        case .participant: "Participant"
        case .seqBoundary: "Boundary"
        case .seqControl: "Control"
        case .seqEntity: "Entity"
        case .collections: "Collections"
        case .group: "Group"
        case .boundary: "Boundary"
        }
    }

    /// The C4 "[Type]" caption shown under the title.
    public var c4Caption: String? {
        switch self {
        case .person, .personExt: "Person"
        case .system, .systemDb, .systemQueue: "Software System"
        case .systemExt, .systemDbExt: "External System"
        case .container, .containerDb, .containerQueue: "Container"
        case .containerExt, .containerDbExt: "External Container"
        case .component4, .component4Db, .component4Queue: "Component"
        case .component4Ext: "External Component"
        default: nil
        }
    }

    /// Kinds offered in the "add" palette for a family.
    public static func palette(for family: DiagramFamily, language: SpecLanguage) -> [NodeKind] {
        switch family {
        case .flowchart:
            switch language {
            case .mermaid: return [.box, .rounded, .stadium, .circle, .diamond, .hexagon, .parallelogram, .database]
            case .plantUML: return [.component, .rounded, .database, .queue, .actor, .usecase, .node, .cloud, .folder, .artifact, .note]
            }
        case .classDiagram: return [.classType, .interfaceType, .abstractClass, .enumType]
        case .erDiagram: return [.entity]
        case .c4: return [.person, .personExt, .system, .systemExt, .systemDb, .container, .containerDb, .containerQueue, .containerExt, .component4, .component4Db]
        case .sequence:
            switch language {
            case .mermaid: return [.participant, .actor]
            case .plantUML: return [.participant, .actor, .database, .queue, .collections, .seqBoundary, .seqControl, .seqEntity]
            }
        }
    }
}

public enum EdgeLineStyle: String, Codable, Sendable {
    case solid, dashed, dotted, thick, invisible
}

public enum EdgeMarker: String, Codable, Sendable, CaseIterable {
    case none
    case arrow          // open "V" arrow
    case filledArrow    // solid triangle (flowchart / C4)
    case triangle       // hollow triangle (inheritance / realisation)
    case diamond        // hollow diamond (aggregation)
    case filledDiamond  // composition
    case circle
    case cross
    // crow's foot (ER)
    case exactlyOne, zeroOrOne, oneOrMany, zeroOrMany
}

public struct SourceSpan: Equatable, Sendable {
    /// UTF-16 offsets into the spec string, half open.
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var end: Int { location + length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
    public func contains(_ offset: Int) -> Bool { offset >= location && offset <= end }
    public func union(_ o: SourceSpan) -> SourceSpan {
        let s = min(location, o.location), e = max(end, o.end)
        return SourceSpan(location: s, length: e - s)
    }
}

public struct DiagramNode: Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: NodeKind
    public var title: String
    public var stereotype: String?
    public var technology: String?
    public var description: String?
    /// Attributes / fields (UML) or columns (ER).
    public var fields: [String]
    /// Operations (UML).
    public var methods: [String]
    public var parent: String?

    /// Lines that *declare* this node (standalone declaration or block). Nil when only referenced from relationships.
    public var declarationSpan: SourceSpan?
    /// True when the declaration line(s) contain nothing but this node's declaration.
    public var declarationIsStandalone: Bool
    /// Range of the title text inside the spec, when the title can be rewritten in place.
    public var titleSpan: SourceSpan?
    /// True when the title is the identifier itself (no separate label).
    public var titleIsIdentifier: Bool
    /// Every place this node is mentioned (for caret → selection mapping).
    public var referenceSpans: [SourceSpan]

    public init(id: String, kind: NodeKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
        fields = []
        methods = []
        declarationIsStandalone = false
        titleIsIdentifier = true
        referenceSpans = []
    }
}

public struct DiagramEdge: Equatable, Sendable, Identifiable {
    public var id: String
    public var from: String
    public var to: String
    public var label: String?
    public var technology: String?
    public var fromLabel: String?
    public var toLabel: String?
    public var line: EdgeLineStyle
    public var startMarker: EdgeMarker
    public var endMarker: EdgeMarker
    /// The whole line(s) the edge was declared on.
    public var span: SourceSpan?
    /// True if that line declares only this edge (no chains, no inline node labels we'd lose).
    public var spanIsStandalone: Bool
    public var labelSpan: SourceSpan?

    public init(id: String = "", from: String, to: String, line: EdgeLineStyle = .solid, startMarker: EdgeMarker = .none, endMarker: EdgeMarker = .arrow) {
        self.id = id
        self.from = from
        self.to = to
        self.line = line
        self.startMarker = startMarker
        self.endMarker = endMarker
        spanIsStandalone = false
    }
}

public struct Diagnostic: Equatable, Sendable {
    public enum Severity: Sendable { case warning, error }
    public var line: Int
    public var message: String
    public var severity: Severity
    public init(line: Int, message: String, severity: Severity = .warning) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

// MARK: Sequence diagrams

public struct SequenceEvent: Equatable, Sendable {
    public enum NotePosition: String, Sendable { case left, right, over }
    public enum Kind: Equatable, Sendable {
        /// Index into `ParsedDiagram.edges`.
        case message(Int, activateTarget: Bool, deactivateSource: Bool)
        case note(String, participants: [String], position: NotePosition)
        case divider(String)
        case delay(String?)
        case spacer
        case fragmentStart(kind: String, label: String)
        case fragmentElse(label: String)
        case fragmentEnd
        case activate(String)
        case deactivate(String)
    }
    public var kind: Kind
    public var span: SourceSpan
    public init(_ kind: Kind, span: SourceSpan) { self.kind = kind; self.span = span }
}

public struct SequenceInfo: Equatable, Sendable {
    public var events: [SequenceEvent] = []
    public var autonumber = false
    public init() {}
}

public struct ParsedDiagram: Equatable, Sendable {
    public var family: DiagramFamily
    public var sequence: SequenceInfo?
    public var direction: Direction
    public var title: String?
    public var nodes: [DiagramNode]
    public var edges: [DiagramEdge]
    public var diagnostics: [Diagnostic]
    /// Offset where new statements should be inserted (e.g. before `@enduml`).
    public var insertionOffset: Int

    public init(family: DiagramFamily, direction: Direction = .topDown) {
        self.family = family
        self.direction = direction
        nodes = []
        edges = []
        diagnostics = []
        insertionOffset = 0
    }

    public func node(_ id: String) -> DiagramNode? { nodes.first { $0.id == id } }
    public func edge(_ id: String) -> DiagramEdge? { edges.first { $0.id == id } }
    public func children(of id: String) -> [DiagramNode] { nodes.filter { $0.parent == id } }

    /// All descendants of a group (recursive).
    public func descendants(of id: String) -> [DiagramNode] {
        var result: [DiagramNode] = []
        var stack = [id]
        while let current = stack.popLast() {
            for child in children(of: current) {
                result.append(child)
                stack.append(child.id)
            }
        }
        return result
    }

    public static let empty = ParsedDiagram(family: .flowchart)
}
