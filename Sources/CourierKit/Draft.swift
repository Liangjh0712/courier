import Foundation

/// A picture in the draft. Its marker, "[图片N]" with N = id, stands where it goes.
public struct DraftImage: Equatable {
    public let id: Int
    public let png: Data
    public init(id: Int, png: Data) {
        self.id = id
        self.png = png
    }
}

/// One step of a send: a paste of text or of a picture.
public enum Piece: Equatable {
    case text(String)
    case image(Data)
}

public func marker(_ id: Int) -> String { "[图片\(id)]" }

let markerRE = try! NSRegularExpression(pattern: "\\[图片(\\d+)\\]")

/// The text without trailing blanks and new lines: an Enter at the end is
/// what sends, not part of the message.
public func trimmedEnd(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
}

/// The message cut at its picture markers, each picture where its marker is.
/// A picture whose marker was deleted is not sent (deleting the marker is how
/// a picture is taken out); a marker with no picture stays text; a second
/// marker of the same picture stays text too.
public func pieces(_ text: String, _ pics: [DraftImage]) -> [Piece] {
    var out: [Piece] = []
    var used = Set<Int>()
    let ns = text as NSString
    var last = 0
    for m in markerRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let id = Int(ns.substring(with: m.range(at: 1))) ?? -1
        guard !used.contains(id), let p = pics.first(where: { $0.id == id }) else { continue }
        let before = ns.substring(with: NSRange(location: last, length: m.range.location - last))
        if !before.isEmpty { out.append(.text(before)) }
        out.append(.image(p.png))
        used.insert(id)
        last = m.range.location + m.range.length
    }
    let rest = ns.substring(from: last)
    if !rest.isEmpty { out.append(.text(rest)) }
    return out
}

/// The pictures the text still refers to.
public func referenced(_ text: String, _ pics: [DraftImage]) -> [DraftImage] {
    pics.filter { text.contains(marker($0.id)) }
}

/// The text with its picture markers taken out, for the history (which keeps
/// no pictures).
public func withoutMarkers(_ s: String) -> String {
    markerRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
}
