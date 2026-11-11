import XCTest
@testable import HermitUI
import HermitWallet

/// The amount a person typed is the amount the engine parses: a comma never makes a number ten or a thousand times bigger.
final class AmountTextTests: XCTestCase {
    private func n(_ s: String, _ sep: String) -> String? { AmountText.normalize(s, decimalSeparator: sep) }

    func testCommaIsTheDecimalMarkInACommaRegion() {
        XCTAssertEqual(n("1,5", ","), "1.5")
        XCTAssertEqual(n("0,5", ","), "0.5")
        XCTAssertEqual(n("1,", ","), "1.")
        XCTAssertEqual(n("1,000", ","), "1.000")
        XCTAssertEqual(n("1.234,56", ","), "1234.56")
        XCTAssertEqual(n("1.000.000", ","), "1000000")
        XCTAssertEqual(n("1 000,5", ","), "1000.5")
        // The app writes amounts with a dot (Max, 25%): those read the same everywhere.
        XCTAssertEqual(n("1.5", ","), "1.5")
        XCTAssertEqual(n("1.125", ","), "1.125")
    }

    func testCommaGroupsThousandsInADotRegion() {
        XCTAssertEqual(n("1,000", "."), "1000")
        XCTAssertEqual(n("1,000.50", "."), "1000.50")
        XCTAssertEqual(n("1,000,000", "."), "1000000")
        XCTAssertEqual(n("1.234,56", "."), "1234.56")
        XCTAssertEqual(n("12.5", "."), "12.5")
        XCTAssertEqual(n(".5", "."), ".5")
        XCTAssertEqual(n("25", "."), "25")
        XCTAssertEqual(n("  ", "."), "")
        XCTAssertEqual(n("١٢", "."), "12")
    }

    func testUnclearTextIsRefused() {
        // The old parser dropped every comma: these became 15, 5 and 150.
        XCTAssertNil(n("1,5", "."))
        XCTAssertNil(n("0,5", "."))
        XCTAssertNil(n("1,50", "."))
        XCTAssertNil(n("1,", "."))
        XCTAssertNil(n("0,500", "."))
        XCTAssertNil(n("1,0000", "."))
        XCTAssertNil(n("1.2.3", "."))
        XCTAssertNil(n("1,2,3", "."))
        XCTAssertNil(n("1,2,3", ","))
        XCTAssertNil(n("1,000.5,0", "."))
        XCTAssertNil(n("1e5", "."))
        XCTAssertNil(n("-1", "."))
        XCTAssertNil(n("0x10", "."))
    }

    func testValueAndCleanAgree() {
        XCTAssertNil(AmountText.value("abc"))
        XCTAssertEqual(AmountText.clean("abc"), "")
        XCTAssertNil(AmountText.value("."))
    }

    func testFractionIsExactAndNeverAboveTheBalance() {
        func h(_ exact: String) -> Holding {
            Holding(walletID: "w", chain: .base, symbol: "ETH", name: "Ether", exact: exact, amount: Double(exact) ?? 0, price: nil, change: nil)
        }
        XCTAssertEqual(fractionText(h("1.000000000000000001"), 0.5), "0.5")
        XCTAssertEqual(fractionText(h("123456789.123456789"), 0.25), "30864197.28086419")
        XCTAssertEqual(fractionText(h("3"), 1), "3")
        XCTAssertEqual(fractionText(h("0.00000001"), 0.5), "0")
    }
}
