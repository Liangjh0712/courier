import XCTest
@testable import CourierKit

final class DraftTests: XCTestCase {
    let a = Data([1]), b = Data([2])

    func testPicturesKeepTheirPlace() {
        let pics = [DraftImage(id: 1, png: a), DraftImage(id: 2, png: b)]
        XCTAssertEqual(pieces("先看[图片2]这里[图片1]然后这张", pics),
                       [.text("先看"), .image(b), .text("这里"), .image(a), .text("然后这张")])
        XCTAssertEqual(pieces("[图片1]开头", pics), [.image(a), .text("开头")])
        XCTAssertEqual(pieces("结尾[图片1]", pics), [.text("结尾"), .image(a)])
    }

    func testMarkersWithoutPictures() {
        let pics = [DraftImage(id: 1, png: a)]
        // No picture 9: the marker is text. DraftImage 1 twice: the second is text.
        XCTAssertEqual(pieces("x[图片9]y", pics), [.text("x[图片9]y")])
        XCTAssertEqual(pieces("[图片1][图片1]", pics), [.image(a), .text("[图片1]")])
        // A picture whose marker is gone is not sent.
        XCTAssertEqual(pieces("只有字", pics), [.text("只有字")])
        XCTAssertEqual(referenced("只有字", pics), [])
    }

    func testTrimAndHistory() {
        XCTAssertEqual(trimmedEnd("第一行\n第二行\n \n"), "第一行\n第二行")
        XCTAssertEqual(withoutMarkers("看[图片1]这"), "看这")
        var h: [String] = []
        for s in ["一", "二", "三", "二", ""] { remember(s, in: &h) }
        XCTAssertEqual(h, ["一", "三", "二"])
        for i in 0..<60 { remember("\(i)", in: &h) }
        XCTAssertEqual(h.count, historyMax)
        XCTAssertEqual(h.last, "59")
    }

    func testStateRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let s = SavedState(history: ["发过的"], text: "没写完的[图片1]", pictures: [.init(id: 1, png: a)])
        try s.save(to: url)
        XCTAssertEqual(SavedState.load(from: url), s)
    }

    func testReadsTheOldInputBarState() {
        // InputBar (the Go version) wrote the same shape; []byte is base64 in JSON.
        let json = #"{"history":["a"],"text":"b","pictures":[{"id":1,"png":"AQ=="}]}"#
        let s = try? JSONDecoder().decode(SavedState.self, from: Data(json.utf8))
        XCTAssertEqual(s, SavedState(history: ["a"], text: "b", pictures: [.init(id: 1, png: a)]))
    }
}
