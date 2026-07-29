import XCTest
@testable import CodexMenuBar

final class JSONLineFramerTests: XCTestCase {
    func testSplitAndCoalescedLines() throws {
        var framer = JSONLineFramer()
        XCTAssertEqual(try framer.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8)), [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        XCTAssertEqual(try framer.append(Data("{\"c\":".utf8)), [])
        XCTAssertEqual(try framer.append(Data("3}\r\n".utf8)), [Data("{\"c\":3}".utf8)])
    }

    func testEmptyAndMalformedLinesAreFramed() throws {
        var framer = JSONLineFramer()
        XCTAssertEqual(try framer.append(Data("\nnot-json\n".utf8)), [Data("not-json".utf8)])
    }

    func testLineLimit() {
        var framer = JSONLineFramer(maximumLineBytes: 3)
        XCTAssertThrowsError(try framer.append(Data("1234".utf8)))
    }
}
