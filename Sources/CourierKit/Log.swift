import Foundation

// The log, ~/Library/Logs/Courier.log: local time to the millisecond, rolled
// over to Courier.log.1 past 2 MB. It is what a report of "it did not send"
// is checked against, so every step of a send is in it.

private let traceFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss.SSS"
    return f
}()
private let traceQueue = DispatchQueue(label: "courier.trace")

public func trace(_ s: String) {
    let line = "\(traceFormat.string(from: Date())) \(s)\n"
    traceQueue.async {
        let url = Paths.log
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// A short one-line view of a text for the log.
public func preview(_ s: String) -> String {
    let one = s.replacingOccurrences(of: "\n", with: "⏎")
    return one.count > 30 ? String(one.prefix(30)) + "…" : one
}

/// The shape of a send for the log: T12,I51KB,T8 = 12 characters, a 51 KB picture, 8 characters.
public func describe(_ parts: [Piece]) -> String {
    parts.map { p -> String in
        switch p {
        case .text(let s): return "T\(s.count)"
        case .image(let d): return "I\(d.count / 1024)KB"
        }
    }.joined(separator: ",")
}
