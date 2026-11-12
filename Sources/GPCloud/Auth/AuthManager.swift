import Foundation
import GPCloudKit
import WebKit

/// Auth model.
///
/// GP Cloud's web app is Next.js + NextAuth. Signing in on gpcloud.grameenphone.com (phone →
/// password/OTP → optional 2FA → OAuth PKCE `authorize` → code exchange) ends with an HttpOnly
/// NextAuth session cookie. `GET /api/auth/session` then returns `{ user, expires, accessToken }`,
/// and NextAuth refreshes the access token server-side when it expires.
///
/// So the app embeds the real login page in a WKWebView (persistent website data store), and
/// reads the access token by calling `/api/auth/session` from inside a hidden same-origin web view
/// sharing that store. No password ever touches this app's code; refresh is handled by the server.
@MainActor
final class AuthManager: NSObject, ObservableObject, TokenProvider {
    enum State: Equatable { case checking, signedOut, signedIn }

    /// Network / WebKit trouble: retryable, must NOT sign the user out.
    struct TransientError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Couldn't reach GP Cloud (\(reason)). Check your connection and try again." }
    }

    @Published private(set) var state: State = .checking
    @Published var showingLogin = false
    @Published var lastError: String?

    /// Shared configuration so the visible login view and the hidden token view share cookies.
    let webConfiguration: WKWebViewConfiguration = {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        return c
    }()

    private lazy var tokenWebView: WKWebView = {
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 10, height: 10), configuration: webConfiguration)
        wv.navigationDelegate = self
        return wv
    }()

    private var tokenPageReady = false
    private var pageWaiters: [CheckedContinuation<Void, Error>] = []
    private var pageLoadAttempt = 0
    private var cachedToken: String?
    private var cachedExpiry: Date = .distantPast
    private var refreshTask: Task<String, Error>?
    private var loginCheckInFlight = false
    /// Bumped on sign-out so in-flight fetches can't repopulate the cache afterwards.
    private var sessionGeneration = 0

    override init() {
        super.init()
        if DemoMode.enabled { state = .signedIn; return }
        Task { await bootstrap() }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        state = .checking
        lastError = nil
        do {
            _ = try await fetchToken()
            state = .signedIn
        } catch let e as TransientError {
            lastError = e.localizedDescription
            state = .signedOut
        } catch {
            state = .signedOut
        }
    }

    func beginLogin() {
        lastError = nil
        showingLogin = true
    }

    /// Called by the login web view on every navigation / client-side route change.
    /// Instead of guessing which URL means "logged in", just ask the session whenever we're on GP Cloud.
    func loginWebViewDidNavigate(to url: URL?) {
        guard state != .signedIn, !loginCheckInFlight,
              let url, url.host == GPCloudAPI.webOrigin.host,
              !url.path.hasPrefix("/api/") else { return }
        loginCheckInFlight = true
        Task {
            defer { loginCheckInFlight = false }
            if (try? await fetchToken()) != nil {
                state = .signedIn
                showingLogin = false
                lastError = nil
            }
        }
    }

    func signOut() async {
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        cachedToken = nil
        cachedExpiry = .distantPast
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let ours = records.filter { $0.displayName.contains("grameenphone") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: ours)
        tokenPageReady = false
        state = .signedOut
    }

    // MARK: - TokenProvider

    nonisolated func accessToken(forceRefresh: Bool) async throws -> String {
        try await MainActor.run { () -> Task<String, Error> in
            if !forceRefresh, let t = self.cachedToken, self.cachedExpiry.timeIntervalSinceNow > 60 {
                return Task { t }
            }
            if let existing = self.refreshTask { return existing }
            let task = Task { @MainActor () throws -> String in
                defer { self.refreshTask = nil }
                do {
                    return try await self.fetchToken()
                } catch is TransientError {
                    throw GPCloudError.api("Couldn't reach GP Cloud. Check your connection.")
                } catch {
                    if self.state == .signedIn { self.state = .signedOut }
                    throw GPCloudError.notSignedIn
                }
            }
            self.refreshTask = task
            return task
        }.value
    }

    /// The gateway rejected a token twice. Re-check the session itself: if it's really gone, sign out.
    nonisolated func tokenRejected() async {
        await recheckSessionAfterRejection()
    }

    private func recheckSessionAfterRejection() async {
        do {
            _ = try await fetchToken()
        } catch is TransientError {
            // Network trouble: keep the session.
        } catch {
            if state == .signedIn { state = .signedOut }
        }
    }

    // MARK: - Session fetch via hidden web view

    /// Throws `GPCloudError.notSignedIn` only when the session definitively has no token;
    /// anything else (timeouts, network, WebKit) is a `TransientError`.
    private func fetchToken() async throws -> String {
        let generation = sessionGeneration
        do {
            try await ensureTokenPage()
        } catch {
            tokenPageReady = false
            throw TransientError(reason: "page load: \(error.localizedDescription)")
        }
        // The fetch carries its own 15 s abort so callAsyncJavaScript always settles.
        let js = """
        const ctl = new AbortController();
        const timer = setTimeout(() => ctl.abort(), 15000);
        try {
          const r = await fetch('/api/auth/session', { credentials: 'include', cache: 'no-store', signal: ctl.signal });
          if (!r.ok) return { kind: 'transient', reason: 'HTTP ' + r.status };
          const s = await r.json();
          if (!s || s.error || !s.accessToken) return { kind: 'signedOut' };
          return { kind: 'ok', token: s.accessToken };
        } catch (e) {
          return { kind: 'transient', reason: String(e) };
        } finally { clearTimeout(timer); }
        """
        let raw: Any?
        do {
            raw = try await tokenWebView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient)
        } catch {
            tokenPageReady = false
            throw TransientError(reason: error.localizedDescription)
        }
        let result = raw as? [String: Any]
        switch result?["kind"] as? String {
        case "ok":
            guard let token = result?["token"] as? String, !token.isEmpty else { throw GPCloudError.notSignedIn }
            guard generation == sessionGeneration else { throw GPCloudError.notSignedIn }
            cachedToken = token
            cachedExpiry = Self.jwtExpiry(token) ?? Date().addingTimeInterval(5 * 60)
            return token
        case "signedOut":
            throw GPCloudError.notSignedIn
        default:
            throw TransientError(reason: (result?["reason"] as? String) ?? "unexpected response")
        }
    }

    private func ensureTokenPage() async throws {
        if tokenPageReady { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pageWaiters.append(c)
            guard pageWaiters.count == 1 else { return }
            pageLoadAttempt += 1
            let attempt = pageLoadAttempt
            // Any same-origin URL works; robots.txt is tiny and doesn't run the SPA.
            tokenWebView.load(URLRequest(url: GPCloudAPI.webOrigin.appendingPathComponent("robots.txt"),
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
            // Hard stop so waiters can never hang.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if attempt == self.pageLoadAttempt, !self.pageWaiters.isEmpty {
                    self.tokenWebView.stopLoading()
                    self.resolvePageWaiters(TransientError(reason: "timed out"))
                }
            }
        }
    }

    private func resolvePageWaiters(_ error: Error?) {
        let waiters = pageWaiters
        pageWaiters.removeAll()
        tokenPageReady = (error == nil)
        for w in waiters { if let error { w.resume(throwing: error) } else { w.resume() } }
    }

    static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

extension AuthManager: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.resolvePageWaiters(nil) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resolvePageWaiters(error) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.resolvePageWaiters(error) }
    }
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.tokenPageReady = false
            self.resolvePageWaiters(TransientError(reason: "web content process ended"))
            self.tokenPageReady = false
        }
    }
}
