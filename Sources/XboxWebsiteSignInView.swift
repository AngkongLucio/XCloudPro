import SwiftUI
import WebKit

/// A persistent Xbox website sign-in surface. It intentionally reports only
/// cookie presence and domain names; cookie values and authentication secrets
/// are never read, copied, logged, or passed into the native streaming stack.
struct XboxWebsiteSignInView: View {
    let onFinish: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var pageStatus = "Opening xbox.com/play…"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "xbox.logo")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text("XBOX WEBSITE SIGN-IN")
                        .font(.system(size: 12, weight: .black))
                        .tracking(1.0)
                    Text(pageStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("CLOSE") {
                    dismiss()
                }
                .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)

            XboxWebsiteWebView(
                onCreated: { webView = $0 },
                onPageStatus: { pageStatus = $0 }
            )
            .background(Color.black)

            HStack(spacing: 12) {
                Text("Sign in only on the official Xbox/Microsoft page.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    checkWebsiteCookies()
                } label: {
                    Text("DONE / CHECK")
                        .font(.system(size: 10, weight: .black))
                        .tracking(0.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color(red: 0.20, green: 0.78, blue: 0.35), in: Capsule())
                }
                .disabled(webView == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func checkWebsiteCookies() {
        guard let webView else {
            onFinish("Xbox website did not finish opening. Try again.")
            dismiss()
            return
        }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let allowedDomains = ["xbox.com", "live.com", "microsoft.com"]
            let matchedDomains = Set(cookies.compactMap { cookie -> String? in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard allowedDomains.contains(where: { domain == $0 || domain.hasSuffix("." + $0) }) else {
                    return nil
                }
                return domain
            })

            DispatchQueue.main.async {
                if matchedDomains.isEmpty {
                    onFinish("No Xbox/Microsoft website cookies detected. Complete sign-in on xbox.com/play, then check again.")
                } else {
                    let domains = matchedDomains.sorted().joined(separator: ", ")
                    onFinish("Detected \(matchedDomains.count) Xbox/Microsoft cookie domain(s): \(domains). This confirms stored website data only—not a verified Xbox account or a native streaming token.")
                }
                dismiss()
            }
        }
    }
}

private struct XboxWebsiteWebView: UIViewRepresentable {
    let onCreated: (WKWebView) -> Void
    let onPageStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageStatus: onPageStatus)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .black
        onCreated(view)
        view.load(URLRequest(url: URL(string: "https://www.xbox.com/en-US/play")!))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onPageStatus: (String) -> Void

        init(onPageStatus: @escaping (String) -> Void) {
            self.onPageStatus = onPageStatus
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onPageStatus("Loading official Xbox website…")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.title") { [weak self] result, _ in
                let title = result as? String
                DispatchQueue.main.async {
                    self?.onPageStatus(title.map { "Loaded: \($0)" } ?? "Xbox website loaded")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onPageStatus("Page load failed: \(error.localizedDescription)")
        }
    }
}
