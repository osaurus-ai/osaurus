//
//  NativeSearchBackendTests.swift
//  OsaurusCoreTests
//
//  Challenge-page detection for the free scrapers. DDG and Bing both serve
//  anti-bot interstitials with HTTP 200/202 instead of hard-blocking; without
//  detection those pages silently parse to zero hits (or worse, DDG's decoy
//  SERPs parse to plausible-looking junk). The fixtures below are trimmed
//  from live captures of both interstitials.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct NativeSearchBackendTests {

    // MARK: - DDG

    private static let ddgAnomalyPage = """
        <!DOCTYPE html>
        <html><head><title>DuckDuckGo</title></head>
        <body>
        <div class="anomaly-modal__modal">
          <p>Unfortunately, bots use DuckDuckGo too. Please complete the \
        following challenge to confirm this search was made by a human.</p>
          <p>If this error persists, please email error-lite@duckduckgo.com</p>
        </div>
        </body></html>
        """

    @Test func ddgDetectsAnomalyPageBody() {
        #expect(DDGScrapeBackend.isChallengePage(status: 200, html: Self.ddgAnomalyPage))
    }

    @Test func ddgDetects202StatusAsChallenge() {
        #expect(DDGScrapeBackend.isChallengePage(status: 202, html: "<html></html>"))
    }

    @Test func ddgDoesNotFlagARegularSERP() {
        let serp = """
            <html><body>
            <div class="result results_links results_links_deep web-result">
              <a rel="nofollow" class="result__a" href="https://swift.org">Swift.org</a>
              <a class="result__snippet" href="https://swift.org">The Swift language</a>
            </div>
            </body></html>
            """
        #expect(!DDGScrapeBackend.isChallengePage(status: 200, html: serp))
    }

    // MARK: - Bing

    private static let bingChallengePage = """
        <!DOCTYPE html>
        <html><head><title>One last step</title></head>
        <body>
        <h1>One last step</h1>
        <p>Please solve the challenge below to continue.</p>
        <div id="challenge-container"></div>
        </body></html>
        """

    @Test func bingDetectsChallengeInterstitial() {
        #expect(BingScrapeBackend.isChallengePage(Self.bingChallengePage))
    }

    @Test func bingDoesNotFlagARegularSERP() {
        let serp = """
            <html><body>
            <ol id="b_results">
            <li class="b_algo"><h2><a href="https://swift.org">Swift.org</a></h2>
            <p>The Swift programming language.</p></li>
            </ol>
            </body></html>
            """
        #expect(!BingScrapeBackend.isChallengePage(serp))
        // Sanity: the same page still parses to a hit.
        let hits = BingScrapeBackend.parseHTML(serp, max: 5)
        #expect(hits.count == 1)
        #expect(hits[0].url == "https://swift.org")
    }

    @Test func bingResultsThroughItsClickRedirect_parseToTheResultsAddress() {
        let target = "https://www.energy.gov/heat-pump-systems?x=1"
        let encoded = Data(target.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let serp = """
            <ol id="b_results">
            <li class="b_algo"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;ptn=3&amp;u=a1\(encoded)&amp;ntb=1">Heat pumps</a></h2>
            <p>How they work.</p></li>
            </ol>
            """
        #expect(BingScrapeBackend.parseHTML(serp, max: 5).map(\.url) == [target])

        let relative = "https://www.bing.com/ck/a?!&&u=a1L2ltYWdlcy9zZWFyY2g_cT1ob3c&ntb=1"
        #expect(BingScrapeBackend.unwrapClickURL(relative) == relative, "a Bing-internal path stays wrapped")
        #expect(BingScrapeBackend.unwrapClickURL("https://swift.org/ck/a?u=a1x") == "https://swift.org/ck/a?u=a1x")
    }

    private static func hit(_ title: String, _ snippet: String, _ url: String) -> SearchHit {
        SearchHit(title: title, url: url, snippet: snippet, engine: "bing_html")
    }

    /// Captured live: Bing answered "how heat pumps work" for "heat" alone.
    @Test func bingFirstWordOnlyResults_areDecoys() {
        let decoys = [
            Self.hit("Heat (1995 film) - Wikipedia", "LAPD detective Vincent Hanna attempts to apprehend career thief Neil McCauley", "https://en.wikipedia.org/wiki/Heat_(1995_film)"),
            Self.hit("Official Site Of The Miami HEAT - NBA.com", "Stay updated with the latest Miami HEAT scores and news.", "https://www.nba.com/heat/"),
            Self.hit("Heat - Wikipedia", "Heat is energy in transfer other than through thermodynamic work", "https://en.wikipedia.org/wiki/Heat"),
            Self.hit("Heat (1995) - IMDb", "Directed by Michael Mann. With Al Pacino, Robert De Niro.", "https://www.imdb.com/title/tt0113277/"),
            Self.hit("Miami Heat Scores, Stats and Highlights - ESPN", "Visit ESPN for Miami Heat live scores.", "https://www.espn.com/nba/team/_/name/mia/miami-heat"),
        ]
        #expect(BingScrapeBackend.matchesOnlyLeadingTerm(decoys, query: "how heat pumps work"))
    }

    @Test func bingOnTopicResults_areKept() {
        let real = [
            Self.hit("How Heat Pumps Work | HowStuffWorks", "A heat pump moves heat from one place to another.", "https://home.howstuffworks.com/heat-pump.htm"),
            Self.hit("Heat pump - Wikipedia", "A heat pump is a device that transfers thermal energy.", "https://en.wikipedia.org/wiki/Heat_pump"),
            Self.hit("Heat (1995 film) - Wikipedia", "A crime film.", "https://en.wikipedia.org/wiki/Heat_(1995_film)"),
        ]
        #expect(!BingScrapeBackend.matchesOnlyLeadingTerm(real, query: "how heat pumps work"))
        #expect(!BingScrapeBackend.matchesOnlyLeadingTerm(real, query: "heat"), "a one-word query has nothing to miss")
    }

    // MARK: - Brave

    /// Trimmed from a live capture: Brave's inline i18n bundle carries
    /// "Switch to traditional captcha" on every results page.
    private static let braveSERP = """
        <!DOCTYPE html><html><head><title>how heat pumps work - Brave Search</title>
        <script>const i18n={"Switch to traditional captcha":"Switch to traditional CAPTCHA"};</script></head>
        <body>
        <div class="snippet svelte-jmfu5f" data-pos="1" data-type="web"><div class="result-content svelte-1rq4ngz">\
        <a href="https://www.carrier.com/heat-pumps/" target="_self" class="svelte-14r20fy l1">\
        <div class="title search-snippet-title line-clamp-1 svelte-14r20fy">What Is A Heat Pump? | Carrier</div></a>\
        <div class="generic-snippet svelte-1cwdgg3"><div class="content t-primary">Heat pumps \
        <strong>move heat</strong> using refrigerant.</div></div></div></div>
        <div class="snippet svelte-jmfu5f" data-pos="2" data-type="ad"><a href="https://search.brave.com/a/redirect?x" class="l1">\
        <div class="title">Ad</div></a></div>
        </body></html>
        """

    @Test func braveResultsPage_withCaptchaInItsScripts_parses() {
        #expect(!SearchHTML.isLikelyChallengePage(Self.braveSERP, treatShortAsChallenge: false))
        let hits = BraveScrapeBackend.parseHTML(Self.braveSERP, max: 5)
        #expect(hits.map(\.url) == ["https://www.carrier.com/heat-pumps/"])
        #expect(hits.first?.title == "What Is A Heat Pump? | Carrier")
        #expect(hits.first?.snippet == "Heat pumps move heat using refrigerant.")
    }

    @Test func visibleCaptcha_isStillAChallenge() {
        let page = """
            <html><head><title>Just a moment...</title><script>var x = 1;</script></head>
            <body><p>Checking your browser before accessing the site.</p></body></html>
            """
        #expect(SearchHTML.isLikelyChallengePage(page, treatShortAsChallenge: false))
    }

    /// Every Wikipedia article ships MediaWiki config naming hCaptcha.
    @Test func wikipediaArticle_isNotAChallenge() {
        let article = """
            <!DOCTYPE html><html lang="en"><head><title>Heat pump - Wikipedia</title>
            <script>RLCONF={"wgConfirmEditCaptchaNeededForGenericEdit":"hcaptcha"};</script></head>
            <body><main><p>A heat pump is a device that uses electric power to transfer heat.</p></main></body></html>
            """
        #expect(!SearchHTML.isLikelyChallengePage(article, treatShortAsChallenge: false))
    }
}
