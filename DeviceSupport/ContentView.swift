//
//  ContentView.swift
//  DeviceSupport
//
//  Created by Saagar Jha on 6/16/26.
//

import Observation
import SwiftUI

struct ContentView: View {
	@State private var installed: [InstalledSupport] = []
	@State private var downloads: [Download] = []
	@State private var deviceNames: [String: String] = [:]
	@State private var selection: Set<URL> = []
	@State private var addingDownload = false
	@State private var pendingDeletion: [InstalledSupport] = []
	@State private var sizes: [URL: Int64] = [:]

	var body: some View {
		NavigationStack {
			List(selection: $selection) {
				if !downloads.isEmpty {
					Section("Downloading") {
						ForEach(downloads) { download in
							DownloadRow(download: download, deviceNames: deviceNames) { cancel(download) }
						}
						.onDelete { $0.forEach { downloads[$0].cancel() }; downloads.remove(atOffsets: $0) }
						.selectionDisabled()
					}
				}
				Section("Installed") {
					if installed.isEmpty {
						Text("No device supports yet. Tap + to download one.")
							.foregroundStyle(.secondary)
							.selectionDisabled()
					}
					ForEach(installed) { InstalledRow(support: $0, deviceNames: deviceNames, size: sizes[$0.url]) }
						.onDelete(perform: deleteInstalled)
				}
			}
			.navigationTitle("Device Support")
			.onDeleteCommand(perform: deleteSelected)
			.toolbar {
				Button { addingDownload = true } label: { Label("Add", systemImage: "plus") }
			}
			.sheet(isPresented: $addingDownload) {
				AddSheet(deviceNames: deviceNames, onStart: start)
			}
			.alert(pendingDeletion.count == 1 ? "Delete this device support?"
											  : "Delete \(pendingDeletion.count) device supports?",
				   isPresented: Binding(get: { !pendingDeletion.isEmpty },
										set: { if !$0 { pendingDeletion = [] } })) {
				Button("Delete", role: .destructive) { performDelete(pendingDeletion) }
				Button("Cancel", role: .cancel) {}
			} message: {
				if pendingDeletion.count == 1, let support = pendingDeletion.first {
					Text("“\(deviceNames[support.device] ?? support.device)” \(support.version) (\(support.build)) will be removed from disk.")
				} else {
					Text("They will be removed from disk and need to be re-downloaded.")
				}
			}
			.task { deviceNames = (try? await AppleDB.deviceNames()) ?? [:] }
			.task { refresh() }
		}
	}

	private func refresh() {
		installed = DeviceSupport.installed()
		// Summing folder sizes walks thousands of files, so do it off the main
		// actor and fill the sizes in when ready.
		let urls = installed.map(\.url)
		Task {
			sizes = await Task.detached {
				Dictionary(uniqueKeysWithValues: urls.map { ($0, DeviceSupport.size(of: $0)) })
			}.value
		}
	}

	/// Swipe-to-delete on a single installed row — asks for confirmation first.
	private func deleteInstalled(_ offsets: IndexSet) {
		pendingDeletion = offsets.map { installed[$0] }
	}

	/// Delete the current selection (Delete key) — asks for confirmation first.
	private func deleteSelected() {
		pendingDeletion = installed.filter { selection.contains($0.id) }
	}

	/// Remove the confirmed device-support folders from disk, then rescan.
	private func performDelete(_ supports: [InstalledSupport]) {
		for support in supports { try? FileManager.default.removeItem(at: support.url) }
		selection.subtract(supports.map(\.id))
		refresh()
	}

	/// Stop an in-flight download and drop its row. Cancelling tears down the
	/// pipeline, which cleans up the scratch directory and any mounted image.
	private func cancel(_ download: Download) {
		download.cancel()
		downloads.removeAll { $0.id == download.id }
	}

	private func start(_ target: FirmwareTarget) {
		let download = Download(target: target)
		downloads.append(download)
		Task {
			await download.run()
			// Successful downloads move into the installed list; failures stay
			// visible (with their error) until the user swipes them away.
			if download.failure == nil {
				downloads.removeAll { $0.id == download.id }
				refresh()
			}
		}
	}
}

/// One in-flight (or failed) download, observed by its row so progress updates
/// re-render only that row, not the whole list.
@MainActor @Observable final class Download: Identifiable {
	// A non-filesystem URL id so download rows share the installed rows' id type:
	// a selectable List asserts if its rows carry mixed id types.
	let id = URL(string: "download:\(UUID().uuidString)")!
	let target: FirmwareTarget
	var stage = "Starting…"
	// The completed fraction (0...1) when the current stage reports one, or nil
	// for indeterminate stages so the row can fall back to a spinner.
	var fraction: Double?
	var failure: String?
	private var task: Task<Void, Never>?

	init(target: FirmwareTarget) { self.target = target }

	func run() async {
		let task = Task {
			do {
				for try await progress in DeviceSupport.populate(target) {
					switch progress {
					case .resolving: stage = "Resolving…"; fraction = nil
					case .downloading(let f): stage = "Downloading \(Int(f * 100))%"; fraction = f
					case .decrypting: stage = "Decrypting…"; fraction = nil
					case .mounting: stage = "Mounting…"; fraction = nil
					case .extracting(let cache, let f): stage = "Extracting \(cache) cache \(Int(f * 100))%"; fraction = f
					case .finished: stage = "Done"; fraction = 1
					}
				}
			} catch is CancellationError {
			} catch {
				failure = "\(error)"
			}
		}
		self.task = task
		await task.value
	}

	func cancel() { task?.cancel() }
}

/// An SF Symbol for a device, chosen by its model-identifier family.
private func deviceSymbol(for device: String) -> String {
	if device.hasPrefix("iPhone") { return "iphone" }
	if device.hasPrefix("iPad") { return "ipad" }
	if device.hasPrefix("iPod") { return "ipodtouch" }
	if device.hasPrefix("Watch") { return "applewatch" }
	if device.hasPrefix("AppleTV") { return "appletv" }
	if device.hasPrefix("RealityDevice") { return "vision.pro" }
	return "questionmark.square.dashed"
}

private struct InstalledRow: View {
	let support: InstalledSupport
	let deviceNames: [String: String]
	let size: Int64?

	var body: some View {
		HStack(spacing: 12) {
			Image(systemName: deviceSymbol(for: support.device))
				.imageScale(.large).frame(width: 28).foregroundStyle(.tint)
			VStack(alignment: .leading, spacing: 2) {
				Text(deviceNames[support.device] ?? support.device)
				Text("\(support.platform) \(support.version) (\(support.build))")
					.font(.caption).foregroundStyle(.secondary)
			}
			Spacer()
			if let size {
				Text(size.formatted(.byteCount(style: .file)))
					.font(.caption).foregroundStyle(.secondary).monospacedDigit()
			}
		}
	}
}

private struct DownloadRow: View {
	let download: Download
	let deviceNames: [String: String]
	var onCancel: () -> Void
	@State private var hovering = false

	var body: some View {
		HStack(spacing: 12) {
			Group {
				if download.failure != nil {
					Image(systemName: "exclamationmark.triangle.fill")
						.imageScale(.large).foregroundStyle(.red)
				} else {
					Image(systemName: deviceSymbol(for: download.target.device))
						.imageScale(.large).foregroundStyle(.tint)
				}
			}
			.frame(width: 28)
			VStack(alignment: .leading, spacing: 2) {
				Text(deviceNames[download.target.device] ?? download.target.device)
				if let failure = download.failure {
					Text(failure).font(.caption).foregroundStyle(.red).textSelection(.enabled)
				} else {
					Text(download.stage).font(.caption).foregroundStyle(.secondary)
				}
			}
			Spacer()
			// Hovering the indicator reveals a cancel button that stops the
			// download and cleans up; otherwise show a real circular bar when
			// the stage reports a fraction, else an indeterminate spinner.
			if download.failure == nil {
				Group {
					if hovering {
						Button(action: onCancel) {
							Image(systemName: "xmark.circle.fill").imageScale(.large)
						}
						.buttonStyle(.plain).foregroundStyle(.secondary)
						.help("Cancel download")
					} else if let fraction = download.fraction {
						ProgressView(value: fraction)
							.progressViewStyle(.circular).controlSize(.small)
					} else {
						ProgressView().controlSize(.small)
					}
				}
				.frame(width: 20, height: 20)
				.onHover { hovering = $0 }
			}
		}
	}
}

/// The download panel: pick platform → version → device, then start.
private struct AddSheet: View {
	let deviceNames: [String: String]
	var onStart: (FirmwareTarget) -> Void
	@Environment(\.dismiss) private var dismiss

	@State private var os: OperatingSystem = .iOS
	@State private var builds: [Release] = []
	@State private var loadingBuilds = false
	@State private var catalogError: String?
	@State private var selectedBuild = ""
	@State private var device = ""

	// Clamp each selection to a value that exists in its list, so a stale or empty
	// @State never mismatches the picker's tags (SwiftUI faults on that).
	private var effectiveBuild: String {
		builds.contains { $0.build == selectedBuild } ? selectedBuild : (builds.first?.build ?? "")
	}
	private var selectedRelease: Release? { builds.first { $0.build == effectiveBuild } }
	private var devices: [String] { selectedRelease?.deviceMap.sorted() ?? [] }
	private var effectiveDevice: String {
		devices.contains(device) ? device : (devices.first ?? "")
	}

	var body: some View {
		NavigationStack {
			Form {
				Picker("Platform", selection: $os) {
					ForEach(OperatingSystem.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				if loadingBuilds {
					HStack { ProgressView().controlSize(.small); Text("Loading builds…") }
				} else if let catalogError {
					Text(catalogError).font(.caption).foregroundStyle(.red)
				} else {
					if !builds.isEmpty {
						Picker("Version", selection: Binding(get: { effectiveBuild }, set: { selectedBuild = $0 })) {
							ForEach(builds, id: \.build) { Text("\($0.version) (\($0.build))").tag($0.build) }
						}
					}
					if !devices.isEmpty {
						Picker("Device", selection: Binding(get: { effectiveDevice }, set: { device = $0 })) {
							ForEach(devices, id: \.self) { Text(deviceNames[$0] ?? $0).tag($0) }
						}
					}
				}
			}
			.formStyle(.grouped)
			.navigationTitle("Download")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Download") {
						onStart(FirmwareTarget(os: os, build: effectiveBuild, device: effectiveDevice))
						dismiss()
					}
					.disabled(effectiveDevice.isEmpty)
				}
			}
			.task(id: os) { await loadBuilds() }
		}
		.frame(minWidth: 420, minHeight: 240)
	}

	private func loadBuilds() async {
		loadingBuilds = true
		catalogError = nil
		builds = []
		defer { loadingBuilds = false }
		do {
			builds = try await AppleDB.catalog(os: os)
			selectedBuild = builds.first?.build ?? ""
		} catch {
			catalogError = "\(error)"
		}
	}
}

#Preview {
	ContentView()
}
