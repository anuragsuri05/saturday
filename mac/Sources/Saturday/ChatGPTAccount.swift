import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// "Sign in with ChatGPT" for open-source and locally run apps: requests are paid from the user's
/// ChatGPT Plus/Pro plan, so no API key is needed.
/// Spec: https://developers.openai.com/siwc/token-sharing-open-source
@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    struct Credentials: Codable {
        var email: String
        var subject: String
        var clientID: String
        var idToken: String
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
    }

    struct ModelOption: Identifiable, Hashable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    @Published private(set) var credentials: Credentials?
    @Published private(set) var isSigningIn = false
    @Published private(set) var models: [ModelOption] = []
    @Published var lastError: String?

    var isSignedIn: Bool { credentials?.accessToken != nil }
    var planEnabled: Bool { isSignedIn && credentials?.scopes.contains(Self.planScope) == true }
    var hasSavedRegistration: Bool { credentials != nil }
    var email: String { credentials?.email ?? "" }

    private static let issuer = "https://auth.openai.com"
    private static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let resource = "https://api.openai.com/v1"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    private static let appName = "Saturday"

    private var server: LoopbackServer?
    private var refreshTask: Task<String, Error>?

    private init() {
        credentials = CredentialFile.load()
    }

    /// Opaque, stable ID for this Mac, created once before the first sign-in. Not a credential.
    private var hostID: String {
        if let id = UserDefaults.standard.string(forKey: "chatgptHostID") { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: "chatgptHostID")
        return id
    }

    // MARK: - Sign in

    /// Opens the browser for ChatGPT sign-in and waits for the loopback callback.
    /// `forceConsent` asks again for plan usage after the user declined it earlier.
    func signIn(forceConsent: Bool = false) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }

        do {
            let server = try await LoopbackServer.start()
            self.server = server
            defer {
                server.stop()
                self.server = nil
            }

            let redirectURI = "http://127.0.0.1:\(server.port)/auth/callback"
            let state = Self.randomToken()
            let nonce = Self.randomToken()
            let verifier = Self.randomToken(bytes: 48)
            let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            let saved = credentials

            var query: [(String, String)] = [
                ("client_id", saved?.clientID ?? "dynamic_agent_client"),
                ("ext_agent_host_id", hostID),
                ("response_type", "code"),
                ("redirect_uri", redirectURI),
                ("scope", Self.scopes),
                ("resource", Self.resource),
                ("state", state),
                ("nonce", nonce),
                ("code_challenge_method", "S256"),
                ("code_challenge", challenge),
            ]
            if let saved {
                query.append(("id_token_hint", saved.idToken))
                query.append(("login_hint", saved.email))
            } else {
                query.append(("agent_name_hint", Self.appName))
            }
            if forceConsent { query.append(("prompt", "consent")) }

            guard let url = URL(string: Self.authorizeURL + "?" + Self.formEncode(query)) else {
                throw AuthError("Couldn't build the sign-in link.")
            }
            NSWorkspace.shared.open(url)

            let callback = try await server.waitForCallback(timeout: 300)
            NSApp.activate(ignoringOtherApps: true)

            guard callback["state"] == state else { throw AuthError("The sign-in response didn't match. Please try again.") }
            if let error = callback["error"] {
                throw AuthError(error == "access_denied" ? "Sign-in was cancelled." : "Sign-in failed (\(error)).")
            }
            guard let code = callback["code"] else { throw AuthError("ChatGPT didn't return a sign-in code.") }

            let clientID: String
            if let saved {
                if let returned = callback["client_id"], returned != saved.clientID {
                    throw AuthError("ChatGPT returned a different app registration. Use “Use a different ChatGPT account” and sign in again.")
                }
                clientID = saved.clientID
            } else {
                guard let issued = callback["client_id"], issued != "dynamic_agent_client" else {
                    throw AuthError("Registration didn't finish. Please try again.")
                }
                clientID = issued
            }

            let tokens = try await Self.postForm(Self.tokenURL, [
                ("grant_type", "authorization_code"),
                ("client_id", clientID),
                ("code", code),
                ("code_verifier", verifier),
                ("redirect_uri", redirectURI),
                ("resource", Self.resource),
            ])
            guard let idToken = tokens["id_token"] as? String,
                  let accessToken = tokens["access_token"] as? String
            else { throw AuthError("ChatGPT didn't return sign-in tokens.") }

            let claims = try await IDToken.validate(idToken, clientID: clientID, nonce: nonce, issuer: Self.issuer)
            guard let subject = claims["sub"] as? String else { throw AuthError("The ID token has no account ID.") }
            if let saved, saved.subject != subject {
                throw AuthError("That's a different ChatGPT account. Use “Use a different ChatGPT account” to switch.")
            }

            let granted = (tokens["scope"] as? String ?? callback["scope"] ?? "").split(separator: " ").map(String.init)
            save(Credentials(
                email: claims["email"] as? String ?? saved?.email ?? "ChatGPT account",
                subject: subject,
                clientID: clientID,
                idToken: idToken,
                accessToken: accessToken,
                refreshToken: tokens["refresh_token"] as? String,
                expiresAt: Date().addingTimeInterval(Self.seconds(tokens["expires_in"])),
                scopes: granted
            ))

            if planEnabled {
                await loadModels()
                showWelcomeOnce()
            } else {
                lastError = "You're signed in, but plan sharing wasn't allowed. Click “Enable plan sharing” to finish."
            }
        } catch is CancellationError {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelSignIn() {
        server?.cancel()
    }

    /// Ends the renewable session but keeps the app registration for the next sign-in.
    func signOut() async {
        guard var saved = credentials else { return }
        if let refreshToken = saved.refreshToken, !(await Self.revoke(refreshToken, clientID: saved.clientID)) {
            lastError = "Signed out here, but ChatGPT didn't confirm. You can also disconnect Saturday in ChatGPT Settings."
        }
        saved.accessToken = nil
        saved.refreshToken = nil
        saved.expiresAt = nil
        save(saved)
        models = []
    }

    /// Forgets the saved registration so the next sign-in can use another ChatGPT account.
    func forgetAccount() async {
        await signOut()
        CredentialFile.delete()
        credentials = nil
        lastError = nil
    }

    // MARK: - Tokens

    /// A valid access token, refreshed shortly before it expires. Refreshes are serialized.
    func accessToken() async throws -> String {
        guard let saved = credentials, let token = saved.accessToken else {
            throw APIError.badResponse("Connect your account in Settings → Accounts first.")
        }
        if let expiry = saved.expiresAt, expiry.timeIntervalSinceNow > 300 { return token }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    nonisolated static func currentAccessToken() async throws -> String {
        try await shared.accessToken()
    }

    private func refresh() async throws -> String {
        guard var saved = credentials, let refreshToken = saved.refreshToken else {
            throw APIError.badResponse("Reconnect your account in Settings → Accounts.")
        }
        do {
            let tokens = try await Self.postForm(Self.tokenURL, [
                ("grant_type", "refresh_token"),
                ("client_id", saved.clientID),
                ("refresh_token", refreshToken),
                ("resource", Self.resource),
            ])
            guard let accessToken = tokens["access_token"] as? String else {
                throw AuthError("ChatGPT didn't return a new access token.")
            }
            saved.accessToken = accessToken
            if let rotated = tokens["refresh_token"] as? String { saved.refreshToken = rotated }
            saved.expiresAt = Date().addingTimeInterval(Self.seconds(tokens["expires_in"]))
            if let scope = tokens["scope"] as? String { saved.scopes = scope.split(separator: " ").map(String.init) }
            save(saved)
            return accessToken
        } catch let error as OAuthError where error.isTerminal {
            saved.accessToken = nil
            saved.refreshToken = nil
            saved.expiresAt = nil
            save(saved)
            throw APIError.badResponse("Your account sign-in expired. Reconnect it in Settings → Accounts.")
        }
    }

    /// Fetches the models this ChatGPT account can use and picks one if the current choice isn't available.
    func loadModels() async {
        guard planEnabled else { return }
        do {
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["models"] as? [[String: Any]] ?? []
            models = list.compactMap { model in
                guard model["visibility"] as? String == "list", let slug = model["slug"] as? String else { return nil }
                return ModelOption(slug: slug, name: model["display_name"] as? String ?? slug)
            }
            let settings = SettingsStore.shared
            if let first = models.first, !models.contains(where: { $0.slug == settings.openAIModel }) {
                settings.openAIModel = first.slug
            }
        } catch {
            // The model list is only for the picker; requests still work with the saved model.
        }
    }

    // MARK: - Helpers

    private func save(_ value: Credentials) {
        credentials = value
        CredentialFile.save(value)
    }

    private func showWelcomeOnce() {
        let key = "chatgptPlanWelcomeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "You're using your ChatGPT plan"
        alert.informativeText = "Saturday will use your ChatGPT plan for some answers. You can review usage and set limits anytime in ChatGPT Settings → Usage."
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }

    private static func seconds(_ value: Any?) -> TimeInterval {
        (value as? NSNumber)?.doubleValue ?? 3600
    }

    private static func randomToken(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64url(Data(bytes))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    private static func postForm(_ url: URL, _ fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let code = object["error"] as? String ?? (object["error"] as? [String: Any])?["code"] as? String
            let description = object["error_description"] as? String
                ?? (object["error"] as? [String: Any])?["message"] as? String
                ?? object["detail"] as? String
            throw OAuthError(status: status, code: code, description: description)
        }
        return object
    }

    /// Revokes the refresh token, retrying network and server errors a few times.
    private static func revoke(_ refreshToken: String, clientID: String) async -> Bool {
        for attempt in 0..<3 {
            do {
                let config = try await IDToken.openIDConfiguration(issuer: issuer)
                guard let endpoint = (config["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { return false }
                _ = try await postForm(endpoint, [
                    ("token", refreshToken),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", clientID),
                ])
                return true
            } catch let error as OAuthError where error.status < 500 {
                return false
            } catch {
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        return false
    }
}

struct AuthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct OAuthError: LocalizedError {
    let status: Int
    let code: String?
    let description: String?

    /// Refresh failures that mean the user has to sign in again.
    var isTerminal: Bool {
        guard let code else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }

    var errorDescription: String? {
        "ChatGPT sign-in error \(status)\(code.map { " (\($0))" } ?? ""): \(description ?? "no details")"
    }
}

/// Stores the ChatGPT registration and tokens in an owner-only file.
private enum CredentialFile {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Saturday", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("chatgpt-account.json")
    }

    static func load() -> ChatGPTAccount.Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChatGPTAccount.Credentials.self, from: data)
    }

    static func save(_ credentials: ChatGPTAccount.Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - ID token validation

enum IDToken {
    static func openIDConfiguration(issuer: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: issuer + "/.well-known/openid-configuration")!)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AuthError("Couldn't read ChatGPT's sign-in configuration.")
        }
        return object
    }

    /// Checks the RS256 signature against OpenAI's JWKS, then the issuer, audience, expiry and nonce.
    static func validate(_ token: String, clientID: String, nonce: String, issuer: String) async throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let header = json(decode(parts[0])), let claims = json(decode(parts[1])),
              let signature = decode(parts[2])
        else { throw AuthError("ChatGPT returned an unreadable ID token.") }
        guard header["alg"] as? String == "RS256" else { throw AuthError("Unsupported ID token signature.") }

        let config = try await openIDConfiguration(issuer: issuer)
        guard let jwksURL = (config["jwks_uri"] as? String).flatMap(URL.init(string:)) else {
            throw AuthError("ChatGPT's signing keys are unavailable.")
        }
        let (jwksData, _) = try await URLSession.shared.data(from: jwksURL)
        let keys = json(jwksData)?["keys"] as? [[String: Any]] ?? []
        let kid = header["kid"] as? String
        guard let jwk = keys.first(where: { kid == nil || $0["kid"] as? String == kid }),
              let modulus = (jwk["n"] as? String).flatMap(decode),
              let exponent = (jwk["e"] as? String).flatMap(decode)
        else { throw AuthError("No matching signing key for the ID token.") }

        let key = try rsaPublicKey(modulus: [UInt8](modulus), exponent: [UInt8](exponent))
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil) else {
            throw AuthError("The ID token signature is invalid.")
        }

        func trimmed(_ s: String?) -> String? { s.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } }
        guard trimmed(claims["iss"] as? String) == trimmed(issuer) else { throw AuthError("The ID token has the wrong issuer.") }
        let audience = claims["aud"] as? String == clientID || (claims["aud"] as? [String])?.contains(clientID) == true
        guard audience else { throw AuthError("The ID token was issued for a different app.") }
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: exp + 60) > Date() else {
            throw AuthError("The ID token has expired.")
        }
        guard claims["nonce"] as? String == nonce else { throw AuthError("The ID token doesn't match this sign-in.") }
        return claims
    }

    private static func decode(_ base64url: String) -> Data? {
        var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    private static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// Builds a PKCS#1 RSAPublicKey (DER) from the JWK modulus and exponent.
    private static func rsaPublicKey(modulus: [UInt8], exponent: [UInt8]) throws -> SecKey {
        func length(_ count: Int) -> [UInt8] {
            if count < 128 { return [UInt8(count)] }
            var bytes = withUnsafeBytes(of: count.bigEndian, Array.init)
            while bytes.first == 0 { bytes.removeFirst() }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        func integer(_ value: [UInt8]) -> [UInt8] {
            var value = Array(value.drop { $0 == 0 })
            if value.isEmpty || value[0] >= 0x80 { value.insert(0, at: 0) }
            return [0x02] + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        let der = [0x30] + length(body.count) + body
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, nil) else {
            throw AuthError("Couldn't read ChatGPT's signing key.")
        }
        return key
    }
}

// MARK: - Loopback callback server

/// Listens on 127.0.0.1 for the one OAuth redirect, then shuts down.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.saturday.oauth-callback")
    private var pending: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// Prefers port 1455, then nearby ports, then any free port (only the port may vary in the redirect URI).
    static func start() async throws -> LoopbackServer {
        var lastError: Error = AuthError("Couldn't start the sign-in listener.")
        for port: UInt16 in [1455, 1456, 1457, 0] {
            do { return try await start(port: port) } catch { lastError = error }
        }
        throw lastError
    }

    private static func start(port: UInt16) async throws -> LoopbackServer {
        let parameters = NWParameters.tcp
        let localPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: port)!
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: localPort)
        let listener = try NWListener(using: parameters)
        let server = LoopbackServer(listener: listener)
        listener.newConnectionHandler = { [weak server] connection in server?.handle(connection) }

        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !once.done { once.done = true; continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if !once.done { once.done = true; continuation.resume(throwing: error) }
                    listener.cancel()
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        server.port = listener.port?.rawValue ?? port
        return server
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let outcome = self.outcome {
                    continuation.resume(with: outcome)
                    return
                }
                self.pending = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(AuthError("Sign-in timed out. Please try again.")))
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard outcome == nil else { return }
        outcome = result
        pending?.resume(with: result)
        pending = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first
            else { return connection.cancel() }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { return self.reply(connection, status: 405, body: "Method not allowed") }
            let target = String(parts[1])
            let path = target.components(separatedBy: "?")[0]
            guard path == "/auth/callback" else { return self.reply(connection, status: 404, body: "Not found") }

            let query = target.contains("?") ? String(target[target.index(after: target.firstIndex(of: "?")!)...]) : ""
            let params = Self.parse(query)
            let succeeded = params["code"] != nil && params["error"] == nil
            self.reply(connection, status: 200, body: Self.page(succeeded: succeeded))
            self.finish(.success(params))
        }
    }

    private func reply(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parse(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let name = pieces.first { result[name] = pieces.count > 1 ? pieces[1] : "" }
        }
        return result
    }

    private static func page(succeeded: Bool) -> String {
        let title = succeeded ? "Saturday is connected to ChatGPT" : "Sign-in didn't finish"
        let detail = succeeded ? "You can close this tab and go back to Saturday." : "Go back to Saturday and try again."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Saturday</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:100vh;margin:0;background:#f6f5f2;color:#1d1d1f}
        @media (prefers-color-scheme: dark){body{background:#1c1c1e;color:#f5f5f7}} main{text-align:center;padding:24px}
        h1{font-size:22px;margin:0 0 8px} p{opacity:.7;margin:0}</style></head>
        <body><main><h1>\(title)</h1><p>\(detail)</p></main></body></html>
        """
    }
}
