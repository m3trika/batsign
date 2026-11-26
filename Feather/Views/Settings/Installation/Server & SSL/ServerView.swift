//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//

import SwiftUI
import NimbleViews

struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@AppStorage("Feather.batchGroupSize") private var _batchGroupSize: Int = 5
	@State private var _isUpdatingCertificates = false
	@State private var _localCATrust: LocalCA.TrustStatus?

	private let _serverMethods: [String] = [
		.localized("Fully Local"),
		.localized("Semi Local")
	]

	private let _serverPackUrl = "https://backloop.dev/pack.json"

	var body: some View {
		Group {
			Section {
				Picker(.localized("Installation Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.self) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			}

			Section {
				Stepper(value: $_batchGroupSize, in: 1...100) {
					HStack {
						Image(systemName: "square.stack.3d.up")
						Text(.localized("Apps per prompt"))
						Spacer()
						Text("\(_batchGroupSize)")
							.foregroundStyle(.secondary)
					}
				}
				.disabled(_serverMethod != 0)
			} footer: {
				Text("Fully Local installs can share one confirmation across several apps. This sets how many apps go into each prompt. 1 gives a separate prompt per app.")
			}

			if LocalCA.isBundled {
				_localCASection
			} else {
				Section {
					Button(.localized("Update SSL Certificates"), systemImage: "arrow.down.doc") {
						guard !_isUpdatingCertificates else { return }
						_isUpdatingCertificates = true

						FR.downloadSSLCertificates(from: _serverPackUrl) { result in
							DispatchQueue.main.async {
								_isUpdatingCertificates = false

								switch result {
								case .success:
									UIAlertController.showAlertWithOk(
										title: .localized("SSL Certificates"),
										message: .localized("Certificates updated successfully.")
									)
								case .failure(let error):
									UIAlertController.showAlertWithOk(
										title: .localized("SSL Certificates"),
										message: "Certificate update failed.\n\n\(error.localizedDescription)"
									)
								}
							}
						}
					}
					.disabled(_isUpdatingCertificates)
				}
			}
		}
		.task {
			guard LocalCA.isBundled else { return }
			let status = await Task.detached(priority: .userInitiated) {
				LocalCA.evaluateSystemTrust()
			}.value
			_localCATrust = status
		}
		.onChange(of: _serverMethod) { _ in
			UIAlertController.showAlertWithRestart(
				title: .localized("Restart Required"),
				message: .localized("These changes require a restart of the app")
			)
		}
	}

	// MARK: Private local CA

	@ViewBuilder
	private var _localCASection: some View {
		Section {
			HStack {
				Image(systemName: "network.badge.shield.half.filled")
				Text(.localized("Host"))
				Spacer()
				Text(LocalCA.hostname ?? "-")
					.foregroundStyle(.secondary)
			}
			HStack {
				Image(systemName: _trustSymbol)
				Text(.localized("Trusted by iOS"))
				Spacer()
				Text(_trustLabel)
					.foregroundStyle(.secondary)
			}
			Button(.localized("Export Trust Profile"), systemImage: "square.and.arrow.up") {
				do {
					let url = try LocalCA.exportableProfileURL()
					UIActivityViewController.show(activityItems: [url])
				} catch {
					UIAlertController.showAlertWithOk(
						title: .localized("Trust Profile"),
						message: error.localizedDescription
					)
				}
			}
			Button(.localized("Test Trust"), systemImage: "checkmark.shield") {
				Task {
					let status = await Task.detached(priority: .userInitiated) {
						LocalCA.evaluateSystemTrust()
					}.value
					_localCATrust = status
					let message: String
					switch status {
					case .trusted:
						message = "PASS: iOS trusts the local installer certificate. Fully Local installs can start."
					case .notTrusted(let reason):
						message = "FAIL: \(LocalCA.NotTrustedError(reason: reason).localizedDescription)"
					case .unavailable(let reason):
						message = "Could not test: \(reason)"
					}
					UIAlertController.showAlertWithOk(
						title: .localized("Local Installer Trust"),
						message: message
					)
				}
			}
		} header: {
			Text(.localized("Local HTTPS Certificate"))
		} footer: {
			Text("Fully Local installs use a private certificate made when this build was compiled. Do this once: Export Trust Profile, save it to Files, open it, install it in Settings › General › VPN & Device Management, then turn on \"BatSign Local Installer CA\" in Settings › General › About › Certificate Trust Settings. It only works for \(LocalCA.hostname ?? "the local installer").")
		}
	}

	private var _trustSymbol: String {
		switch _localCATrust {
		case .some(.trusted): return "checkmark.seal.fill"
		case .some(.notTrusted): return "xmark.seal"
		default: return "questionmark.circle"
		}
	}

	private var _trustLabel: String {
		switch _localCATrust {
		case .some(.trusted): return "Yes"
		case .some(.notTrusted): return "No"
		case .some(.unavailable): return "Unknown"
		case .none: return "Checking…"
		}
	}
}
