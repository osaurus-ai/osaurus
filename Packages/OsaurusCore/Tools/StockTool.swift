//
//  StockTool.swift
//  osaurus
//
//  Get current stock quotes (and optional details) via Yahoo Finance.
//

import Foundation

struct StockTool: ChatTool {
  let name: String = "stock"
  let toolDescription: String = "Get current stock price and optional details via Yahoo Finance"

  var parameters: JSONValue? {
    // Minimal JSON Schema-like structure (OpenAI compatible)
    return .object([
      "type": .string("object"),
      "properties": .object([
        "symbol": .object([
          "type": .string("string"),
          "description": .string("Ticker symbol, e.g., AAPL"),
        ]),
        "include_details": .object([
          "type": .string("boolean"),
          "description": .string("Include extended fundamentals (market cap, PE, etc.)"),
        ]),
      ]),
      "required": .array([.string("symbol")]),
    ])
  }

  func execute(argumentsJSON: String) async throws -> String {
    // Parse and normalize arguments
    let rawArgs =
      (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
    let args = normalizeArgs(rawArgs)
    let symbolRaw =
      (args["symbol"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !symbolRaw.isEmpty else {
      return Self.failureResult(reason: "Invalid or empty stock symbol", source: "yahoo")
    }
    let symbol = symbolRaw.uppercased()
    let includeDetails = (args["include_details"] as? Bool) ?? false

    // Fetch quote (required)
    do {
      let quote = try await fetchQuote(symbol: symbol)
      guard let meta = quote.chart.result?.first?.meta else {
        return Self.failureResult(reason: "Quote data unavailable", source: "yahoo")
      }

      // Build base payload
      var payload: [String: Any] = [
        "symbol": meta.symbol,
        "price": meta.regularMarketPrice ?? 0.0,
        "currency": meta.currency ?? "USD",
        "exchange": meta.exchangeName ?? "Unknown",
        "previousClose": meta.chartPreviousClose ?? 0.0,
        "timestamp": meta.regularMarketTime ?? 0,
      ]

      if let longName = meta.longName, !longName.isEmpty {
        payload["companyName"] = longName
      } else if let shortName = meta.shortName, !shortName.isEmpty {
        payload["companyName"] = shortName
      }

      if let dayHigh = meta.regularMarketDayHigh { payload["dayHigh"] = dayHigh }
      if let dayLow = meta.regularMarketDayLow { payload["dayLow"] = dayLow }
      if let volume = meta.regularMarketVolume { payload["volume"] = volume }
      if let high52 = meta.fiftyTwoWeekHigh { payload["fiftyTwoWeekHigh"] = high52 }
      if let low52 = meta.fiftyTwoWeekLow { payload["fiftyTwoWeekLow"] = low52 }

      if let price = meta.regularMarketPrice, let prev = meta.chartPreviousClose, prev != 0 {
        let change = price - prev
        let pct = (change / prev) * 100
        payload["change"] = change
        payload["changePercent"] = pct
      }

      // Optional details
      if includeDetails {
        if let details = try? await fetchDetails(symbol: symbol) {
          if let result = details.quoteSummary.result?.first {
            if let longName = result.price?.longName, !longName.isEmpty {
              payload["companyName"] = longName
            } else if let shortName = result.price?.shortName, !shortName.isEmpty {
              payload["companyName"] = shortName
            }

            if let marketState = result.price?.marketState, !marketState.isEmpty {
              payload["marketState"] = marketState
            }

            var det: [String: Any] = [:]
            if let marketCap = result.summaryDetail?.marketCap?.raw {
              det["marketCap"] = marketCap
              if let fmt = result.summaryDetail?.marketCap?.fmt { det["marketCapFormatted"] = fmt }
            }
            if let trailingPE = result.summaryDetail?.trailingPE?.raw {
              det["trailingPE"] = trailingPE
            }
            if let forwardPE = result.summaryDetail?.forwardPE?.raw { det["forwardPE"] = forwardPE }
            if let divYield = result.summaryDetail?.dividendYield?.raw {
              det["dividendYield"] = divYield * 100
            }
            if let beta = result.summaryDetail?.beta?.raw { det["beta"] = beta }
            if let low = result.summaryDetail?.fiftyTwoWeekLow?.raw { det["fiftyTwoWeekLow"] = low }
            if let high = result.summaryDetail?.fiftyTwoWeekHigh?.raw {
              det["fiftyTwoWeekHigh"] = high
            }
            if !det.isEmpty { payload["details"] = det }
          }
        }
      }

      // Build summary text
      let priceStr: String = {
        if let price = meta.regularMarketPrice { return String(format: "%.2f", price) }
        return "0.00"
      }()
      let cur = meta.currency ?? "USD"
      let exch = meta.exchangeName ?? "Unknown"
      let changeStr: String = {
        if let price = meta.regularMarketPrice, let prev = meta.chartPreviousClose {
          let change = price - prev
          return String(format: "%+.2f", change)
        }
        return "0.00"
      }()
      let pctStr: String = {
        if let price = meta.regularMarketPrice, let prev = meta.chartPreviousClose, prev != 0 {
          let pct = (price - prev) / prev * 100
          return String(format: "%+.2f%%", pct)
        }
        return "0.00%"
      }()

      let summary = "\(symbol): \(priceStr) \(cur) (\(changeStr) / \(pctStr)) on \(exch)"

      // Serialize payload JSON (sorted keys)
      let jsonData =
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        ?? Data("{}".utf8)
      let json = String(data: jsonData, encoding: .utf8) ?? "{}"
      return summary + "\n" + json
    } catch {
      return Self.failureResult(reason: error.localizedDescription, source: "yahoo")
    }
  }

  // MARK: - Networking
  private func fetchQuote(symbol: String) async throws -> YahooQuoteResponse {
    var components = URLComponents(
      string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)")
    components?.queryItems = [
      URLQueryItem(name: "interval", value: "1d"),
      URLQueryItem(name: "range", value: "1d"),
      URLQueryItem(name: "includePrePost", value: "true"),
    ]
    guard let url = components?.url else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Osaurus/1.0", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 10

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(YahooQuoteResponse.self, from: data)
    if let err = decoded.chart.error {
      throw NSError(
        domain: "YahooFinance", code: 1, userInfo: [NSLocalizedDescriptionKey: err.description])
    }
    guard decoded.chart.result?.isEmpty == false else {
      throw NSError(
        domain: "YahooFinance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Symbol not found"])
    }
    return decoded
  }

  private func fetchDetails(symbol: String) async throws -> YahooSummaryResponse {
    var components = URLComponents(
      string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(symbol)")
    components?.queryItems = [
      URLQueryItem(name: "modules", value: "price,summaryDetail,defaultKeyStatistics")
    ]
    guard let url = components?.url else { throw URLError(.badURL) }
    var req = URLRequest(url: url)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue("Osaurus/1.0", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 10

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(YahooSummaryResponse.self, from: data)
    if let err = decoded.quoteSummary.error {
      throw NSError(
        domain: "YahooFinance", code: 3, userInfo: [NSLocalizedDescriptionKey: err.description])
    }
    return decoded
  }

  // MARK: - Helpers
  private func normalizeArgs(_ args: [String: Any]) -> [String: Any] {
    var out = args
    if out["symbol"] == nil, let s = out["s"] { out["symbol"] = s }
    if out["include_details"] == nil, let d = out["d"] { out["include_details"] = d }
    return out
  }

  private static func failureResult(reason: String, source: String) -> String {
    let summary = "Stock lookup failed: \(reason)"
    let dict: [String: Any] = ["error": reason, "source": source]
    let data =
      (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
    let json = String(data: data, encoding: .utf8) ?? "{}"
    return summary + "\n" + json
  }

  // MARK: - Models (minimal)
  private struct YahooQuoteResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
      let result: [QuoteResult]?
      let error: YahooError?
    }

    struct QuoteResult: Decodable {
      let meta: Meta

      struct Meta: Decodable {
        let currency: String?
        let symbol: String
        let exchangeName: String?
        let fullExchangeName: String?
        let instrumentType: String?
        let regularMarketTime: Int?
        let regularMarketPrice: Double?
        let fiftyTwoWeekHigh: Double?
        let fiftyTwoWeekLow: Double?
        let regularMarketDayHigh: Double?
        let regularMarketDayLow: Double?
        let regularMarketVolume: Int?
        let longName: String?
        let shortName: String?
        let chartPreviousClose: Double?
      }
    }

    struct YahooError: Decodable {
      let code: String
      let description: String
    }
  }

  private struct YahooSummaryResponse: Decodable {
    let quoteSummary: QuoteSummary

    struct QuoteSummary: Decodable {
      let result: [SummaryResult]?
      let error: YahooError?
    }

    struct SummaryResult: Decodable {
      let price: PriceInfo?
      let summaryDetail: SummaryDetail?
    }

    struct PriceInfo: Decodable {
      let longName: String?
      let shortName: String?
      let marketState: String?
    }

    struct SummaryDetail: Decodable {
      let marketCap: ValueInfo?
      let trailingPE: ValueInfo?
      let forwardPE: ValueInfo?
      let dividendYield: ValueInfo?
      let beta: ValueInfo?
      let fiftyTwoWeekLow: ValueInfo?
      let fiftyTwoWeekHigh: ValueInfo?
    }

    struct ValueInfo: Decodable {
      let raw: Double?
      let fmt: String?
    }
    struct YahooError: Decodable {
      let code: String
      let description: String
    }
  }
}
