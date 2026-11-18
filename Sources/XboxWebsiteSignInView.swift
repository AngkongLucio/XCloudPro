import SwiftUI
import WebKit

/// Presents only the official Xbox/Microsoft authentication route.
/// It never reads or exports cookies, passwords, OAuth codes, or tokens.
struct XboxWebsiteSignInView: View {
    let onFinish: (String) -> Void

    @Environment(\\.dismiss) private var dismiss
    @State private var pageStatus = "Opening Microsoft sign-in…"
    @State private var didFinish = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
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
                Button("CLOSE") { finish("Sign-in was closed before the Xbox callback completed.") }
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)

            XboxLoginWebView(
                onStatus: { pageStatus = $0 },
                onAuthenticated: {
                    finish("Microsoft returned to the official Xbox sign-in callback. Website sign-in completed; native Xbox Cloud credentials still need validation.")
                }
            )
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func finish(_ message: String) {
        guard !didFinish else { return }
        didFinish = true
        onFinish(message)
        dismiss()
    }
}

private struct XboxLoginWebView: UIViewRepresentable {
    let onStatus: (String) -> Void
    let onAuthenticated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus, onAuthenticated: onAuthenticated)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.isOpaque = false
        view.backgroundColor = .black

        // Xbox's own sign-in entry point; return to its loggedIn callback,
        // not to the full Xbox Cloud Gaming website.
        var components = URLComponents(string: "https://www.xbox.com/en-US/auth/msa")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "logIn"),
            URLQueryItem(name: "returnUrl", value: "https://www.xbox.com/en-US/auth/msa?action=loggedIn")
        ]
        if let url = components.url {
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onStatus: (String) -> Void
        private let onAuthenticated: () -> Void
        private var didAuthenticate = false

        init(onStatus: @escaping (String) -> Void, onAuthenticated: @escaping () -> Void) {
            self.onStatus = onStatus
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onStatus("Connecting to Microsoft securely…") }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onStatus("Microsoft sign-in page ready") }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.onStatus("Sign-in page error: \\(error.localizedDescription)") }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard
                let url = navigationAction.request.url,
                url.host?.lowercased() == "www.xbox.com",
                url.path.lowercased() == "/en-us/auth/msa",
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name.lowercased() == "action" && $0.value?.lowercased() == "loggedin"
                }) == true
            else {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            guard !didAuthenticate else { return }
            didAuthenticate = true
            DispatchQueue.main.async { self.onAuthenticated() }
        }
    }
}
