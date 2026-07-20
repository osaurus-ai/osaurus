import Testing

@testable import OsaurusCore

@Suite("Credits top-up amount parsing")
struct CreditsTopUpSheetTests {
    @Test func ordinaryDollarAmountsConvertToMicroUSD() {
        #expect(CreditsTopUpSheet.parseMicroUSD("25") == 25_000_000)
        #expect(CreditsTopUpSheet.parseMicroUSD(" $5.50 ") == 5_500_000)
    }

    @Test func oversizedFiniteAmountIsRejectedWithoutIntOverflow() {
        #expect(CreditsTopUpSheet.parseMicroUSD("1e300") == nil)
        #expect(CreditsTopUpSheet.parseMicroUSD(String(Double.greatestFiniteMagnitude)) == nil)
        // `Double(Int.max)` is represented as 2^63, not Int.max. This amount
        // reaches that exact post-scaling boundary and must remain failable.
        #expect(CreditsTopUpSheet.parseMicroUSD("9223372036854.775808") == nil)
    }

    @Test func nonPositiveAndNonFiniteAmountsRemainInvalid() {
        #expect(CreditsTopUpSheet.parseMicroUSD("0") == nil)
        #expect(CreditsTopUpSheet.parseMicroUSD("-1") == nil)
        #expect(CreditsTopUpSheet.parseMicroUSD("nan") == nil)
        #expect(CreditsTopUpSheet.parseMicroUSD("inf") == nil)
    }
}
