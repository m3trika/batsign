//
//  LocalCA.swift
//  Feather
//
//  The private certificate authority that "Fully Local" installs use.
//
//  The local installer hands iOS an itms-services link pointing at an HTTPS
//  server inside BatSign, under a backloop.dev name that resolves to 127.0.0.1.
//  It used to download the public backloop.dev certificate for that, but that
//  certificate no longer exists, and iOS rejected it anyway (its key was public
//  and it was valid for ten years, past Apple's 825-day limit). Installs then sat
//  on "Ready" or "Installing" for ever.
//
//  Builds now ship a leaf issued by a private CA made at build time
//  (scripts/make-local-pki.sh). The CA is name-constrained to that one host, so
//  trusting it on the phone cannot vouch for any other site. The user installs
//  the CA profile once; after that installd trusts the local server.
//

import Foundation
import Security

enum LocalCA {
	/// The three files the TLS server reads. When a private CA is bundled, these
	/// always come from the app bundle, never from older downloaded copies in
	/// Documents (see `ServerInstaller.getUrl`).
	static let identityFileNames: Set<String> = ["server.crt", "server.pem", "commonName.txt"]

	static var certificateURL: URL? {
		Bundle.main.url(forResource: "BatSignLocalCA", withExtension: "crt")
	}

	static var profileURL: URL? {
		Bundle.main.url(forResource: "BatSignLocalCA", withExtension: "mobileconfig")
	}

	/// Whether this build carries a private CA and the leaf it issued.
	static var isBundled: Bool {
		certificateURL != nil
			&& profileURL != nil
			&& identityFileNames.allSatisfy { file in
				let parts = file.split(separator: ".", maxSplits: 1).map(String.init)
				return Bundle.main.url(forResource: parts[0], withExtension: parts[1]) != nil
			}
	}

	/// The host name the bundled leaf is issued for.
	static var hostname: String? {
		guard
			let url = Bundle.main.url(forResource: "commonName", withExtension: "txt"),
			let value = try? String(contentsOf: url, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!value.isEmpty
		else {
			return nil
		}
		return value
	}

	enum TrustStatus: Sendable {
		case trusted
		case notTrusted(String)
		case unavailable(String)

		var isTrusted: Bool {
			if case .trusted = self { return true }
			return false
		}
	}

	struct NotTrustedError: LocalizedError {
		let reason: String

		var errorDescription: String? {
			"iOS does not trust BatSign's local installer certificate yet, so the install would never start. "
				+ "Go to Settings › Installation › Server & SSL › Export Trust Profile, install the profile from Files "
				+ "(Settings › General › VPN & Device Management), then turn on \"BatSign Local Installer CA\" in "
				+ "Settings › General › About › Certificate Trust Settings. (\(reason))"
		}
	}

	/// Evaluates the bundled leaf for its host name against the device's own
	/// trust store, with no anchors supplied by the app. This passes only once
	/// the user has installed the CA profile and enabled full trust for it,
	/// which is the same trust installd applies when it fetches the manifest.
	/// Local only: no network access.
	static func evaluateSystemTrust() -> TrustStatus {
		guard isBundled, let hostname else {
			return .unavailable("this build has no bundled local CA")
		}
		guard
			let leafURL = Bundle.main.url(forResource: "server", withExtension: "crt"),
			let pem = try? String(contentsOf: leafURL, encoding: .utf8)
		else {
			return .unavailable("the bundled certificate could not be read")
		}

		let certificates = certificateDERs(from: pem).compactMap {
			SecCertificateCreateWithData(nil, $0 as CFData)
		}
		guard !certificates.isEmpty else {
			return .unavailable("the bundled certificate could not be parsed")
		}

		var trust: SecTrust?
		let status = SecTrustCreateWithCertificates(
			certificates as CFArray,
			SecPolicyCreateSSL(true, hostname as CFString),
			&trust
		)
		guard status == errSecSuccess, let trust else {
			return .unavailable("SecTrustCreateWithCertificates failed (\(status))")
		}
		_ = SecTrustSetNetworkFetchAllowed(trust, false)

		var error: CFError?
		if SecTrustEvaluateWithError(trust, &error) {
			return .trusted
		}
		let message = error.map { CFErrorCopyDescription($0) as String } ?? "unknown trust failure"
		return .notTrusted(message)
	}

	/// A copy of the CA profile in a temporary folder, ready to share or save to
	/// Files. Copied because some share targets cannot read the app bundle.
	static func exportableProfileURL() throws -> URL {
		guard let profileURL else {
			throw CocoaError(.fileNoSuchFile)
		}
		let fileManager = FileManager.default
		let directory = fileManager.temporaryDirectory
			.appendingPathComponent("BatSignLocalCA", isDirectory: true)
		try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
		let destination = directory.appendingPathComponent("BatSignLocalCA.mobileconfig")
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.removeItem(at: destination)
		}
		try fileManager.copyItem(at: profileURL, to: destination)
		return destination
	}

	private static func certificateDERs(from pem: String) -> [Data] {
		let begin = "-----BEGIN CERTIFICATE-----"
		let end = "-----END CERTIFICATE-----"
		var result: [Data] = []
		var remainder = pem[...]
		while let beginRange = remainder.range(of: begin) {
			remainder = remainder[beginRange.upperBound...]
			guard let endRange = remainder.range(of: end) else { break }
			let base64 = String(remainder[..<endRange.lowerBound].filter { !$0.isWhitespace })
			if let data = Data(base64Encoded: base64) {
				result.append(data)
			}
			remainder = remainder[endRange.upperBound...]
		}
		return result
	}
}
