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
}
