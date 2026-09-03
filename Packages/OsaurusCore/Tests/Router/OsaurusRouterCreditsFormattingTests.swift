import Foundation
import Testing

@testable import OsaurusCore

/// The credits display contract: 1 credit = 100 micro-USD ($1 = 10,000
/// credits). Micro-USD stays the wire/arithmetic unit; these formatters are
/// the only place credits exist.
@Suite
struct OsaurusRouterCreditsFormattingTests {
    @Test func wholeBalancesGroupThousands() {
        #expect(OsaurusRouter.formatMicroAsCredits("7250000") == "72,500 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("7000000") == "70,000 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("5000000") == "50,000 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("1234500") == "12,345 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("100000000000") == "1,000,000,000 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("12500") == "125 credits")
    }

    /// Balances predating the credit system can carry sub-credit residue,
    /// rendered as two decimals per the router integration guide.
    @Test func subCreditResidueRendersTwoDecimals() {
        #expect(OsaurusRouter.formatMicroAsCredits("7250037") == "72,500.37 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("150") == "1.50 credits")
    }

    @Test func singularCreditUsesSingularUnit() {
        #expect(OsaurusRouter.formatMicroAsCredits("100") == "1 credit")
    }

    /// Tiny legacy charges below one credit must not collapse to zero.
    @Test func nonZeroBelowOneCreditRendersLessThanOne() {
        #expect(OsaurusRouter.formatMicroAsCredits("99") == "<1 credit")
        #expect(OsaurusRouter.formatMicroAsCredits("1") == "<1 credit")
        #expect(OsaurusRouter.formatMicroAsCredits("-99") == "-<1 credit")
    }

    @Test func signIsPreservedForActivityRows() {
        #expect(OsaurusRouter.formatMicroAsCredits("-5000000") == "-50,000 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("+5000000") == "50,000 credits")
    }

    @Test func zeroAndGarbageRenderZeroCredits() {
        #expect(OsaurusRouter.formatMicroAsCredits("0") == "0 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("") == "0 credits")
        #expect(OsaurusRouter.formatMicroAsCredits("not-a-number") == "0 credits")
        #expect(OsaurusRouter.formatMicroAsCredits(" 200 ") == "2 credits")
    }

    /// Hero displays show the bare figure (unit renders separately as a
    /// caption) and drop sub-credit residue.
    @Test func heroValueDropsUnitAndResidue() {
        #expect(OsaurusRouter.formatMicroAsCreditsValue("21208579") == "212,085")
        #expect(OsaurusRouter.formatMicroAsCreditsValue("7250037") == "72,500")
        #expect(OsaurusRouter.formatMicroAsCreditsValue("100") == "1")
        #expect(OsaurusRouter.formatMicroAsCreditsValue("99") == "<1")
        #expect(OsaurusRouter.formatMicroAsCreditsValue("0") == "0")
        #expect(OsaurusRouter.formatMicroAsCreditsValue("-5000000") == "-50,000")
    }

    /// The composer chip abbreviates from 10,000 credits up so six-figure
    /// balances never truncate.
    @Test func compactBalanceAbbreviatesLargeAmounts() {
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("999900") == "9,999 credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("1000000") == "10K credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("5000000") == "50K credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("21208579") == "212.1K credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("125000000") == "1.25M credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("100000000000") == "1000M credits")
        // 999,950 credits would round to "1000.0K"; it promotes to the M tier.
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("99995000") == "1M credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("150") == "1 credit")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("50") == "<1 credit")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("0") == "0 credits")
        #expect(OsaurusRouter.formatMicroAsCreditsCompact("-21208579") == "-212.1K credits")
    }

    /// Cloud media costs only exist as USD doubles; they convert through
    /// micro-USD to the same credits display.
    @Test func usdDoubleConvertsToCredits() {
        #expect(OsaurusRouter.formatUSDAsCredits(5.0) == "50,000 credits")
        #expect(OsaurusRouter.formatUSDAsCredits(0.04) == "400 credits")
        #expect(OsaurusRouter.formatUSDAsCredits(0.0001) == "1 credit")
        #expect(OsaurusRouter.formatUSDAsCredits(0) == "0 credits")
        #expect(OsaurusRouter.formatUSDAsCredits(-1.0) == "-10,000 credits")
        #expect(OsaurusRouter.formatUSDAsCredits(.nan) == "0 credits")
        #expect(OsaurusRouter.formatUSDAsCredits(.infinity) == "0 credits")
    }

    /// The dollar formatter stays byte-for-byte unchanged for the Stripe
    /// top-up flow, the one place real money is displayed.
    @Test func dollarFormatterUnchangedForTopUpFlow() {
        #expect(OsaurusRouter.formatMicroUSD("7250000") == "$7.25")
        #expect(OsaurusRouter.formatMicroUSD("5000000") == "$5.00")
        #expect(OsaurusRouter.formatMicroUSD("-1230000") == "-$1.23")
    }
}
