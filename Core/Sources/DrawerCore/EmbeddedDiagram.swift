import Foundation

/// Stores the editable diagram inside exported images, the way draw.io does, so a PNG or SVG
/// can be opened again in Drawer: an `iTXt` chunk in PNGs, a `<metadata>` element in SVGs.
public enum EmbeddedDiagram {
    static let keyword = "drawer"
    static let namespace = "https://github.com/romadinov/drawer"
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func json(_ state: DrawingState) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(state)) ?? Data()
    }

    /// Reads a diagram from a `.drawer` file, or from a PNG/SVG that has one embedded.
    public static func decode(_ data: Data) -> DrawingState? {
        if data.starts(with: pngSignature) { return fromPNG(data) }
        if let state = try? JSONDecoder().decode(DrawingState.self, from: data) { return state }
        if let text = String(data: data, encoding: .utf8), text.contains("<svg") { return fromSVG(text) }
        return nil
    }

    // MARK: PNG

    /// Adds (or replaces) the diagram chunk right after the PNG header.
    public static func embed(_ state: DrawingState, inPNG png: Data) -> Data {
        var chunks = pngChunks(png).filter { !($0.type == "iTXt" && $0.data.starts(with: Array(keyword.utf8) + [0])) }
        guard let header = chunks.first, header.type == "IHDR" else { return png }
        // keyword, NUL, compression flag 0, method 0, empty language tag + NUL, empty translated keyword + NUL, UTF-8 text.
        var payload = Data(keyword.utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(json(state))
        chunks.insert((type: "iTXt", data: payload), at: 1)
        var out = Data(pngSignature)
        for c in chunks {
            var length = UInt32(c.data.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typeAndData = Data(c.type.utf8) + c.data
            out.append(typeAndData)
            var crc = crc32(typeAndData).bigEndian
            out.append(Data(bytes: &crc, count: 4))
        }
        return out
    }

    public static func fromPNG(_ png: Data) -> DrawingState? {
        let prefix = Array(keyword.utf8) + [0]
        for c in pngChunks(png) where c.type == "iTXt" && c.data.starts(with: prefix) {
            // Skip keyword+NUL, the two flag bytes, then the NUL-terminated language tag and translated keyword.
            var i = c.data.startIndex + prefix.count + 2
            for _ in 0..<2 {
                guard let nul = c.data[i...].firstIndex(of: 0) else { return nil }
                i = nul + 1
            }
            return try? JSONDecoder().decode(DrawingState.self, from: c.data[i...])
        }
        return nil
    }

    static func pngChunks(_ png: Data) -> [(type: String, data: Data)] {
        let bytes = [UInt8](png)
        guard bytes.starts(with: pngSignature) else { return [] }
        var result: [(String, Data)] = []
        var i = 8
        while i + 12 <= bytes.count {
            let length = Int(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]))
            guard i + 12 + length <= bytes.count else { break }
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            result.append((type, Data(bytes[(i + 8)..<(i + 8 + length)])))
            i += 12 + length
            if type == "IEND" { break }
        }
        return result
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // MARK: SVG

    /// The `<metadata>` element to put inside an SVG's root element.
    public static func svgMetadata(_ state: DrawingState) -> String {
        "<metadata><drawer:diagram xmlns:drawer=\"\(namespace)\" encoding=\"base64\">\(json(state).base64EncodedString())</drawer:diagram></metadata>"
    }

    public static func fromSVG(_ svg: String) -> DrawingState? {
        guard let r = svg.range(of: #"<drawer:diagram[^>]*>([A-Za-z0-9+/=\s]+)</drawer:diagram>"#, options: .regularExpression) else { return nil }
        let element = String(svg[r])
        guard let open = element.firstIndex(of: ">"), let close = element.range(of: "</", options: .backwards) else { return nil }
        let base64 = element[element.index(after: open)..<close.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else { return nil }
        return try? JSONDecoder().decode(DrawingState.self, from: data)
    }
}
