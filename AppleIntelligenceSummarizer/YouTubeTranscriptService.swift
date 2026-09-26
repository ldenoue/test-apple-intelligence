import Foundation

actor YouTubeTranscriptService {
    struct Transcript: Sendable {
        let text: String
        let languageCode: String
    }

    enum TranscriptError: LocalizedError {
        case invalidURL
        case videoUnavailable(String)
        case captionsUnavailable
        case invalidCaptionResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Enter a valid YouTube video URL."
            case .videoUnavailable(let reason):
                reason
            case .captionsUnavailable:
                "This video doesn't have a caption track."
            case .invalidCaptionResponse:
                "YouTube returned an unreadable caption track."
            }
        }
    }

    private struct ClientProfile: Sendable {
        let name: String
        let version: String
        let headerName: String
        let userAgent: String
        let extras: [String: String]
    }

    private let profiles: [ClientProfile] = [
        ClientProfile(
            name: "ANDROID",
            version: "20.10.38",
            headerName: "3",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 12) gzip",
            extras: ["androidSdkVersion": "30"]
        ),
        ClientProfile(
            name: "IOS",
            version: "20.10.4",
            headerName: "5",
            userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extras: ["deviceMake": "Apple", "deviceModel": "iPhone16,2"]
        ),
        ClientProfile(
            name: "ANDROID_VR",
            version: "1.62.20",
            headerName: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.20 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extras: ["androidSdkVersion": "32"]
        ),
        ClientProfile(
            name: "WEB",
            version: "2.20260819.01.00",
            headerName: "1",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
            extras: [:]
        ),
        ClientProfile(
            name: "MWEB",
            version: "2.20260819.01.00",
            headerName: "2",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            extras: [:]
        )
    ]

    static func videoID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }

        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = components.path.split(separator: "/").first.map(String.init)
        } else if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else {
                let parts = components.path.split(separator: "/").map(String.init)
                candidate = parts.count >= 2 && ["shorts", "embed", "live"].contains(parts[0])
                    ? parts[1]
                    : nil
            }
        } else {
            candidate = nil
        }

        guard let candidate,
              candidate.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    func transcript(from urlString: String) async throws -> Transcript {
        guard let videoID = Self.videoID(from: urlString) else {
            throw TranscriptError.invalidURL
        }

        var lastReason: String?
        for profile in profiles {
            do {
                let player = try await playerResponse(videoID: videoID, profile: profile)
                if let reason = playabilityReason(in: player) {
                    lastReason = reason
                }
                if let selection = defaultCaption(in: player) {
                    let text = try await downloadCaptions(from: selection.url, userAgent: profile.userAgent)
                    return Transcript(text: text, languageCode: selection.languageCode)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        if let lastReason {
            throw TranscriptError.videoUnavailable(lastReason)
        }
        throw TranscriptError.captionsUnavailable
    }

    private func playerResponse(
        videoID: String,
        profile: ClientProfile
    ) async throws -> [String: Any] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else {
            throw TranscriptError.invalidURL
        }

        var client: [String: Any] = [
            "hl": "en",
            "clientName": profile.name,
            "clientVersion": profile.version
        ]
        for (key, value) in profile.extras {
            client[key] = Int(value) ?? value
        }

        let payload: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": client,
                "user": ["lockedSafetyMode": false],
                "request": [
                    "useSsl": true,
                    "internalExperimentFlags": [],
                    "consistencyTokenJars": []
                ]
            ],
            "playbackContext": [
                "contentPlaybackContext": [
                    "vis": 0,
                    "splay": false,
                    "autoCaptionsDefaultOn": false,
                    "autonavState": "STATE_NONE",
                    "html5Preference": "HTML5_PREF_WANTS",
                    "lactMilliseconds": "-1"
                ]
            ],
            "racyCheckOk": true,
            "contentCheckOk": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.headerName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TranscriptError.videoUnavailable("YouTube couldn't load this video.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptError.videoUnavailable("YouTube returned invalid video data.")
        }
        return json
    }

    private func defaultCaption(in player: [String: Any]) -> (url: URL, languageCode: String)? {
        guard let captions = player["captions"] as? [String: Any],
              let renderer = captions["playerCaptionsTracklistRenderer"] as? [String: Any],
              let tracks = renderer["captionTracks"] as? [[String: Any]],
              !tracks.isEmpty else { return nil }

        let indices = renderer["defaultTranslationSourceTrackIndices"] as? [Int]
        let preferredIndex = indices?.first ?? 0
        var track = tracks.indices.contains(preferredIndex) ? tracks[preferredIndex] : tracks[0]
        guard let originalLanguage = track["languageCode"] as? String else { return nil }

        if let automaticTrack = tracks.first(where: {
            ($0["languageCode"] as? String) == originalLanguage && ($0["kind"] as? String) == "asr"
        }) {
            track = automaticTrack
        }

        guard let urlString = track["baseUrl"] as? String,
              let url = URL(string: urlString) else { return nil }
        return (url, originalLanguage)
    }

    private func playabilityReason(in player: [String: Any]) -> String? {
        guard let status = player["playabilityStatus"] as? [String: Any] else { return nil }
        if let reason = status["reason"] as? String { return reason }
        return (status["messages"] as? [String])?.first
    }

    private func downloadCaptions(from url: URL, userAgent: String) async throws -> String {
        guard url.scheme == "https",
              ["youtube.com", "www.youtube.com"].contains(url.host?.lowercased() ?? ""),
              url.path == "/api/timedtext" else {
            throw TranscriptError.invalidCaptionResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TranscriptError.invalidCaptionResponse
        }

        let parserDelegate = CaptionParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw TranscriptError.invalidCaptionResponse
        }
        let text = parserDelegate.cues.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptError.invalidCaptionResponse }
        return text
    }
}

private final class CaptionParserDelegate: NSObject, XMLParserDelegate {
    private var activeElement: String?
    private var buffer = ""
    var cues: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "text" || elementName == "p" {
            activeElement = elementName
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeElement != nil {
            buffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == activeElement else { return }
        let text = buffer
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            cues.append(text)
        }
        activeElement = nil
        buffer = ""
    }
}
