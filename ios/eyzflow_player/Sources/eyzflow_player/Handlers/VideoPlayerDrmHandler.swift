import AVFoundation
import Foundation
import ObjectiveC

/// Handles DRM (Digital Rights Management) for protected content playback
/// Supports FairPlay Streaming and AES-128 (Standard HLS Encryption)
///
/// FairPlay follows Apple's AVContentKeySession flow:
/// 1. The asset is added as a content key recipient *before* its
///    AVPlayerItem is created, so every `skd://` key the item meets is
///    routed to this session (on the phone, also while playing over AirPlay).
/// 2. The application certificate is fetched once (prefetched at setup,
///    awaited by the first key request) and cached for the session.
/// 3. For each key request the SPC is built with
///    `makeStreamingContentKeyRequestData(forApp:contentIdentifier:options:)`
///    from the certificate and the content id (the `skd://` URI without its
///    scheme), POSTed raw (`application/octet-stream`) to the licence URL with
///    the configured headers, and the raw CKC answer is handed back to
///    AVFoundation.
///
/// The handler is retained by the AVPlayerItem it serves (see
/// `retain(by:)`), so a shared player that outlives its platform view keeps
/// its key session for renewals, later keys and AirPlay.
class VideoPlayerDrmHandler: NSObject {
    private var contentKeySession: AVContentKeySession?
    private var drmConfig: [String: Any]
    private var certificateUrl: URL?
    private var licenseUrl: URL?
    private var licenseHeaders: [String: String]?

    /// Serial queue for the key session delegate and all certificate state.
    private let delegateQueue = DispatchQueue(label: "com.eyzflow.player.drm")

    // Certificate cache (accessed on delegateQueue only)
    private var certificateData: Data?
    private var certificateFetchInFlight = false
    private var certificateWaiters: [(Result<Data, Error>) -> Void] = []

    private let lock = NSLock()
    private var _lastErrorMessage: String?
    private var _onError: ((String) -> Void)?

    /// The message of the last FairPlay failure (licence server body included
    /// for non-2xx answers), for load errors whose AVFoundation error is generic.
    var lastErrorMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastErrorMessage
    }

    /// Called (on the main queue) when a FairPlay key could not be obtained.
    var onError: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onError }
        set { lock.lock(); _onError = newValue; lock.unlock() }
    }

    private static var itemAssociationKey: UInt8 = 0

    init(drmConfig: [String: Any]) {
        self.drmConfig = drmConfig

        // Extract configuration values
        if let licenseUrlString = drmConfig["licenseUrl"] as? String {
            self.licenseUrl = URL(string: licenseUrlString)
        }

        if let certificateUrlString = drmConfig["certificateUrl"] as? String {
            self.certificateUrl = URL(string: certificateUrlString)
        }

        if let headers = drmConfig["headers"] as? [String: String] {
            self.licenseHeaders = headers
        }

        super.init()
    }

    /// Sets up DRM for the given asset. Must be called before the asset's
    /// AVPlayerItem is created. For FairPlay the key session is created and
    /// the asset added as a recipient synchronously; the completion is called
    /// synchronously too (the certificate is prefetched in the background and
    /// awaited by the first key request).
    /// - Parameters:
    ///   - asset: The AVURLAsset to configure DRM for
    ///   - completion: Completion handler called when setup is complete
    func setupDRM(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let drmType = drmConfig["type"] as? String else {
            completion(false, NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "DRM type not specified"]))
            return
        }

        let drmTypeLower = drmType.lowercased()

        // For AES-128 (standard HLS encryption), headers passed to AVURLAsset should be sufficient
        // AVPlayer will automatically handle key requests for standard HLS encryption
        if drmTypeLower == "aes-128" {
            npLog("🔐 DRM: AES-128 detected - using standard HLS encryption")
            completion(true, nil)
            return
        }

        // For FairPlay, we need to set up AVContentKeySession
        if drmTypeLower == "fairplay" {
            setupFairPlay(asset: asset, completion: completion)
        } else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported DRM type: \(drmType)"])
            completion(false, error)
        }
    }

    /// Keeps this handler (and its key session) alive for as long as `item`.
    func retain(by item: AVPlayerItem) {
        objc_setAssociatedObject(item, &VideoPlayerDrmHandler.itemAssociationKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Sets up FairPlay DRM
    private func setupFairPlay(asset: AVURLAsset, completion: @escaping (Bool, Error?) -> Void) {
        guard let licenseUrl = licenseUrl else {
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "License URL is required for FairPlay"])
            completion(false, error)
            return
        }
        guard certificateUrl != nil else {
            // makeStreamingContentKeyRequestData needs the application certificate
            let error = NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Certificate URL is required for FairPlay"])
            completion(false, error)
            return
        }

        npLog("🔐 DRM: Setting up FairPlay - License URL: \(licenseUrl.absoluteString)")

        // Create content key session; keys go to the asset we add below
        let session = AVContentKeySession(keySystem: .fairPlayStreaming)
        session.setDelegate(self, queue: delegateQueue)
        contentKeySession = session

        // Add the asset as a recipient BEFORE its AVPlayerItem is created, so
        // the item's key requests are delivered to this session.
        session.addContentKeyRecipient(asset)

        // Prefetch the certificate; key requests wait for it if needed
        delegateQueue.async { [weak self] in
            self?.withCertificate { result in
                if case .failure(let error) = result {
                    npLog("🔐 DRM: Certificate prefetch failed: \(error.localizedDescription)")
                }
            }
        }

        completion(true, nil)
    }

    // MARK: - Certificate

    /// Calls `completion` (on delegateQueue) with the cached certificate,
    /// fetching it first if needed. Must be called on delegateQueue.
    private func withCertificate(_ completion: @escaping (Result<Data, Error>) -> Void) {
        if let data = certificateData {
            completion(.success(data))
            return
        }
        certificateWaiters.append(completion)
        guard !certificateFetchInFlight else { return }
        guard let url = certificateUrl else {
            finishCertificate(.failure(VideoPlayerDrmHandler.error("FairPlay certificate URL not configured")))
            return
        }
        certificateFetchInFlight = true
        fetchCertificate(url: url) { [weak self] result in
            guard let self = self else { return }
            self.delegateQueue.async {
                self.certificateFetchInFlight = false
                if case .success(let data) = result {
                    self.certificateData = data
                }
                // On failure nothing is cached, so the next key request retries
                self.finishCertificate(result)
            }
        }
    }

    private func finishCertificate(_ result: Result<Data, Error>) {
        let waiters = certificateWaiters
        certificateWaiters.removeAll()
        waiters.forEach { $0(result) }
    }

    /// Fetches the FairPlay application certificate
    private func fetchCertificate(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        npLog("🔐 DRM: Fetching certificate from: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Add custom headers if provided
        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                npLog("🔐 DRM: Certificate fetch error: \(error.localizedDescription)")
                completion(.failure(VideoPlayerDrmHandler.error("FairPlay certificate request failed: \(error.localizedDescription)")))
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(statusCode) else {
                completion(.failure(VideoPlayerDrmHandler.error("FairPlay certificate request failed (HTTP \(statusCode))")))
                return
            }

            guard let data = data, let certificate = FairPlayLicenseFormat.certificate(from: data) else {
                completion(.failure(VideoPlayerDrmHandler.error("FairPlay certificate request returned no data")))
                return
            }

            npLog("🔐 DRM: Certificate fetched successfully (\(certificate.count) bytes)")
            completion(.success(certificate))
        }

        task.resume()
    }

    /// Cleans up DRM resources owned by the view. The key session itself lives
    /// as long as the player item it serves (see `retain(by:)`): a shared
    /// player can keep playing after its view is gone and still needs keys
    /// (renewals, other renditions, AirPlay). It is released with the item.
    func cleanup() {
        onError = nil
        npLog("🔐 DRM: Cleaned up DRM handler")
    }

    // MARK: - Key requests

    private func handleKeyRequest(_ keyRequest: AVContentKeyRequest, renewal: Bool) {
        npLog("🔐 DRM: \(renewal ? "Renewing content key" : "Content key") request received (\(String(describing: keyRequest.identifier)))")

        guard let licenseUrl = licenseUrl else {
            fail(keyRequest, "FairPlay licence URL not configured")
            return
        }

        guard let contentId = FairPlayLicenseFormat.contentIdentifier(
            identifier: keyRequest.identifier,
            initializationData: keyRequest.initializationData
        ) else {
            fail(keyRequest, "FairPlay key request has no skd:// content identifier")
            return
        }

        withCertificate { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.fail(keyRequest, error.localizedDescription)
            case .success(let certificate):
                keyRequest.makeStreamingContentKeyRequestData(
                    forApp: certificate,
                    contentIdentifier: contentId,
                    options: [AVContentKeyRequestProtocolVersionsKey: [1]]
                ) { [weak self] spc, error in
                    guard let self = self else { return }
                    guard let spc = spc else {
                        self.fail(keyRequest, "FairPlay SPC could not be created: \(error?.localizedDescription ?? "unknown error")")
                        return
                    }
                    self.requestLicense(spc: spc, licenseUrl: licenseUrl, keyRequest: keyRequest)
                }
            }
        }
    }

    /// POSTs the SPC to the licence server and hands the CKC to AVFoundation.
    private func requestLicense(spc: Data, licenseUrl: URL, keyRequest: AVContentKeyRequest) {
        var request = URLRequest(url: licenseUrl)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = spc

        // Add custom headers if provided (access-token)
        if let headers = licenseHeaders {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        npLog("🔐 DRM: Sending SPC (\(spc.count) bytes) to: \(licenseUrl.absoluteString)")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                self.fail(keyRequest, "FairPlay licence request failed: \(error.localizedDescription)")
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(statusCode) else {
                // Keep the server's body: the Dart side reads codes such as
                // STREAM_LIMIT, DEVICE_LIMIT or PLAYER_KEY_INVALID from it.
                let body = FairPlayLicenseFormat.bodyText(data)
                self.fail(keyRequest, "FairPlay licence request failed (HTTP \(statusCode))\(body.isEmpty ? "" : ": \(body)")")
                return
            }

            guard let data = data, let ckc = FairPlayLicenseFormat.ckc(from: data) else {
                self.fail(keyRequest, "FairPlay licence response was empty")
                return
            }

            let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc)
            keyRequest.processContentKeyResponse(keyResponse)
            npLog("🔐 DRM: CKC (\(ckc.count) bytes) processed")
        }

        task.resume()
    }

    private func fail(_ keyRequest: AVContentKeyRequest, _ message: String) {
        npLog("🔐 DRM: \(message)")
        lock.lock()
        _lastErrorMessage = message
        let callback = _onError
        lock.unlock()
        keyRequest.processContentKeyResponseError(VideoPlayerDrmHandler.error(message))
        if let callback = callback {
            DispatchQueue.main.async { callback(message) }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "VideoPlayerDrmHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - AVContentKeySessionDelegate

extension VideoPlayerDrmHandler: AVContentKeySessionDelegate {
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handleKeyRequest(keyRequest, renewal: false)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        // Only arrives if a persistable key was asked for (offline); serve it as streaming.
        npLog("🔐 DRM: Persistable content key request received")
        handleKeyRequest(keyRequest, renewal: false)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handleKeyRequest(keyRequest, renewal: true)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        npLog("🔐 DRM: Content key request failed: \(err.localizedDescription)")
    }

    func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest, reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        npLog("🔐 DRM: Content key request should retry - reason: \(retryReason.rawValue)")
        switch retryReason {
        case .timedOut, .receivedResponseWithExpiredLease, .receivedObsoleteContentKey:
            return true
        default:
            return false
        }
    }
}

// MARK: - Wire format

/// The EYZFlow FairPlay licence contract (`POST /v1/drm/:stream_id/fairplay/acquire`,
/// forwarded unchanged to the Axinom FairPlay licence service): the body is the
/// raw SPC, the answer the raw CKC. Lenient readers accept the base64 / `<ckc>`
/// / JSON wrappers other FairPlay servers use.
enum FairPlayLicenseFormat {
    /// The content identifier for the SPC: the `skd://` URI without its scheme
    /// (Apple's and Axinom's reference clients), as UTF-8.
    static func contentIdentifier(identifier: Any?, initializationData: Data?) -> Data? {
        var uri: String?
        if let string = identifier as? String {
            uri = string
        } else if let url = identifier as? URL {
            uri = url.absoluteString
        } else if let data = initializationData {
            uri = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        }
        guard var value = uri?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}"))),
              !value.isEmpty else { return nil }
        if let range = value.range(of: "skd://", options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
        guard !value.isEmpty else { return nil }
        return value.data(using: .utf8)
    }

    /// The CKC from a licence answer: raw bytes, or a base64 CKC wrapped in
    /// `<ckc>…</ckc>`, a JSON `{"ckc": …}` or sent bare.
    static func ckc(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return data // binary CKC
        }
        if text.hasPrefix("<ckc>"), text.hasSuffix("</ckc>") {
            let inner = String(text.dropFirst(5).dropLast(6))
            return Data(base64Encoded: inner, options: .ignoreUnknownCharacters)
        }
        if text.hasPrefix("{"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = (json["ckc"] ?? json["CkcMessage"] ?? json["license"]) as? String {
            return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
        }
        if text.count >= 16,
           text.range(of: "^[A-Za-z0-9+/=\\r\\n]+$", options: .regularExpression) != nil,
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) {
            return decoded
        }
        return data
    }

    /// The application certificate: DER as served, or base64 DER.
    static func certificate(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if data.first == 0x30 { return data } // DER SEQUENCE
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
           decoded.first == 0x30 {
            return decoded
        }
        return data
    }

    /// A licence server's error body as text, shortened for logs and Dart.
    static func bodyText(_ data: Data?) -> String {
        guard let data = data, !data.isEmpty else { return "" }
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
