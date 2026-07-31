import Foundation
import WebKit

/// One-shot, nonpersistent WebKit verification for a workspace HTML file.
/// This deliberately does not reuse BrowserSession: verification must not
/// inherit cookies, storage, open pages, or external-network access.
@MainActor
enum WorkspaceWebSmokeVerifier {
    final class PayloadBox: @unchecked Sendable {
        let payload: [String: Any]

        init(_ payload: [String: Any]) {
            self.payload = payload
        }
    }

    private enum VerifyError: LocalizedError {
        case timeout
        case navigation(String)
        case invalidEvidence

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Local WebKit smoke verification timed out."
            case .navigation(let message):
                return "Local WebKit navigation failed: \(message)"
            case .invalidEvidence:
                return "Local WebKit returned invalid DOM evidence."
            }
        }
    }

    private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func load(
            _ fileURL: URL,
            in webView: WKWebView,
            allowingReadAccessTo readRoot: URL
        ) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.navigationDelegate = self
                webView.loadFileURL(fileURL, allowingReadAccessTo: readRoot)
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(8))
                    finish(.failure(VerifyError.timeout))
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(VerifyError.navigation(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(.failure(VerifyError.navigation(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            decisionHandler(
                scheme == nil || scheme == "file" || scheme == "about" ? .allow : .cancel
            )
        }

        private func finish(_ result: Result<Void, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation.resume(with: result)
        }
    }

    private final class JSResultBox: @unchecked Sendable {
        let value: Any?
        let error: Error?

        init(value: Any?, error: Error?) {
            self.value = value
            self.error = error
        }
    }

    static func verify(
        fileURL: URL,
        displayPath: String,
        selector: String?,
        minimumCount: Int
    ) async -> PayloadBox {
        let source = try? String(contentsOf: fileURL, encoding: .utf8)
        let contentHash = source.map(WorkspaceWriteSafety.contentSHA256)
        do {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let controller = WKUserContentController()
            controller.add(try await networkBlockRule())
            controller.addUserScript(
                WKUserScript(
                    source: errorCaptureScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            configuration.userContentController = controller

            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                configuration: configuration
            )
            let waiter = NavigationWaiter()
            try await waiter.load(
                fileURL,
                in: webView,
                allowingReadAccessTo: fileURL
            )
            // Allow synchronous initialization, queued microtasks, and a
            // first animation frame to settle before sampling the DOM.
            try await Task.sleep(for: .milliseconds(300))

            let evidence = try await evaluateEvidence(
                webView: webView,
                selector: selector,
                minimumCount: max(1, minimumCount)
            )
            webView.stopLoading()
            webView.navigationDelegate = nil

            let runtimeErrors = evidence["runtime_errors"] as? [String] ?? []
            let selectorCount = evidence["selector_count"] as? Int
            let boardPresent = evidence["board_present"] as? Bool == true
            let boardElementCount = evidence["board_element_count"] as? Int
            var failures = runtimeErrors
            if let selector, let selectorCount, selectorCount < max(1, minimumCount) {
                failures.append(
                    "Selector '\(selector)' matched \(selectorCount) element(s); expected at least \(max(1, minimumCount))."
                )
            }
            if selector == nil, boardPresent, boardElementCount == 0 {
                failures.append(
                    "Element '#board' exists but contains no rendered child elements after page load."
                )
            }

            var payload: [String: Any] = [
                "status": failures.isEmpty ? "passed" : "failed",
                "level": "behavior_smoke",
                "engine": "isolated_webkit",
                "path": displayPath,
                "network": "blocked",
                "storage": "nonpersistent",
                "errors": failures,
                "dom": evidence,
            ]
            if let contentHash {
                payload["content_sha256"] = contentHash
            }
            return PayloadBox(payload)
        } catch {
            var payload: [String: Any] = [
                "status": "failed",
                "level": "behavior_smoke",
                "engine": "isolated_webkit",
                "path": displayPath,
                "network": "blocked",
                "storage": "nonpersistent",
                "errors": [error.localizedDescription],
                "message": error.localizedDescription,
            ]
            if let contentHash {
                payload["content_sha256"] = contentHash
            }
            return PayloadBox(payload)
        }
    }

    private static func evaluateEvidence(
        webView: WKWebView,
        selector: String?,
        minimumCount: Int
    ) async throws -> [String: Any] {
        let selectorLiteral: String
        if let selector,
            let data = try? JSONEncoder().encode(selector),
            let json = String(data: data, encoding: .utf8)
        {
            selectorLiteral = json
        } else {
            selectorLiteral = "null"
        }
        let script = """
            (() => {
              const selector = \(selectorLiteral);
              const board = document.querySelector('#board');
              const targetCount = selector ? document.querySelectorAll(selector).length : null;
              const boardRect = board ? board.getBoundingClientRect() : null;
              return JSON.stringify({
                ready_state: document.readyState,
                title: document.title || '',
                body_text_characters: (document.body?.innerText || '').length,
                element_count: document.querySelectorAll('*').length,
                button_count: document.querySelectorAll('button').length,
                board_present: !!board,
                board_element_count: board ? board.querySelectorAll('*').length : null,
                board_width: boardRect ? Math.round(boardRect.width) : null,
                board_height: boardRect ? Math.round(boardRect.height) : null,
                selector: selector,
                selector_count: targetCount,
                selector_minimum: selector ? \(minimumCount) : null,
                runtime_errors: Array.isArray(window.__osaurusVerificationErrors)
                  ? window.__osaurusVerificationErrors
                  : []
              });
            })()
            """
        let box: JSResultBox = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                continuation.resume(returning: JSResultBox(value: value, error: error))
            }
        }
        if let error = box.error { throw error }
        guard let json = box.value as? String,
            let data = json.data(using: .utf8),
            let evidence = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw VerifyError.invalidEvidence
        }
        return evidence
    }

    private static func networkBlockRule() async throws -> WKContentRuleList {
        let rules = """
            [
              {
                "trigger": { "url-filter": "^https://.*" },
                "action": { "type": "block" }
              },
              {
                "trigger": { "url-filter": "^http://.*" },
                "action": { "type": "block" }
              },
              {
                "trigger": { "url-filter": "^wss://.*" },
                "action": { "type": "block" }
              },
              {
                "trigger": { "url-filter": "^ws://.*" },
                "action": { "type": "block" }
              }
            ]
            """
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "com.dinoki.osaurus.workspace-web-smoke-network-block",
                encodedContentRuleList: rules
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(
                        throwing: error
                            ?? VerifyError.navigation("Could not install external-network block.")
                    )
                }
            }
        }
    }

    private static let errorCaptureScript = """
        (() => {
          const errors = [];
          Object.defineProperty(window, '__osaurusVerificationErrors', {
            value: errors,
            configurable: false,
            enumerable: false,
            writable: false
          });
          window.addEventListener('error', event => {
            const errorDetail = event.error && (event.error.stack || event.error.message);
            const location = event.filename
              ? ` (${event.filename}:${event.lineno || 0}:${event.colno || 0})`
              : '';
            errors.push(`${errorDetail || event.message || 'JavaScript error'}${location}`);
          });
          window.addEventListener('unhandledrejection', event => {
            const reason = event.reason;
            errors.push(`Unhandled promise rejection: ${
              reason && reason.stack ? reason.stack : String(reason)
            }`);
          });
        })();
        """
}
