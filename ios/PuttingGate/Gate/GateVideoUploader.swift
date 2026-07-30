import Foundation

/// Uploads one gate putt's review clip to the backend under the user's Firebase
/// login, in three steps mirroring `UploadService`: request a signed URL, PUT the
/// file straight to storage, then associate the object with the putt.
final class GateVideoUploader {
    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
    }

    struct UploadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func upload(_ fileURL: URL, sessionID: String, puttIndex: Int) async throws {
        let base = AppSettings.backendBaseURL
        let token = await auth.validAccessToken()

        func authed(_ url: URL, method: String, json: [String: Any]? = nil) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = method
            if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: json)
            }
            return req
        }

        // 1. Signed URL to PUT this putt's clip.
        guard let urlEndpoint = URL(
            string: "\(base)/device/putts/\(sessionID)/\(puttIndex)/video/upload-url"
        ) else { throw UploadError(message: "Bad URL") }
        let (urlData, urlResp) = try await URLSession.shared.data(
            for: authed(urlEndpoint, method: "POST", json: ["filename": "putt-\(puttIndex).mp4"])
        )
        try Self.check(urlResp, urlData, "Couldn't start clip upload")
        guard let info = try? JSONSerialization.jsonObject(with: urlData) as? [String: Any],
              let objectName = info["object_name"] as? String,
              let uploadURLString = info["upload_url"] as? String,
              let uploadURL = URL(string: uploadURLString)
        else { throw UploadError(message: "Unexpected upload-url response") }

        // 2. PUT the clip straight to storage.
        var put = URLRequest(url: uploadURL)
        put.httpMethod = "PUT"
        let (_, putResp) = try await URLSession.shared.upload(for: put, fromFile: fileURL)
        try Self.check(putResp, nil, "Clip upload failed")

        // 3. Associate the uploaded object with the putt.
        guard let associate = URL(
            string: "\(base)/device/putts/\(sessionID)/\(puttIndex)/video"
        ) else { throw UploadError(message: "Bad URL") }
        let (aData, aResp) = try await URLSession.shared.data(
            for: authed(associate, method: "POST", json: ["object_name": objectName])
        )
        try Self.check(aResp, aData, "Couldn't attach clip")

        // Best-effort cleanup of the local clip.
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func check(_ response: URLResponse, _ body: Data?, _ fallback: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UploadError(message: fallback)
        }
    }
}
