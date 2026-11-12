import GPCloudKit
import SwiftUI
import WebKit

struct WelcomeView: View {
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 72))
                .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                Text("GP Cloud").font(.largeTitle.weight(.semibold))
                Text("Your Grameenphone cloud storage, on your Mac.")
                    .foregroundStyle(.secondary)
            }
            if auth.state == .checking {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    auth.beginLogin()
                } label: {
                    Text("Sign in").frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            if let err = auth.lastError {
                Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try Again") { Task { await auth.bootstrap() } }.buttonStyle(.link)
            }
            Text("You'll sign in on Grameenphone's own page. This app never sees your password.")
                .font(.caption).foregroundStyle(.tertiary)
            Text("Unofficial client · not affiliated with or endorsed by Grameenphone")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $auth.showingLogin) {
            LoginSheet().environmentObject(auth)
        }
    }
}

struct LoginSheet: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text("gpcloud.grameenphone.com").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            LoginWebView(configuration: auth.webConfiguration) { url in
                auth.loginWebViewDidNavigate(to: url)
            }
        }
        .frame(width: 480, height: 720)
    }
}

struct LoginWebView: NSViewRepresentable {
    let configuration: WKWebViewConfiguration
    let onURLChange: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onURLChange: onURLChange) }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: configuration)
        wv.navigationDelegate = context.coordinator
        // Next.js routes client-side, so watch the URL itself, not just page loads.
        context.coordinator.observation = wv.observe(\.url, options: [.new]) { webView, _ in
            let url = webView.url
            DispatchQueue.main.async { context.coordinator.onURLChange(url) }
        }
        wv.load(URLRequest(url: GPCloudAPI.webOrigin))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onURLChange: (URL?) -> Void
        var observation: NSKeyValueObservation?
        init(onURLChange: @escaping (URL?) -> Void) { self.onURLChange = onURLChange }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onURLChange(webView.url) }

        // Open links that leave GP Cloud (terms, app stores) in the default browser.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, action.navigationType == .linkActivated,
               let host = url.host, !host.hasSuffix("grameenphone.com") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
