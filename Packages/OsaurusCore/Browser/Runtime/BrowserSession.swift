//
//  BrowserSession.swift
//  OsaurusCore — Native Browser Use
//
//  The native, `@MainActor` async WebKit engine behind Browser Use. One
//  instance per agent, keyed by a persistent WebKit profile UUID so cookies /
//  localStorage / IndexedDB survive across runs and stay isolated between
//  agents (`WKWebsiteDataStore(forIdentifier:)`).
//
//  This replaces the MIT `osaurus.browser` plugin's `HeadlessBrowser`: the
//  proven perception / action JavaScript is preserved verbatim for parity, but
//  the plugin's `DispatchSemaphore` bridge (mandated by the synchronous C ABI)
//  is gone — every WebKit call is a real `async` hop, so the runtime composes
//  cleanly with the subagent loop's cancellation and never blocks a thread.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// Per-agent WebKit profile identifier. The `WKWebsiteDataStore` and the
    /// sign-in `BrowserLoginWindow` share this UUID so credentials entered in
    /// the visible window flow straight back into the headless session.
    let profileId: UUID

    private var webView: WKWebView!
    private var navigationContinuation: CheckedContinuation<Error?, Never>?
    /// Identifies which `navigate` call owns `navigationContinuation`, so a
    /// stale timeout timer can never resume a later navigation.
    private var navigationGeneration = 0
    /// The WKNavigation owned by the pending `navigate` call. Delegate
    /// callbacks for a superseded navigation (e.g. the -999 cancellation
    /// WebKit fires when a new load replaces a provisional one) carry the OLD
    /// navigation object and must not resume the new continuation.
    private var currentNavigation: WKNavigation?
    private var refCounter = 0
    private var hasNavigated = false
    private var snapshotGeneration = 0

    // Dialog handling — a pre-registered policy applied to the next dialog.
    struct DialogPolicy {
        var accept: Bool
        var promptText: String?
    }
    private var pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
    private(set) var lastDialog: [String: Any]?

    init(profileId: UUID) {
        self.profileId = profileId
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileId)
        config.applicationNameForUserAgent = Self.desktopSafariUA

        let captureScript = WKUserScript(
            source: Self.captureScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(captureScript)

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: config
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    }

    static let desktopSafariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - URL scheme policy

    /// Test seam: the WebKit smoke tests load local HTML fixtures over
    /// `file://`. Never set outside tests.
    static var allowFileURLsForTesting = false

    /// Why a URL must not be loaded in an agent-driven session, or nil when it
    /// is allowed. Only `http` / `https` (and `about:blank`) are navigable:
    /// `file://` would let the model read arbitrary local files into its
    /// context, `data:`/`blob:` smuggle attacker-authored documents past the
    /// per-host policy, and unknown schemes can bounce out to other apps.
    /// Enforced BOTH at the tool boundary (`BrowserToolExecutor.navigate`) and
    /// in `decidePolicyFor` (covers redirects, JS navigation, and clicks on
    /// crafted links).
    static func navigationRefusalReason(for url: URL?) -> String? {
        guard let url else { return nil }
        switch (url.scheme ?? "").lowercased() {
        case "http", "https":
            return nil
        case "about":
            // about:blank (initial document / window.open targets).
            return nil
        case "file":
            if allowFileURLsForTesting { return nil }
            return
                "Local file URLs are blocked in the agent browser. Only http(s) pages can be loaded."
        case let scheme:
            return
                "URLs with the '\(scheme)' scheme are blocked in the agent browser. Only http(s) pages can be loaded."
        }
    }

    /// The live `WKWebsiteDataStore` backing this session, grabbed before
    /// teardown so callers can wipe per-agent storage in place via
    /// `removeData(ofTypes:modifiedSince:)` (never the crash-prone
    /// `WKWebsiteDataStore.remove(forIdentifier:)`).
    var websiteDataStore: WKWebsiteDataStore? {
        webView?.configuration.websiteDataStore
    }

    /// The live WebView, exposed so the settings-tab session window can attach
    /// it directly (the delegate stays with this session; the window observes
    /// URL/title via KVO instead).
    var liveWebView: WKWebView? {
        webView
    }

    /// Releases the underlying webview. Safe to call multiple times.
    func tearDown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        if let continuation = navigationContinuation {
            navigationContinuation = nil
            continuation.resume(returning: nil)
        }
    }

    // MARK: - Capture script (console + network instrumentation)

    static let captureScriptSource: String = """
        (function() {
          if (window.__osaurus_capture_installed) return;
          window.__osaurus_capture_installed = true;
          window.__osaurus_console = [];
          window.__osaurus_network = [];
          var origConsole = {};
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function(level) {
            origConsole[level] = (console[level] || console.log).bind(console);
            console[level] = function() {
              var args = Array.prototype.slice.call(arguments).map(function(a) {
                try { return typeof a === 'string' ? a : JSON.stringify(a); }
                catch (e) { return String(a); }
              });
              window.__osaurus_console.push({
                level: level,
                message: args.join(' '),
                timestamp: Date.now()
              });
              if (window.__osaurus_console.length > 500) window.__osaurus_console.shift();
              try { origConsole[level].apply(null, arguments); } catch (e) {}
            };
          });
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function(input, init) {
              var url = typeof input === 'string' ? input : (input && input.url) || '';
              var method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
              var entry = { url: url, method: method.toUpperCase(), kind: 'fetch', start: Date.now() };
              window.__osaurus_network.push(entry);
              if (window.__osaurus_network.length > 500) window.__osaurus_network.shift();
              return origFetch.apply(this, arguments).then(function(resp) {
                entry.status = resp.status; entry.ok = resp.ok;
                entry.duration_ms = Date.now() - entry.start;
                return resp;
              }).catch(function(err) {
                entry.status = 0; entry.error = String(err);
                entry.duration_ms = Date.now() - entry.start;
                throw err;
              });
            };
          }
          var XHR = window.XMLHttpRequest;
          if (XHR) {
            var origOpen = XHR.prototype.open;
            var origSend = XHR.prototype.send;
            XHR.prototype.open = function(method, url) {
              this.__osaurus_entry = { url: url, method: method.toUpperCase(), kind: 'xhr', start: Date.now() };
              window.__osaurus_network.push(this.__osaurus_entry);
              if (window.__osaurus_network.length > 500) window.__osaurus_network.shift();
              return origOpen.apply(this, arguments);
            };
            XHR.prototype.send = function() {
              var self = this;
              this.addEventListener('loadend', function() {
                if (self.__osaurus_entry) {
                  self.__osaurus_entry.status = self.status;
                  self.__osaurus_entry.ok = self.status >= 200 && self.status < 400;
                  self.__osaurus_entry.duration_ms = Date.now() - self.__osaurus_entry.start;
                }
              });
              return origSend.apply(this, arguments);
            };
          }
        })();
        """

    // MARK: - JavaScript evaluation

    /// Box for the non-Sendable JS result crossing the continuation. Both the
    /// completion handler and the awaiting caller are main-actor, so the
    /// transfer is safe in practice; the box just satisfies strict checking.
    private final class JSResultBox: @unchecked Sendable {
        let result: Any?
        let error: String?
        init(result: Any?, error: String?) {
            self.result = result
            self.error = error
        }
    }

    /// Evaluate a script and return the raw result / error message. Async,
    /// main-actor confined — no semaphore.
    func evaluateJavaScript(_ script: String) async -> (result: Any?, error: String?) {
        guard let webView else { return (nil, "Browser session was torn down.") }
        let box: JSResultBox = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                continuation.resume(
                    returning: JSResultBox(result: result, error: error?.localizedDescription))
            }
        }
        return (box.result, box.error)
    }

    // MARK: - Navigation

    enum WaitUntil: String {
        case load
        case networkidle
        case domstable
    }

    func navigate(
        to urlString: String,
        timeout: TimeInterval = 30,
        waitUntil: WaitUntil = .load
    ) async -> (success: Bool, error: String?) {
        guard let webView else { return (false, "Browser session was torn down.") }
        guard let url = URL(string: urlString) else { return (false, "Invalid URL: \(urlString)") }
        if let refusal = Self.navigationRefusalReason(for: url) { return (false, refusal) }

        // A navigate while one is pending would silently orphan the first
        // awaiter; resolve it explicitly before installing the new one.
        resumeNavigation(with: BrowserNavigationSuperseded())
        navigationGeneration += 1
        let generation = navigationGeneration

        let navError: Error? = await withCheckedContinuation { continuation in
            navigationContinuation = continuation
            let request = URLRequest(url: url, timeoutInterval: timeout)
            currentNavigation = webView.load(request)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self,
                    // A stale timer must never fire into a LATER navigation's
                    // continuation — it only times out its own generation.
                    self.navigationGeneration == generation,
                    let pending = self.navigationContinuation
                else { return }
                self.navigationContinuation = nil
                pending.resume(returning: BrowserTimeout())
            }
        }

        if navError is BrowserTimeout {
            return (false, "Navigation timed out after \(Int(timeout)) seconds")
        }
        if navError is BrowserNavigationSuperseded {
            return (false, "Navigation was superseded by a newer navigation.")
        }
        if let blocked = navError as? BrowserNavigationBlocked {
            return (false, blocked.reason)
        }
        if let navError { return (false, navError.localizedDescription) }

        switch waitUntil {
        case .load: break
        case .networkidle: await waitForNetworkIdle(timeout: timeout)
        case .domstable: await waitForDOMStable(timeout: timeout)
        }

        hasNavigated = true
        return (true, nil)
    }

    /// Navigate back in the session's history and wait for the page to settle.
    func goBack() async -> (success: Bool, error: String?) {
        guard let webView else { return (false, "Browser session was torn down.") }
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        guard webView.canGoBack else { return (false, "No back history in this session.") }
        webView.goBack()
        try? await Task.sleep(nanoseconds: 300_000_000)
        await waitForDOMStable(timeout: 10)
        return (true, nil)
    }

    private struct BrowserTimeout: Error {}
    private struct BrowserNavigationSuperseded: Error {}
    struct BrowserNavigationBlocked: Error {
        let reason: String
    }

    func waitForNetworkIdle(timeout: TimeInterval) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let script = """
            (function() {
                return window.performance.getEntriesByType('resource')
                    .filter(r => r.initiatorType === 'fetch' || r.initiatorType === 'xmlhttprequest')
                    .filter(r => r.responseEnd === 0).length;
            })()
            """
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let result = await evaluateJavaScript(script)
            if let pending = result.result as? Int, pending == 0 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func waitForDOMStable(timeout: TimeInterval) async {
        let readyScript = "(function(){try{return document.readyState==='complete';}catch(e){return false;}})()"
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let result = await evaluateJavaScript(readyScript)
            if result.result as? Bool == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let countScript =
            "(function(){try{if(!document.body)return -1;return document.body.getElementsByTagName('*').length;}catch(e){return -1;}})()"
        var lastCount = -1
        var stableIterations = 0
        while Date().timeIntervalSince(start) < timeout {
            let result = await evaluateJavaScript(countScript)
            if let count = result.result as? Int {
                if count == lastCount && count >= 0 {
                    stableIterations += 1
                    if stableIterations >= 3 { return }
                } else {
                    stableIterations = 0
                    lastCount = count
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Snapshot

    struct SnapshotOptions {
        var filter: String = "all"
        var maxElements: Int = 100
        var visibleOnly: Bool = true
    }

    func takeSnapshot(
        options: SnapshotOptions = SnapshotOptions(),
        detail: BrowserDetailLevel = .standard
    ) async -> String {
        guard hasNavigated else {
            return "Error: No page loaded. Call browser_navigate first to load a page."
        }
        refCounter = 0
        snapshotGeneration += 1
        let currentGeneration = snapshotGeneration

        let filterCondition: String
        switch options.filter {
        case "inputs":
            filterCondition = "el.matches('input, textarea, select, [contenteditable=\"true\"]')"
        case "buttons":
            filterCondition =
                "el.matches('button, input[type=\"button\"], input[type=\"submit\"], [role=\"button\"]')"
        case "links":
            filterCondition = "el.matches('a[href]')"
        case "forms":
            filterCondition = "el.matches('form, input, textarea, select, button')"
        default:
            filterCondition = "true"
        }

        let visibilityCheck = options.visibleOnly
            ? """
                try {
                    const rect = el.getBoundingClientRect();
                    // Elements inside same-origin iframes must be styled by THEIR window.
                    const win = (el.ownerDocument && el.ownerDocument.defaultView) || window;
                    const style = win.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                    if (rect.width === 0 && rect.height === 0) return false;
                    return true;
                } catch (e) { return false; }
            """ : "return true;"

        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {error: 'Page not ready - document.body is null.'};
                    }
                    if (document.readyState === 'loading') {
                        return {error: 'Page still loading. Wait and try again.'};
                    }
                    const maxElements = \(options.maxElements);
                    const results = [];
                    let refId = 0;
                    window.__osaurus_refs = new Map();
                    window.__osaurus_snapshot_gen = \(currentGeneration);
                    function isVisible(el) { \(visibilityCheck) }
                    function isInteractive(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : '';
                            if (!tag) return false;
                            const role = el.getAttribute ? el.getAttribute('role') : null;
                            const tabIndex = el.getAttribute ? el.getAttribute('tabindex') : null;
                            if (['a','button','input','textarea','select','details','summary'].includes(tag)) return true;
                            if (['button','link','menuitem','option','radio','checkbox','tab','textbox','combobox','listbox','menu','menubar','slider','spinbutton','switch'].includes(role)) return true;
                            if (el.onclick || (el.getAttribute && el.getAttribute('onclick'))) return true;
                            if (tabIndex && tabIndex !== '-1') return true;
                            if (el.getAttribute && el.getAttribute('contenteditable') === 'true') return true;
                            return false;
                        } catch (e) { return false; }
                    }
                    function getElementType(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : 'unknown';
                            const type = el.getAttribute ? el.getAttribute('type') : null;
                            const role = el.getAttribute ? el.getAttribute('role') : null;
                            if (tag === 'a') return 'link';
                            if (tag === 'button' || role === 'button') return 'button';
                            if (tag === 'input') {
                                if (type === 'checkbox') return 'checkbox';
                                if (type === 'radio') return 'radio';
                                if (type === 'submit') return 'submit';
                                if (type === 'file') return 'file';
                                return 'input';
                            }
                            if (tag === 'textarea') return 'textarea';
                            if (tag === 'select') return 'select';
                            if (tag === 'img') return 'img';
                            if (role) return role;
                            return tag;
                        } catch (e) { return 'unknown'; }
                    }
                    function truncate(str, len) {
                        if (!str) return '';
                        try { str = String(str).trim().replace(/\\s+/g, ' ');
                            return str.length > len ? str.substring(0, len) + '...' : str;
                        } catch (e) { return ''; }
                    }
                    function getElementText(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : '';
                            if (tag === 'input' || tag === 'textarea') {
                                return el.placeholder || (el.getAttribute && el.getAttribute('aria-label')) || el.name || '';
                            }
                            if (tag === 'img') return el.alt || el.title || '';
                            return el.innerText || el.textContent || '';
                        } catch (e) { return ''; }
                    }
                    function getElementInfo(el) {
                        try {
                            const ref = 'E' + (++refId);
                            window.__osaurus_refs.set(ref, el);
                            const type = getElementType(el);
                            const text = truncate(getElementText(el), 50);
                            let info = { ref, type, text };
                            try {
                                if (el.name) info.name = el.name;
                                if (el.id) info.id = truncate(el.id, 30);
                                if (el.value && el.tagName && el.tagName.toLowerCase() !== 'textarea') info.value = truncate(el.value, 30);
                                if (el.placeholder) info.placeholder = truncate(el.placeholder, 30);
                                if (el.href) info.href = truncate(el.href, 50);
                                if (el.checked) info.checked = true;
                                if (el.disabled) info.disabled = true;
                                if (el.required) info.required = true;
                                if (el.getAttribute && el.getAttribute('aria-label')) info.ariaLabel = truncate(el.getAttribute('aria-label'), 30);
                            } catch (attrError) {}
                            return info;
                        } catch (e) { return null; }
                    }
                    function matchesFilter(node) {
                        try {
                            if (!node || !node.tagName) return false;
                            if (!isInteractive(node)) return false;
                            if (!isVisible(node)) return false;
                            // The filter condition references `el` (plugin parity).
                            const el = node;
                            return !!(\(filterCondition));
                        } catch (e) { return false; }
                    }
                    // Recursive collector instead of a TreeWalker: descends
                    // into OPEN shadow roots and same-origin iframes (a
                    // TreeWalker sees neither). Cross-origin frames are
                    // listed so the model knows content exists it cannot reach.
                    const crossOriginFrames = [];
                    let hasMore = false;
                    let iterations = 0;
                    function collect(node) {
                        if (iterations++ > 10000) { hasMore = true; return; }
                        try {
                            if (matchesFilter(node)) {
                                if (results.length >= maxElements) { hasMore = true; return; }
                                const info = getElementInfo(node);
                                if (info) results.push(info);
                            }
                            if (node.shadowRoot) {
                                const kids = node.shadowRoot.children;
                                for (let i = 0; i < kids.length; i++) { collect(kids[i]); if (hasMore) return; }
                            }
                            if (node.tagName && node.tagName.toLowerCase() === 'iframe') {
                                let idoc = null;
                                try { idoc = node.contentDocument; } catch (e) { idoc = null; }
                                if (idoc && idoc.body) {
                                    collect(idoc.body);
                                    if (hasMore) return;
                                } else if (node.src) {
                                    crossOriginFrames.push(String(node.src).substring(0, 200));
                                }
                            }
                            const children = node.children;
                            if (children) {
                                for (let i = 0; i < children.length; i++) { collect(children[i]); if (hasMore) return; }
                            }
                        } catch (e) {}
                    }
                    collect(document.body);
                    return {
                        url: window.location.href || '',
                        title: document.title || '',
                        elementCount: results.length,
                        hasMore: hasMore,
                        elements: results,
                        crossOriginFrames: crossOriginFrames,
                        generation: \(currentGeneration),
                        bodyText: (function(){ try { return (document.body.innerText || '').substring(0, 500); } catch(e) { return ''; } })()
                    };
                } catch (e) {
                    return {error: 'Snapshot failed: ' + (e.message || String(e))};
                }
            })()
            """

        let result = await evaluateJavaScript(script)
        if let error = result.error { return "Error: \(error)" }
        if let dict = result.result as? [String: Any], let errorMsg = dict["error"] as? String {
            return "Error: \(errorMsg)"
        }
        guard let data = result.result as? [String: Any] else {
            return "Error: Failed to parse snapshot"
        }
        return BrowserSnapshotFormatter.format(data, detail: detail)
    }

    // MARK: - Page text

    /// Readability-style main-content extraction: the layout-aware text of
    /// `<main>` / `<article>` (falling back to `<body>`), full length — the
    /// executor paginates. Snapshots only show interactive elements; this is
    /// how the child actually READS a page.
    func readPageText() async -> (text: String?, error: String?) {
        guard hasNavigated else {
            return (nil, "No page loaded. Call browser_navigate first to load a page.")
        }
        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {error: 'Page not ready - document.body is null.'};
                    }
                    const root = document.querySelector('main, article, [role="main"]') || document.body;
                    // innerText is layout-aware: skips display:none content and
                    // preserves visual line structure.
                    const text = (root.innerText || root.textContent || '')
                        .replace(/\\n{3,}/g, '\\n\\n')
                        .trim();
                    return {text: text};
                } catch (e) {
                    return {error: 'Read failed: ' + (e.message || String(e))};
                }
            })()
            """
        let result = await evaluateJavaScript(script)
        if let error = result.error { return (nil, "JavaScript error: \(error)") }
        guard let dict = result.result as? [String: Any] else {
            return (nil, "Failed to read page text.")
        }
        if let error = dict["error"] as? String { return (nil, error) }
        return (dict["text"] as? String ?? "", nil)
    }

    // MARK: - Element interactions

    private func refPreamble(ref: String?, selector: String?, target: inout String) -> String? {
        // Returns the JS expression that resolves the element, or nil when
        // neither ref nor selector was provided.
        if let ref {
            target = "window.__osaurus_refs?.get('\(ref)')"
            return """
                if (!window.__osaurus_refs) { return {success:false, error:'No snapshot taken. Call browser_snapshot first.'}; }
                if (window.__osaurus_snapshot_gen !== \(snapshotGeneration)) { return {success:false, error:'Snapshot is stale. Call browser_snapshot again.'}; }
                """
        } else if let selector {
            target = "document.querySelector('\(browserEscapeSelector(selector))')"
            return ""
        }
        return nil
    }

    private func decode(_ result: (result: Any?, error: String?)) -> (success: Bool, error: String?) {
        if let error = result.error { return (false, "JavaScript error: \(error)") }
        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success { return (true, nil) }
            if let error = dict["error"] as? String { return (false, error) }
        }
        return (false, "Unknown error. Call browser_snapshot to refresh element refs.")
    }

    /// Best-effort human label for an element (text / value / aria-label),
    /// used to classify click targets ("Submit", "Buy now") BEFORE gating and
    /// to render the confirm card. Read-only; returns nil when unresolvable.
    func elementLabel(ref: String?, selector: String?) async -> String? {
        guard hasNavigated else { return nil }
        let getEl: String
        if let ref {
            getEl = "window.__osaurus_refs?.get('\(ref)')"
        } else if let selector {
            getEl = "document.querySelector('\(browserEscapeSelector(selector))')"
        } else {
            return nil
        }
        let script = """
            (function() {
                try {
                    const el = \(getEl);
                    if (!el) return null;
                    const text = el.innerText || el.value || (el.getAttribute && el.getAttribute('aria-label')) || '';
                    return String(text).trim().replace(/\\s+/g, ' ').substring(0, 80);
                } catch (e) { return null; }
            })()
            """
        let result = await evaluateJavaScript(script)
        let label = (result.result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty ?? true) ? nil : label
    }

    func clickElement(ref: String?, selector: String?) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        var getEl = ""
        guard let validation = refPreamble(ref: ref, selector: selector, target: &getEl) else {
            return (false, "Either ref or selector must be provided")
        }
        let script = """
            (function() {
                try {
                    if (!document || !document.body) { return {success:false, error:'Page not ready.'}; }
                    \(validation)
                    const el = \(getEl);
                    if (!el) { return {success:false, error:'Element not found. Call browser_snapshot for refs.'}; }
                    if (!document.body.contains(el)) { return {success:false, error:'Element no longer in DOM. Call browser_snapshot.'}; }
                    el.scrollIntoView({block:'center', behavior:'instant'});
                    el.click();
                    return {success:true};
                } catch (e) { return {success:false, error:'Click failed: ' + (e.message || String(e))}; }
            })()
            """
        return decode(await evaluateJavaScript(script))
    }

    func typeText(
        ref: String?, selector: String?, text: String, clear: Bool, submit: Bool
    ) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        var getEl = ""
        guard let validation = refPreamble(ref: ref, selector: selector, target: &getEl) else {
            return (false, "Either ref or selector must be provided")
        }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = """
            (function() {
                try {
                    if (!document || !document.body) { return {success:false, error:'Page not ready.'}; }
                    \(validation)
                    const el = \(getEl);
                    if (!el) { return {success:false, error:'Element not found. Call browser_snapshot.'}; }
                    if (!document.body.contains(el)) { return {success:false, error:'Element no longer in DOM.'}; }
                    el.scrollIntoView({block:'center', behavior:'instant'});
                    el.focus();
                    if (el.getAttribute('contenteditable') === 'true') {
                        if (\(clear)) el.innerHTML = '';
                        el.innerHTML += '\(escaped)';
                    } else {
                        if (\(clear)) el.value = '';
                        el.value += '\(escaped)';
                    }
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    if (\(submit)) {
                        const form = el.closest('form');
                        if (form) { form.submit(); }
                        else {
                            el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', bubbles:true}));
                            el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', bubbles:true}));
                        }
                    }
                    return {success:true};
                } catch (e) { return {success:false, error:'Type failed: ' + (e.message || String(e))}; }
            })()
            """
        return decode(await evaluateJavaScript(script))
    }

    func selectOption(ref: String?, selector: String?, values: [String]) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        var getEl = ""
        guard let validation = refPreamble(ref: ref, selector: selector, target: &getEl) else {
            return (false, "Either ref or selector must be provided")
        }
        let valuesJSON = values
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
            .joined(separator: ",")
        let script = """
            (function() {
                try {
                    if (!document || !document.body) { return {success:false, error:'Page not ready.'}; }
                    \(validation)
                    const el = \(getEl);
                    if (!el) { return {success:false, error:'Element not found.'}; }
                    if (!el.tagName || el.tagName.toLowerCase() !== 'select') { return {success:false, error:'Element is not a <select>.'}; }
                    const values = [\(valuesJSON)];
                    let matched = false;
                    for (const opt of el.options) {
                        const shouldSelect = values.includes(opt.value) || values.includes(opt.text);
                        opt.selected = shouldSelect;
                        if (shouldSelect) matched = true;
                    }
                    if (!matched && values.length > 0) { return {success:false, error:'No matching options for: ' + values.join(', ')}; }
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return {success:true};
                } catch (e) { return {success:false, error:'Select failed: ' + (e.message || String(e))}; }
            })()
            """
        return decode(await evaluateJavaScript(script))
    }

    func hoverElement(ref: String?, selector: String?) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        var getEl = ""
        guard let validation = refPreamble(ref: ref, selector: selector, target: &getEl) else {
            return (false, "Either ref or selector must be provided")
        }
        let script = """
            (function() {
                try {
                    if (!document || !document.body) { return {success:false, error:'Page not ready.'}; }
                    \(validation)
                    const el = \(getEl);
                    if (!el) { return {success:false, error:'Element not found.'}; }
                    if (!document.body.contains(el)) { return {success:false, error:'Element no longer in DOM.'}; }
                    el.scrollIntoView({block:'center', behavior:'instant'});
                    const rect = el.getBoundingClientRect();
                    const x = rect.left + rect.width/2, y = rect.top + rect.height/2;
                    el.dispatchEvent(new MouseEvent('mouseenter', {bubbles:true, clientX:x, clientY:y}));
                    el.dispatchEvent(new MouseEvent('mouseover', {bubbles:true, clientX:x, clientY:y}));
                    el.dispatchEvent(new MouseEvent('mousemove', {bubbles:true, clientX:x, clientY:y}));
                    return {success:true};
                } catch (e) { return {success:false, error:'Hover failed: ' + (e.message || String(e))}; }
            })()
            """
        return decode(await evaluateJavaScript(script))
    }

    func scroll(direction: String?, ref: String?, x: Int?, y: Int?) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        let script: String
        if let ref {
            script = """
                (function() {
                    try {
                        if (!window.__osaurus_refs) { return {success:false, error:'No snapshot taken.'}; }
                        if (window.__osaurus_snapshot_gen !== \(snapshotGeneration)) { return {success:false, error:'Snapshot is stale.'}; }
                        const el = window.__osaurus_refs.get('\(ref)');
                        if (!el) { return {success:false, error:'Element ref not found.'}; }
                        el.scrollIntoView({behavior:'smooth', block:'center'});
                        return {success:true};
                    } catch (e) { return {success:false, error:'Scroll failed: ' + (e.message || String(e))}; }
                })()
                """
        } else if let direction {
            let amount: (x: Int, y: Int)
            switch direction.lowercased() {
            case "up": amount = (0, -400)
            case "down": amount = (0, 400)
            case "left": amount = (-400, 0)
            case "right": amount = (400, 0)
            default: amount = (0, 400)
            }
            script =
                "(function(){try{window.scrollBy({left:\(amount.x), top:\(amount.y), behavior:'smooth'});return {success:true};}catch(e){return {success:false, error:String(e)};}})()"
        } else if let x, let y {
            script =
                "(function(){try{window.scrollTo({left:\(x), top:\(y), behavior:'smooth'});return {success:true};}catch(e){return {success:false, error:String(e)};}})()"
        } else {
            return (false, "Provide direction, ref, or x/y coordinates")
        }
        let decoded = decode(await evaluateJavaScript(script))
        try? await Task.sleep(nanoseconds: 300_000_000)
        return decoded
    }

    func pressKey(key: String, modifiers: [String]) async -> (success: Bool, error: String?) {
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        let keyMap: [String: (key: String, code: String, keyCode: Int)] = [
            "enter": ("Enter", "Enter", 13), "escape": ("Escape", "Escape", 27),
            "tab": ("Tab", "Tab", 9), "backspace": ("Backspace", "Backspace", 8),
            "delete": ("Delete", "Delete", 46), "arrowup": ("ArrowUp", "ArrowUp", 38),
            "arrowdown": ("ArrowDown", "ArrowDown", 40), "arrowleft": ("ArrowLeft", "ArrowLeft", 37),
            "arrowright": ("ArrowRight", "ArrowRight", 39), "home": ("Home", "Home", 36),
            "end": ("End", "End", 35), "pageup": ("PageUp", "PageUp", 33),
            "pagedown": ("PageDown", "PageDown", 34), "space": (" ", "Space", 32),
        ]
        let keyInfo = keyMap[key.lowercased()]
            ?? (key, "Key\(key.uppercased())", Int(key.unicodeScalars.first?.value ?? 0))
        let ctrl = modifiers.contains("ctrl") || modifiers.contains("control")
        let shift = modifiers.contains("shift")
        let alt = modifiers.contains("alt") || modifiers.contains("option")
        let meta = modifiers.contains("meta") || modifiers.contains("cmd") || modifiers.contains("command")
        let script = """
            (function() {
                try {
                    const target = document.activeElement || document.body;
                    const opts = {key:'\(keyInfo.key)', code:'\(keyInfo.code)', keyCode:\(keyInfo.keyCode), which:\(keyInfo.keyCode), bubbles:true, cancelable:true, ctrlKey:\(ctrl), shiftKey:\(shift), altKey:\(alt), metaKey:\(meta)};
                    target.dispatchEvent(new KeyboardEvent('keydown', opts));
                    target.dispatchEvent(new KeyboardEvent('keypress', opts));
                    target.dispatchEvent(new KeyboardEvent('keyup', opts));
                    return {success:true};
                } catch (e) { return {success:false, error:'Key press failed: ' + (e.message || String(e))}; }
            })()
            """
        return decode(await evaluateJavaScript(script))
    }

    func waitFor(
        text: String?, textGone: String?, time: TimeInterval?, timeout: TimeInterval
    ) async -> (success: Bool, error: String?) {
        if let time {
            try? await Task.sleep(nanoseconds: UInt64(time * 1_000_000_000))
            return (true, nil)
        }
        guard hasNavigated else { return (false, "No page loaded. Call browser_navigate first.") }
        let start = Date()
        if let text {
            let escaped = browserEscapeSelector(text)
            while Date().timeIntervalSince(start) < timeout {
                let script =
                    "(function(){try{if(!document.body)return false;return document.body.innerText.includes('\(escaped)');}catch(e){return false;}})()"
                let result = await evaluateJavaScript(script)
                if let found = result.result as? Bool, found { return (true, nil) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return (false, "Timeout after \(Int(timeout))s waiting for text: '\(text)'.")
        }
        if let textGone {
            let escaped = browserEscapeSelector(textGone)
            while Date().timeIntervalSince(start) < timeout {
                let script =
                    "(function(){try{if(!document.body)return true;return !document.body.innerText.includes('\(escaped)');}catch(e){return true;}})()"
                let result = await evaluateJavaScript(script)
                if let gone = result.result as? Bool, gone { return (true, nil) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return (false, "Timeout after \(Int(timeout))s waiting for text to disappear: '\(textGone)'")
        }
        return (false, "Provide text, text_gone, or time parameter")
    }

    // MARK: - Inspection

    func consoleMessages(level: String?, since: Double?, clear: Bool) async -> [[String: Any]] {
        let result = await evaluateJavaScript("(function(){try{return window.__osaurus_console||[];}catch(e){return [];}})()")
        var messages = (result.result as? [[String: Any]]) ?? []
        let levelFilter = level?.lowercased() ?? "all"
        if levelFilter != "all" {
            messages = messages.filter { (($0["level"] as? String)?.lowercased() ?? "") == levelFilter }
        }
        if let since {
            let cutoff = since * 1000
            messages = messages.filter { (($0["timestamp"] as? Double) ?? 0) >= cutoff }
        }
        if clear { _ = await evaluateJavaScript("window.__osaurus_console = [];") }
        return messages
    }

    func networkRequests(
        failedOnly: Bool, methodFilter: String?, urlContains: String?, clear: Bool
    ) async -> [[String: Any]] {
        let result = await evaluateJavaScript("(function(){try{return window.__osaurus_network||[];}catch(e){return [];}})()")
        var requests = (result.result as? [[String: Any]]) ?? []
        if failedOnly {
            requests = requests.filter {
                let status = $0["status"] as? Int ?? 0
                return status == 0 || !(200...399 ~= status)
            }
        }
        if let m = methodFilter?.uppercased() { requests = requests.filter { ($0["method"] as? String) == m } }
        if let needle = urlContains?.lowercased() {
            requests = requests.filter { ($0["url"] as? String)?.lowercased().contains(needle) ?? false }
        }
        if clear { _ = await evaluateJavaScript("window.__osaurus_network = [];") }
        return requests
    }

    // MARK: - Cookies

    private func cookieStore() -> WKHTTPCookieStore? {
        webView?.configuration.websiteDataStore.httpCookieStore
    }

    func getCookies(domain: String?) async -> [[String: Any]] {
        guard let store = cookieStore() else { return [] }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        let filtered = domain.map { d in cookies.filter { $0.domain.contains(d) } } ?? cookies
        return filtered.map { c in
            [
                "name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                "secure": c.isSecure, "http_only": c.isHTTPOnly,
                "expires": c.expiresDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            ]
        }
    }

    func setCookie(_ props: [String: Any]) async -> (ok: Bool, error: String?) {
        guard let store = cookieStore() else { return (false, "Browser session was torn down.") }
        guard let name = props["name"] as? String,
            let value = props["value"] as? String,
            let domain = props["domain"] as? String
        else { return (false, "name, value, and domain are required") }
        var attrs: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain,
            .path: (props["path"] as? String) ?? "/",
        ]
        if let secure = props["secure"] as? Bool, secure { attrs[.secure] = "TRUE" }
        if let expires = props["expires"] as? Double { attrs[.expires] = Date(timeIntervalSince1970: expires) }
        guard let cookie = HTTPCookie(properties: attrs) else {
            return (false, "Failed to construct cookie from properties")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.setCookie(cookie) { continuation.resume() }
        }
        return (true, nil)
    }

    func clearCookies(domain: String?) async {
        guard let store = cookieStore() else { return }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { all in
                let filtered = domain.map { d in all.filter { $0.domain.contains(d) } } ?? all
                continuation.resume(returning: filtered)
            }
        }
        for cookie in cookies {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    // MARK: - Screenshot

    func takeScreenshot(fullPage: Bool) async -> Data? {
        guard hasNavigated, let webView else { return nil }
        let config = WKSnapshotConfiguration()
        if fullPage {
            let dimensionScript = """
                (function() {
                    try {
                        if (!document || !document.body) { return JSON.stringify({width: 1280, height: 800}); }
                        return JSON.stringify({
                            width: Math.max(document.body.scrollWidth || 1280, 1280),
                            height: Math.max(document.body.scrollHeight || 800, 800)
                        });
                    } catch (e) { return JSON.stringify({width: 1280, height: 800}); }
                })()
                """
            let result = await evaluateJavaScript(dimensionScript)
            if let jsonString = result.result as? String,
                let data = jsonString.data(using: .utf8),
                let dimensions = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                let width = dimensions["width"],
                let height = dimensions["height"]
            {
                // Cap dimensions to prevent memory issues.
                config.rect = CGRect(x: 0, y: 0, width: min(width, 8000), height: min(height, 8000))
            }
        }
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    // MARK: - Arbitrary script

    func executeScript(_ userScript: String) async -> (result: Any?, error: String?) {
        let safe = """
            (function() {
                try { return {result: (function() { \(userScript) })()}; }
                catch (e) { return {error: e.message || String(e)}; }
            })()
            """
        let out = await evaluateJavaScript(safe)
        if let error = out.error { return (nil, error) }
        if let dict = out.result as? [String: Any] {
            if let errorMsg = dict["error"] as? String { return (nil, errorMsg) }
            return (dict["result"], nil)
        }
        return (out.result, nil)
    }

    // MARK: - Properties

    var currentURL: String? { webView?.url?.absoluteString }
    var currentTitle: String? { webView?.title }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Scheme policy applies to EVERY load — tool navigations, redirects,
        // JS-driven navigation, and clicked links (main frame and subframes).
        if let reason = Self.navigationRefusalReason(for: navigationAction.request.url) {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame != false {
                resumeNavigation(with: BrowserNavigationBlocked(reason: reason))
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // Non-renderable responses are file downloads; unsupported for now —
        // fail with a typed reason instead of silently doing nothing.
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame {
                let mime = (navigationResponse.response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "Content-Type") ?? "unknown type"
                resumeNavigation(
                    with: BrowserNavigationBlocked(
                        reason:
                            "The page responded with a file download (\(mime)). Downloads aren't supported in the agent browser."
                    ))
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard belongsToPendingNavigate(navigation) else { return }
        resumeNavigation(with: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard belongsToPendingNavigate(navigation) else { return }
        resumeNavigation(with: error)
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        guard belongsToPendingNavigate(navigation) else { return }
        resumeNavigation(with: error)
    }

    /// A superseded load's terminal callback (e.g. the -999 cancellation
    /// WebKit fires when a new load replaces a provisional one) carries the
    /// OLD `WKNavigation` and must not resolve the pending navigate's
    /// continuation. Callbacks with a nil navigation are accepted — better a
    /// resolved awaiter than a hang.
    private func belongsToPendingNavigate(_ navigation: WKNavigation?) -> Bool {
        guard let currentNavigation, let navigation else { return true }
        return navigation === currentNavigation
    }

    private func resumeNavigation(with error: Error?) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        currentNavigation = nil
        continuation.resume(returning: error)
    }

    // MARK: - WKUIDelegate (new windows / uploads)

    /// `target="_blank"` links and `window.open` land here. There are no tabs
    /// in the agent browser, so load the request in the SAME webview (subject
    /// to the scheme policy) — without this, new-window links silently no-op.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
            Self.navigationRefusalReason(for: url) == nil
        {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// File inputs can't hand the page local files (that would be a local-file
    /// exfiltration channel); decline the chooser but record it so the model
    /// sees WHY the upload did nothing via `browser_handle_dialog status`.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        lastDialog = [
            "kind": "file_chooser",
            "message":
                "The page opened a file chooser. File uploads aren't supported in the agent browser; the chooser was dismissed.",
            "timestamp": Date().timeIntervalSince1970,
        ]
        completionHandler(nil)
    }

    // MARK: - Dialogs

    func setDialogPolicy(accept: Bool, promptText: String?) {
        pendingDialogPolicy = DialogPolicy(accept: accept, promptText: promptText)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
        lastDialog = ["kind": "alert", "message": message, "timestamp": Date().timeIntervalSince1970]
        completionHandler()
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
        let accept = pendingDialogPolicy.accept
        lastDialog = [
            "kind": "confirm", "message": message,
            "timestamp": Date().timeIntervalSince1970, "accepted": accept,
        ]
        pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
        completionHandler(accept)
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let text = pendingDialogPolicy.accept ? (pendingDialogPolicy.promptText ?? defaultText ?? "") : nil
        lastDialog = [
            "kind": "prompt", "message": prompt, "default_text": defaultText ?? "",
            "response": text as Any? ?? NSNull(), "timestamp": Date().timeIntervalSince1970,
        ]
        pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
        completionHandler(text)
    }
}
