import SwiftUI
import WebKit

/// Microsoft OAuth WebView used by the XAL flow.
/// This mirrors XStreaming: load Sisu's MsaOauthRedirect and intercept
/// the ms-xal custom-scheme callback without reading cookies or credentials.
struct XboxXALSignInView: View {
    let authorizationURL: URL
    let onRedirect: (URL) -> Void
    let onCancel: () -> Void

    @State private var pageStatus = "Opening Microsoft sign-in…"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "xbox.logo")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.35))
                VStack(alignment: .leading, spacing: 3) {
                    Text("MICROSOFT SIGN-IN")
                        .font(.system(size: 12, weight: .black))
                        .tracking(1)
                    Text(pageStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("CANCEL", action: onCancel)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)

            XALAuthorizationWebView(
                authorizationURL: authorizationURL,
                onStatus: { pageStatus = $0 },
                onRedirect: onRedirect
            )
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

private struct XALAuthorizationWebView: UIViewRepresentable {
    let authorizationURL: URL
    let onStatus: (String) -> Void
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus, onRedirect: onRedirect)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.load(URLRequest(url: authorizationURL, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onStatus: (String) -> Void
        private let onRedirect: (URL) -> Void
        private var didRedirect = false

        init(onStatus: @escaping (String) -> Void, onRedirect: @escaping (URL) -> Void) {
            self.onStatus = onStatus
            self.onRedirect = onRedirect
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onStatus("Connecting to Microsoft securely…") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onStatus("Microsoft sign-in page ready") }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onStatus("Sign-in page error: \(error.localizedDescription)") }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  url.scheme?.lowercased() == "ms-xal-000000004c20a908" else {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            guard !didRedirect else { return }
            didRedirect = true
            DispatchQueue.main.async { self.onRedirect(url) }
        }
    }
}
