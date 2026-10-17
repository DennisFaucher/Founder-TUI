import XCTest
@testable import Founder

final class FuzzyQueryTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        let query = FuzzyQuery("   ")
        XCTAssertTrue(query.isEmpty)
        XCTAssertNotNil(query.match("anything at all"))
    }

    func testFuzzySubsequence() {
        let query = FuzzyQuery("rfp")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("invoice.pdf"))
    }

    func testAllTermsMustMatch() {
        let query = FuzzyQuery("pr rfp")
        XCTAssertNotNil(query.match("PurchaseRequestForPlan.pdf"))
        XCTAssertNil(query.match("PurchaseRequest.pdf"))
    }

    func testExactSubstring() {
        let query = FuzzyQuery("'plan")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("ReserveF-o-r-P-l-a-n.pdf"))
    }

    func testPrefixAndSuffix() {
        XCTAssertNotNil(FuzzyQuery("^Reserve").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery("^Reserve").match("MyReserveForPlan.pdf"))
        XCTAssertNotNil(FuzzyQuery(".pdf$").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery(".pdf$").match("ReserveForPlan.pdf.bak"))
        XCTAssertNotNil(FuzzyQuery("^ReserveForPlan.pdf$").match("ReserveForPlan.pdf"))
        XCTAssertNil(FuzzyQuery("^Reserve$").match("ReserveForPlan.pdf"))
    }

    func testNegation() {
        let query = FuzzyQuery("rfp !archive")
        XCTAssertNotNil(query.match("ReserveForPlan.pdf"))
        XCTAssertNil(query.match("ReserveForPlan.archive.pdf"))
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyQuery("rfp").match("reserveforplan.pdf"))
        XCTAssertNil(FuzzyQuery("RFP").match("reserveforplan.pdf"))
        XCTAssertNotNil(FuzzyQuery("RFP").match("ReserveForPlan.pdf"))
    }

    func testCaseInsensitiveAnchors() {
        XCTAssertNotNil(FuzzyQuery("'plan").match("ReserveForPlan.PDF"))
        XCTAssertNotNil(FuzzyQuery(".pdf$").match("ReserveForPlan.PDF"))
    }

    func testWordBoundaryBeatsMidWord() {
        let query = FuzzyQuery("plan")
        let boundary = query.match("ReserveForPlan.pdf")
        let midword = query.match("reserveXplanX.pdf")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(midword)
        XCTAssertGreaterThan(boundary!.score, midword!.score)
    }

    func testConsecutiveRunBeatsScattered() {
        let query = FuzzyQuery("abc")
        let consecutive = query.match("abc.txt")
        let scattered = query.match("a-b-c.txt")
        XCTAssertNotNil(consecutive)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(consecutive!.score, scattered!.score)
    }

    func testPositionsPointAtMatchedCharacters() {
        let query = FuzzyQuery("rfp")
        guard let match = query.match("ReserveForPlan.pdf") else {
            return XCTFail("expected a match")
        }
        let characters = Array("ReserveForPlan.pdf")
        let matched = match.positions.map { characters[$0] }.map(String.init)
        XCTAssertEqual(matched, ["R", "F", "P"])
    }

    func testPositionsForAnchoredMatch() {
        guard let match = FuzzyQuery(".pdf$").match("ReserveForPlan.pdf") else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.positions, [14, 15, 16, 17])
    }
}

final class RelativeNameTests: XCTestCase {
    func testRelativeToVolumeRoot() {
        let base = URL(fileURLWithPath: "/").standardizedFileURL.path
        XCTAssertEqual(
            relativeName(for: URL(fileURLWithPath: "/usr/lib/python3.14/os.py"), base: base),
            "usr/lib/python3.14/os.py"
        )
    }

    func testRelativeToHome() {
        let base = URL(fileURLWithPath: "/Users/someone").standardizedFileURL.path
        XCTAssertEqual(
            relativeName(for: URL(fileURLWithPath: "/Users/someone/Documents/a/b.txt"), base: base),
            "Documents/a/b.txt"
        )
        XCTAssertEqual(
            relativeName(for: URL(fileURLWithPath: "/Users/other/x.txt"), base: base),
            "x.txt"
        )
    }
}
