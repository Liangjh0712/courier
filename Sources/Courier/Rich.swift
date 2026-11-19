import AppKit
import CourierKit

// In the editor a picture is an attachment showing its thumbnail; the draft
// as stored and sent is text with a [图片N] marker in its place.

let baseAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 14),
    .foregroundColor: NSColor.textColor,
]

final class ShotAttachment: NSTextAttachment {
    let shotID: Int
    let png: Data

    init(id: Int, png: Data) {
        shotID = id
        self.png = png
        super.init(data: nil, ofType: nil)
        let thumb = thumbnail(png)
        image = thumb
        bounds = CGRect(x: 0, y: -6, width: thumb.size.width, height: thumb.size.height)
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}

/// A thumbnail at most 40 high and 140 wide, with rounded corners and a hairline.
func thumbnail(_ png: Data) -> NSImage {
    guard let src = NSImage(data: png), src.size.width > 0, src.size.height > 0 else {
        return NSImage(size: NSSize(width: 40, height: 40))
    }
    var h = min(40, src.size.height)
    var w = src.size.width * h / src.size.height
    if w > 140 {
        w = 140
        h = src.size.height * w / src.size.width
    }
    return NSImage(size: NSSize(width: ceil(w), height: ceil(h)), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        src.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        return true
    }
}

func toEditor(_ text: String, _ pics: [DraftImage]) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for s in segments(text, pics) {
        switch s {
        case .text(let t):
            out.append(NSAttributedString(string: t, attributes: baseAttributes))
        case .picture(let p):
            let a = NSMutableAttributedString(attachment: ShotAttachment(id: p.id, png: p.png))
            a.addAttributes(baseAttributes, range: NSRange(location: 0, length: a.length))
            out.append(a)
        }
    }
    return out
}

func fromEditor(_ s: NSAttributedString) -> (text: String, pics: [DraftImage]) {
    var text = ""
    var pics: [DraftImage] = []
    let ns = s.string as NSString
    s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, _ in
        if let a = value as? ShotAttachment {
            text += marker(a.shotID)
            pics.append(DraftImage(id: a.shotID, png: a.png))
        } else if value == nil {
            text += ns.substring(with: range)
        }
    }
    return (text, pics)
}
