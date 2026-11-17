import SwiftUI
import WebKit

struct XboxWebView: UIViewRepresentable {
    let reloadToken: UUID

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Bundle the official Better xCloud userscript and the supplied redirect helper.
        // Both scripts are injected at document start; each script checks its own hostname/path.
        if let betterXCloudURL = Bundle.main.url(forResource: "better-xcloud.user", withExtension: "js"),
           let source = try? String(contentsOf: betterXCloudURL, encoding: .utf8) {
            let script = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }

        if let redirectURL = Bundle.main.url(forResource: "opt-out-play-xbox-com.user", withExtension: "js"),
           let source = try? String(contentsOf: redirectURL, encoding: .utf8) {
            let script = WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.load(URLRequest(
            url: URL(string: "https://www.xbox.com/play")!,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 30
        ))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        context.coordinator.lastReloadToken = reloadToken
        webView.reload()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastReloadToken = UUID()
    }
}
