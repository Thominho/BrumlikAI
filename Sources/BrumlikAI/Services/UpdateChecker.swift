import Foundation
import AppKit
import CryptoKit

enum UpdateError: LocalizedError {
    case http(Int)
    case invalidSignature
    case invalidBundle
    case cannotReplaceApp

    var errorDescription: String? {
        switch self {
        case .http(let status): return L10n.f(.errUpdateHTTP, status)
        case .invalidSignature: return L10n.t(.errUpdateSignature)
        case .invalidBundle: return L10n.t(.errUpdateBundle)
        case .cannotReplaceApp: return L10n.t(.errUpdateLocation)
        }
    }
}

/// Finds newer versions on GitHub Releases and installs them. Every release archive carries an Ed25519
/// signature (`BrumlikAI.zip.sig`) made with the maintainer's private key; the matching public key is in
/// Info.plist, so neither a tampered download nor a hijacked GitHub account can push code to users.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let archiveName = "BrumlikAI.zip"
    static let signatureName = "BrumlikAI.zip.sig"

    struct Release: Equatable {
        let version: String
        let notes: String
        let archiveURL: URL
        let signatureURL: URL
        let pageURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing
        case failed(String)
        case notConfigured
    }

    @Published private(set) var state: State = .idle
    @Published var checksAutomatically = AppState.storedBool("updates.autoCheck", default: true) {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: "updates.autoCheck") }
    }
    @Published var installsAutomatically = AppState.storedBool("updates.autoInstall", default: false) {
        didSet { UserDefaults.standard.set(installsAutomatically, forKey: "updates.autoInstall") }
    }

    private var timer: Timer?
    private var isIdle: @MainActor () -> Bool = { true }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    private var repository: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BrumlikUpdateRepository") as? String, !value.isEmpty else { return nil }
        return value
    }

    private var publicKey: Curve25519.Signing.PublicKey? {
        guard let base64 = Bundle.main.object(forInfoDictionaryKey: "BrumlikUpdatePublicKey") as? String,
              let data = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Checks shortly after launch and then every six hours. Installs on its own only when the user allowed it
    /// and nothing is being recorded or processed.
    func startAutomaticChecks(isIdle: @escaping @MainActor () -> Bool) {
        self.isIdle = isIdle
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.automaticCheck() }
        }
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            await automaticCheck()
        }
    }

    func check() async {
        guard let repository, publicKey != nil else {
            state = .notConfigured
            return
        }
        state = .checking
        do {
            if let release = try await latestRelease(in: repository),
               Self.isVersion(release.version, newerThan: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func install(_ release: Release) async {
        guard let publicKey else {
            state = .notConfigured
            return
        }
        state = .downloading
        do {
            let newApp = try await download(release, verifiedWith: publicKey)
            state = .installing
            try replaceAndRelaunch(with: newApp)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pure helpers

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    nonisolated static func isValidSignature(_ signatureFile: Data, for archive: Data, publicKey: Curve25519.Signing.PublicKey) -> Bool {
        let text = String(decoding: signatureFile, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text) else { return false }
        return publicKey.isValidSignature(signature, for: archive)
    }

    // MARK: - Steps

    private func automaticCheck() async {
        guard checksAutomatically else { return }
        await check()
        if installsAutomatically, let release = availableRelease, isIdle() {
            await install(release)
        }
    }

    private func latestRelease(in repository: String) async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BrumlikAI/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw UpdateError.http(status) }

        struct GitHubRelease: Decodable {
            let tagName: String
            let body: String?
            let htmlUrl: String?
            let assets: [Asset]

            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: String
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)

        func assetURL(_ name: String) -> URL? {
            release.assets.first { $0.name == name }.flatMap { URL(string: $0.browserDownloadUrl) }
        }
        guard let archive = assetURL(Self.archiveName), let signature = assetURL(Self.signatureName) else { return nil }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Release(
            version: version,
            notes: release.body ?? "",
            archiveURL: archive,
            signatureURL: signature,
            pageURL: release.htmlUrl.flatMap(URL.init(string:))
        )
    }

    /// Downloads the archive, checks its signature, unpacks it and makes sure it really is a newer BrumlikAI.
    private func download(_ release: Release, verifiedWith publicKey: Curve25519.Signing.PublicKey) async throws -> URL {
        let (archiveData, archiveResponse) = try await URLSession.shared.data(from: release.archiveURL)
        let (signatureData, signatureResponse) = try await URLSession.shared.data(from: release.signatureURL)
        for response in [archiveResponse, signatureResponse] {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw UpdateError.http(status) }
        }
        guard Self.isValidSignature(signatureData, for: archiveData, publicKey: publicKey) else {
            throw UpdateError.invalidSignature
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrumlikAI-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let archiveFile = workDirectory.appendingPathComponent(Self.archiveName)
        try archiveData.write(to: archiveFile)
        try Self.run("/usr/bin/ditto", ["-x", "-k", archiveFile.path, workDirectory.path])

        let newApp = workDirectory.appendingPathComponent("BrumlikAI.app")
        guard let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Self.isVersion(newVersion, newerThan: currentVersion) else {
            throw UpdateError.invalidBundle
        }
        return newApp
    }

    /// Hands over to a small shell script that waits for this process to quit, swaps the bundles
    /// (putting the old one back if the move fails) and starts the new version.
    private func replaceAndRelaunch(with newApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app",
              !currentApp.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) else {
            throw UpdateError.cannotReplaceApp
        }

        let script = """
        while kill -0 "$3" 2>/dev/null; do sleep 0.2; done
        backup="$(mktemp -d)/BrumlikAI.app"
        mv "$2" "$backup" || exit 1
        if mv "$1" "$2"; then open "$2"; else mv "$backup" "$2"; open "$2"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "brumlik-update", newApp.path, currentApp.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidBundle }
    }
}
