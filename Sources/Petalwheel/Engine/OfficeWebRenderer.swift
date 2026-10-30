import AppKit
import WebKit
import PDFKit

/// Offscreen WKWebView that renders a local HTML file (Quick Look previews, combined EPUB chapters)
/// to PDF. Page JavaScript is disabled and every non-local request is blocked.
@MainActor
final class OfficeWebRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?
    private var ruleStoreDir: URL?
    private var loadID = 0

    init(width: CGFloat, height: CGFloat = 1000) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        webView = WKWebView(frame: frame, configuration: config)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = NSView(frame: frame)
        window.contentView?.addSubview(webView)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
    }

    deinit {
        if let dir = ruleStoreDir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Loading

    /// Loads `file`, allowing reads inside `readAccess`. Resolves once the page (and its images) loaded.
    func load(_ file: URL, readAccess: URL, extraCSS: String? = nil, timeout: Double = 90) async throws {
        if ruleStoreDir == nil { try await installRemoteBlocker() }
        webView.configuration.userContentController.removeAllUserScripts()
        if let extraCSS {
            let script = WKUserScript(source: """
                (function(){var s=document.createElement('style');s.textContent=\(Self.jsString(extraCSS));
                (document.head||document.documentElement).appendChild(s);})();
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadContinuation = c
            loadID += 1
            let id = loadID
            // Both paths must agree on symlinks (/var → /private/var) or WebKit silently never loads.
            webView.loadFileURL(file.resolvingSymlinksInPath(), allowingReadAccessTo: readAccess.resolvingSymlinksInPath())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.loadID == id else { return }
                self.finishLoad(NurToError(l: "Rendering “%@” timed out.", file.lastPathComponent))
            }
        }
        // Give decoders (PDF/SVG images, web fonts) a moment to settle.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func finishLoad(_ error: Error?) {
        guard let c = loadContinuation else { return }
        loadContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoad(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { finishLoad(error) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { finishLoad(NurToError(l: "The renderer stopped unexpectedly.")) }
    }

    /// Only file: and data: URLs may load (no tracking pixels / remote fonts from documents).
    private func installRemoteBlocker() async throws {
        let dir = try OutputNaming.tempDirectory()
        ruleStoreDir = dir
        guard let store = WKContentRuleListStore(url: dir) else { return }
        let rules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """
        if let list = try await store.compileContentRuleList(forIdentifier: "petalwheel-local-only", encodedContentRuleList: rules) {
            webView.configuration.userContentController.add(list)
        }
    }

    // MARK: Scripting

    func evaluate(_ js: String) async throws -> Any? {
        try await webView.evaluateJavaScript(js)
    }

    func evaluateJSON<T: Decodable>(_ js: String, as type: T.Type) async throws -> T {
        guard let s = try await evaluate(js) as? String, let data = s.data(using: .utf8) else {
            throw NurToError(l: "Couldn't read the rendered document.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Full document size in CSS pixels.
    func contentSize() async throws -> CGSize {
        let size = try await evaluateJSON("""
            JSON.stringify([Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0),
                            Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)])
            """, as: [Double].self)
        return CGSize(width: size.first ?? 0, height: size.count > 1 ? size[1] : 0)
    }

    /// Resizes the view so that view coordinates equal document coordinates.
    func resize(to size: CGSize) async throws {
        let frame = CGRect(origin: .zero, size: CGSize(width: max(1, size.width), height: max(1, size.height)))
        window.setContentSize(frame.size)
        window.contentView?.frame = frame
        webView.frame = frame
        webView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    // MARK: Output

    /// A one-page PDF of `rect` (view coordinates; keep it near the top of the document,
    /// WebKit can stall on rectangles far down a very tall page).
    func pdfPage(_ rect: CGRect) async throws -> Data {
        let config = WKPDFConfiguration()
        config.rect = rect
        return try await webView.pdf(configuration: config)
    }

    /// Paginated PDF through AppKit printing (respects CSS page breaks).
    func printPDF(to output: URL, paperSize: CGSize, margin: CGFloat, fitWidth: Bool = false) async throws {
        let info = NSPrintInfo()
        info.paperSize = paperSize
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = fitWidth ? .fit : .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = webView.bounds
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            printContinuation = c
            op.runModal(for: window, delegate: self,
                        didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard ok, FileManager.default.fileExists(atPath: output.path) else {
            throw NurToError(l: "Couldn't print “%@”.", output.lastPathComponent)
        }
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printContinuation?.resume(returning: success)
        printContinuation = nil
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
