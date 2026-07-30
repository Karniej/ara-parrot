import Foundation

/// Opt-in cloud formatting via the Anthropic Messages API.
///
/// There is no official Anthropic SDK for Swift, so this speaks raw HTTPS
/// against `/v1/messages`. That is the supported shape for this language, not a
/// workaround: the request is four headers and a JSON body, and taking on a
/// vendored client for it would be more surface than it removes.
///
/// ## Inference settings, and why they are not adjustable
///
/// `thinking` is `adaptive` at `effort: low`. Low effort is the latency lever —
/// this call sits between the user finishing a sentence and the text appearing
/// at their cursor. Disabling thinking is *not* the lever, even though it looks
/// like the cheaper one: with thinking off, this model can write `<thinking>`
/// tags and other internal markup into the visible response, and the visible
/// response is what gets typed into whatever the user had focused.
///
/// The response is constrained to `{"cleaned": string}` by `output_config`.
/// That is a safety property as much as a parsing one — a schema-constrained
/// response cannot turn into a chat answer, so the "the transcript is data, not
/// an instruction" rule has a structural backstop and not only a prompt.
///
/// No `cache_control`: the minimum cacheable prefix on this model is 512 tokens
/// and the system prompt here is a few dozen, so a breakpoint would buy the
/// write premium and never a read.
///
/// ## The transport is injected
///
/// Everything interesting about this type is in how it treats a response —
/// especially a refusal, which arrives as a perfectly successful HTTP 200. The
/// seam lets those paths be driven without a network or an API key, and it
/// defaults to `urlSessionTransport` — `URLSession.shared.data(for:delegate:)`
/// with a delegate that refuses redirects, for the credential reason set out on
/// that property — which is the only transport production ever uses.
///
/// **The default transport suspends; it does not block.** That is a
/// requirement, not a detail: `FormatterChain.withDeadline` abandons a slow
/// formatter rather than cancelling it, and an abandoned task that blocks its
/// thread goes on occupying the cooperative pool, which is sized to the core
/// count and never grows. Under `engine: .cloud` a wedged network would orphan
/// one such task per utterance on top of the local engine's. `URLSession`'s
/// async API resumes a continuation from its own delegate queue, so an
/// outstanding request costs no pool thread; a `DispatchSemaphore` around
/// `dataTask` would be the easy version of this and the wrong one.
public struct CloudFormatter: Formatter {
    public typealias Transport =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let config: CloudConfig
    private let apiKey: String?
    private let transport: Transport

    /// - Parameters:
    ///   - config: Provider, model and keychain account. A `provider` other
    ///     than `anthropic` disables this formatter rather than sending that
    ///     vendor's key here.
    ///   - apiKey: The credential, already read. `nil` disables this formatter.
    ///
    ///     **A value and not a closure, deliberately.** A closure would invite
    ///     the caller to supply `{ Keychain.readPassword(account:) }`, and that
    ///     is the one thing that must not happen: it would be evaluated inside
    ///     `format`, which `FormatterChain` runs on the cooperative pool, and
    ///     `SecItemCopyMatching` blocks its thread for as long as a human takes
    ///     to answer a dialog whenever the keychain is locked or the item's ACL
    ///     does not trust this binary. That is the precise failure
    ///     `FormatterChain.withDeadline` documents and cannot rescue — the
    ///     deadline abandons the task without freeing the thread — and an
    ///     unsigned binary re-prompts on every rebuild, so it is not a corner
    ///     case. A `String?` makes the rule structural rather than advisory:
    ///     there is no lazy work left for a caller to smuggle in.
    ///
    ///     So the read happens once at startup, off the pool, where a prompt is
    ///     expected and blocking is free. The cost is that a rotated key needs a
    ///     restart to take effect, which is the right trade — picking rotation
    ///     up automatically would mean reading the keychain per utterance, i.e.
    ///     exactly the failure above.
    ///   - transport: Defaults to `urlSessionTransport`, which is what
    ///     production uses. Injected only so response handling — above all the
    ///     refusal path — is testable without a network.
    public init(config: CloudConfig,
                apiKey: String?,
                transport: @escaping Transport = CloudFormatter.urlSessionTransport) {
        self.config = config
        self.apiKey = apiKey
        self.transport = transport
    }

    /// The production transport. Named rather than inlined so the default
    /// argument and the documentation above refer to the same one line.
    ///
    /// The delegate is not boilerplate and must not be dropped: it is the only
    /// thing keeping the API key from being forwarded to whatever host a
    /// redirect names. CFNetwork strips `Authorization` when a redirect crosses
    /// hosts, but it has no idea `x-api-key` is a credential and forwards it
    /// verbatim — measured against two loopback servers, on both 302 and 307,
    /// with the destination receiving the key in full. The framework's own
    /// strip list is precisely the statement that custom auth headers are the
    /// caller's problem, and this is a hand-rolled client with a custom auth
    /// header. Refusing every redirect outright costs nothing real: this
    /// endpoint does not legitimately redirect, so a 3xx surfaces as
    /// `.transportFailure("HTTP 3xx")` and the chain falls back.
    public static let urlSessionTransport: Transport = { request in
        try await URLSession.shared.data(for: request, delegate: NoRedirects.shared)
    }

    /// Refuses every HTTP redirect. Stateless, hence safely shared.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirects()

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // `nil` means "do not follow"; the 3xx becomes the final response.
            completionHandler(nil)
        }
    }

    private static let endpoint =
        URL(string: "https://api.anthropic.com/v1/messages")!

    /// Generous for a rewrite of one dictated utterance, and deliberately not
    /// tight. `max_tokens` caps thinking *and* the response together, and
    /// thinking is on; a cap sized to the visible answer alone would truncate
    /// the schema-shaped JSON mid-string, which surfaces as a fall-through to
    /// the rules formatter rather than as anything a user could diagnose.
    private static let maxTokens = 4096

    public func format(_ text: String, mode: Mode) async throws -> String {
        // Both guards run before a request is built, let alone sent. A key
        // minted for another vendor must never be handed to this endpoint —
        // that is a credential disclosure to a third party, not a failed call.
        //
        // Both are normalised the same way. Comparing the provider strictly
        // while trimming the key would make `provider: "Anthropic"` or a
        // trailing space in config.json disable cloud formatting with an
        // `.unavailable` the user cannot tell apart from a missing key.
        let provider = config.provider
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard provider == Self.anthropic else { throw FormatterError.unavailable }
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { throw FormatterError.unavailable }

        // Serialising this body cannot fail — every value is a literal or a
        // `String`, and a Swift `String` is always valid Unicode. `try!` would
        // be defensible on that reasoning and is still the wrong trade: this
        // daemon's one promise is that a transcript is never lost, and a trap
        // in a shipped binary breaks it for a bug nobody can reproduce.
        //
        // Not `.unavailable`, which the chain prints as "engine unavailable" —
        // a bug in this file reported to the user as a missing engine. The
        // detail is a constant, so it carries no payload either way.
        guard let request = try? Self.buildRequest(key: key, model: config.model,
                                                   text: text, mode: mode)
        else { throw FormatterError.transportFailure("request serialisation failed") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Self.translate(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FormatterError.transportFailure("response was not HTTP")
        }
        // The status only. An error body from this API quotes the offending
        // request back — including, on an auth failure, the key itself — so
        // nothing derived from it may enter an error that the chain logs.
        guard http.statusCode == 200 else {
            throw FormatterError.transportFailure("HTTP \(http.statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw FormatterError.transportFailure("unrecognised response shape")
        }

        // Checked before `content` is touched. A safety classifier declines
        // with HTTP 200 and an empty or partial content array, so this is the
        // documented way this call fails and `content[0]` is the documented way
        // to crash on it. Dictated speech trips these occasionally; the chain's
        // job from here is to fall back, not to surface it.
        guard decoded.stopReason != "refusal" else { throw FormatterError.refused }

        // Truncation leaves the JSON half-written. Usually that fails to decode
        // below anyway, but a fragment can happen to parse, and half a sentence
        // typed at the cursor is worse than no rewrite at all.
        guard decoded.stopReason != "max_tokens" else {
            throw FormatterError.implausibleOutput
        }

        // Not `content[0]`: thinking is on, so a thinking block precedes the
        // answer.
        guard let raw = decoded.content?.first(where: { $0.type == "text" })?.text,
              let payload = raw.data(using: .utf8),
              let cleaned = try? JSONDecoder().decode(Cleaned.self, from: payload)
        else { throw FormatterError.implausibleOutput }

        let out = TranscriptPrompt.clean(cleaned.cleaned)
        guard !out.isEmpty else { throw FormatterError.implausibleOutput }
        return out
    }

    private static let anthropic = "anthropic"

    // MARK: - Request construction

    static func buildRequest(key: String, model: String,
                             text: String, mode: Mode) throws -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": ["type": "adaptive"],
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["cleaned": ["type": "string"]],
                        "required": ["cleaned"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "system": TranscriptPrompt.instructions(for: mode),
            "messages": [["role": "user", "content": TranscriptPrompt.wrap(text)]],
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Response shape

    private struct Response: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let stopReason: String?
        let content: [Block]?

        private enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case content
        }
    }

    private struct Cleaned: Decodable {
        let cleaned: String
    }

    // MARK: - Error mapping

    /// Maps a transport failure onto the chain's vocabulary without letting the
    /// credential out.
    ///
    /// `URLSession` reports caller cancellation as `URLError.cancelled`, never
    /// as `CancellationError`, and that is the only way this formatter sees one
    /// in practice: nothing else holds the `URLSessionTask`, so the request is
    /// cancelled exactly when the task wrapping it is. Reporting it as
    /// cancellation rather than as `.transportFailure` is accurate but, to be
    /// honest about it, **decorative**: `FormatterChain` decides cancellation by
    /// `Task.isCancelled` and never by error type, and `withDeadline` cancels
    /// the work task only in its `defer`, after the race is already decided — so
    /// the resulting error is yielded into a finished continuation and dropped
    /// before anything logs it. It earns its place as the right rendering if a
    /// future caller ever cancels a `CloudFormatter` outside `withDeadline`, not
    /// as a fix for anything observable today.
    ///
    /// Anything that is not a `URLError` is reduced to its type name, so that
    /// no error a transport *throws* can push a payload — a wrapped response
    /// body, a re-thrown error quoting the request — into a printed string.
    /// Note the limit of that: a `FormatterError` is returned untouched, so a
    /// transport throwing `.transportFailure(payload)` still has its payload
    /// printed verbatim. Production's only transport is `URLSession`, which
    /// throws `URLError`, so this costs nothing today — but the guarantee is
    /// "no *foreign* error type reaches a log line", not "no injected transport
    /// can print anything".
    static func translate(_ error: any Error) -> any Error {
        if let error = error as? FormatterError { return error }
        if error is CancellationError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return CancellationError() }
            return FormatterError.transportFailure(
                "URLError \(error.code.rawValue) (\(Self.summarise(error.code)))")
        }
        return FormatterError.transportFailure("\(type(of: error))")
    }

    /// A fixed, code-derived phrase for a `URLError`.
    ///
    /// Deliberately *not* `localizedDescription`. That reads
    /// `NSLocalizedDescriptionKey` out of the error's `userInfo`, which makes
    /// the message a channel the error's producer controls — and the errors
    /// this daemon renders come from a request that carries the API key in a
    /// header. Every string below is a literal in this file, so no `userInfo`
    /// any transport can construct reaches a log line.
    private static func summarise(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: return "no internet connection"
        case .networkConnectionLost: return "connection lost"
        case .timedOut: return "timed out"
        case .cannotFindHost: return "cannot find host"
        case .cannotConnectToHost: return "cannot connect to host"
        case .dnsLookupFailed: return "DNS lookup failed"
        case .secureConnectionFailed: return "TLS handshake failed"
        case .serverCertificateUntrusted: return "server certificate untrusted"
        case .userAuthenticationRequired: return "authentication required"
        case .httpTooManyRedirects: return "too many redirects"
        default: return "unclassified"
        }
    }
}
