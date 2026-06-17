//
//  SharedCache.swift
//  DeviceSupport
//
//  Created by Saagar Jha on 6/16/26.
//

import AppleArchive
import Compression
import CryptoKit
import Foundation
import System

/// Failures we detect ourselves: a bad HTTP status, an unparseable archive.
///
/// Errors that already carry their own detail — `URLError`, `DecodingError` —
/// are thrown directly and never wrapped; this enum is only for the conditions
/// nothing else reports.
nonisolated enum SharedCacheError: Error {
	case unexpectedStatus(Int)
	case rangeNotHonored(Int)
	case missingContentLength
	case malformedArchive(String)
	case commandFailed(String)

	/// Throw `error` when `condition` holds (after unxip's conditional-throw style).
	static func `throw`(_ error: @autoclosure () -> Self, if condition: Bool) throws {
		if condition { throw error() }
	}
}

/// An Apple operating system we can populate device support for. The raw value
/// is the name appledb uses (`iOS`, `watchOS`, …).
enum OperatingSystem: String, CaseIterable, Sendable {
	// iOS covers iPhone *and* iPad: there's no separate iPadOS platform. The two
	// are identical for our purposes (same DeviceSupport folder, same extractor,
	// same non-OTA preference); they differ only in which appledb osStr holds a
	// given device's per-build firmware, which `firmwareNames(for:)` resolves from
	// the device identifier. Splitting them would only surface unreachable entries
	// (the iPadOS namespace has no pre-13 history, but the iOS catalog does).
	case iOS
	case tvOS
	case watchOS
	case visionOS

	/// watchOS ships no IPSW, and tvOS's OTA is the clean route, so these prefer
	/// the OTA payload; the rest use the restore IPSW.
	var prefersOTA: Bool { self == .tvOS || self == .watchOS }

	/// The Xcode platform whose dsc_extractor matches this OS's cache. The
	/// extractor is platform-specific — the iPhoneOS one rejects, e.g., an
	/// arm64_32 watch cache.
	var extractorPlatform: String {
		switch self {
		case .iOS: return "iPhoneOS.platform"
		case .tvOS: return "AppleTVOS.platform"
		case .watchOS: return "WatchOS.platform"
		case .visionOS: return "XROS.platform"
		}
	}

	/// The subdirectory of `~/Library/Developer/Xcode` that holds this OS's
	/// device-support folders (iPads land in iOS's).
	var deviceSupportDirectory: String {
		switch self {
		case .iOS: return "iOS DeviceSupport"
		case .tvOS: return "tvOS DeviceSupport"
		case .watchOS: return "watchOS DeviceSupport"
		case .visionOS: return "visionOS DeviceSupport"
		}
	}

	/// The appledb osStr namespace(s) that may hold `device`'s per-build firmware,
	/// in the order to try. iPhones/iPods live under `iOS`; an iPad lives under
	/// `iPadOS` from iPadOS 13 on but under `iOS` for its pre-13 (iOS) era — so try
	/// `iPadOS` first and fall back to `iOS`. Other platforms use their own osStr.
	func firmwareNames(for device: String) -> [String] {
		guard self == .iOS, device.hasPrefix("iPad") else { return [rawValue] }
		return ["iPadOS", "iOS"]
	}
}

/// A concrete thing the user wants to populate: one OS build for one device family.
///
/// A device is part of the identity because the shared cache differs by device
/// family, so "iOS 26.5" alone isn't enough to pin down which cache to fetch.
struct FirmwareTarget: Hashable, Sendable {
	var os: OperatingSystem
	var build: String
	var device: String
}

/// A device-support folder already present under ~/Library/Developer/Xcode.
struct InstalledSupport: Identifiable, Hashable, Sendable {
	var platform: String   // the folder family, e.g. "iOS" (iOS and iPadOS share one)
	var device: String     // model identifier, e.g. "iPhone12,1"
	var version: String
	var build: String
	var url: URL
	var id: URL { url }
}

// MARK: - appledb currency types
//
// These mirror the JSON at https://api.appledb.dev/ios/<osStr>;<build>.json
// closely enough to use directly throughout, rather than translating into a
// separate model. Unmodeled keys (hashes, release notes, baseband, etc.) are
// simply ignored by the decoder.

/// One firmware entry from appledb (a single OS build, across all its devices).
struct Firmware: Decodable, Sendable {
	var osStr: String
	var version: String
	var build: String
	var beta: Bool
	var released: String?
	/// Every device this build covers.
	var deviceMap: [String]
	/// Download sources — one per device group, IPSW and OTA, full and delta.
	var sources: [Source]

	/// A single downloadable firmware asset.
	struct Source: Decodable, Sendable {
		/// "ipsw" or "ota".
		var type: String
		/// Devices this particular asset serves.
		var deviceMap: [String]
		var size: Int
		/// Base build(s) a delta OTA patches from. Empty for full sources.
		///
		/// appledb encodes this field inconsistently: it may be absent (full
		/// source), a single build string, or an array of build strings (a delta
		/// applicable from several bases). We normalize all three to an array.
		var prerequisiteBuilds: [String]
		var links: [Link]

		/// True for full (non-delta) sources, i.e. the ones that contain a cache.
		var isFull: Bool { prerequisiteBuilds.isEmpty }

		enum CodingKeys: String, CodingKey {
			case type, deviceMap, size, prerequisiteBuild, links
		}

		init(from decoder: any Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			type = try c.decode(String.self, forKey: .type)
			deviceMap = try c.decode([String].self, forKey: .deviceMap)
			size = try c.decode(Int.self, forKey: .size)
			links = try c.decode([Link].self, forKey: .links)
			// appledb: absent | "21H16" | ["21F79", "21F90"] — normalize to array.
			// If present in some other shape, let the array decode throw a real
			// DecodingError rather than silently treating it as "full".
			if !c.contains(.prerequisiteBuild) {
				prerequisiteBuilds = []
			} else if let single = try? c.decode(String.self, forKey: .prerequisiteBuild) {
				prerequisiteBuilds = [single]
			} else {
				prerequisiteBuilds = try c.decode([String].self, forKey: .prerequisiteBuild)
			}
		}
	}

	/// A mirror URL for a source.
	struct Link: Decodable, Sendable {
		var url: URL
		var active: Bool
		var preferred: Bool
	}
}

/// A real, downloadable build from appledb's per-OS catalog — enough to browse
/// and pick. (The catalog also contains placeholder rows with no build or device
/// list; those are filtered out when building this.)
struct Release: Sendable, Hashable {
	var version: String
	var build: String
	var deviceMap: [String]
	var beta: Bool
}

// MARK: - appledb access

enum AppleDB {
	/// Fetch the firmware entry for `build` that actually serves `device`, with its
	/// full sources. An iPad's firmware lives under `iPadOS` (13+) or `iOS` (pre-13),
	/// so try each candidate namespace and return the first whose sources include a
	/// full cache source for the device; a missing namespace (404) just tries the
	/// next. Throws the last error if none serve it.
	static func firmware(os: OperatingSystem, build: String, device: String) async throws -> Firmware {
		var lastError: Error?
		for name in os.firmwareNames(for: device) {
			do {
				let firmware = try await get(Firmware.self, from: "https://api.appledb.dev/ios/\(name);\(build).json")
				if firmware.cacheSource(for: device, on: os) != nil { return firmware }
			} catch {
				lastError = error   // 404 / decode failure for this namespace; try the next
			}
		}
		throw lastError ?? SharedCacheError.malformedArchive("no firmware for \(device) in \(build)")
	}

	/// Every known build for `os` (appledb's per-OS catalog), newest first. These
	/// carry version/build/deviceMap for browsing but not the full sources — fetch
	/// `firmware(os:build:device:)` for the chosen build to download.
	static func catalog(os: OperatingSystem) async throws -> [Release] {
		// The catalog is messy — some rows lack a build or device list — so decode
		// leniently, then keep only the real, downloadable builds.
		struct Entry: Decodable {
			var version: String?
			var build: String?
			var beta: Bool?
			var released: String?
			var deviceMap: [String]?
			// Per-device download assets — populated for every real firmware, unlike
			// the inline `sources` array, which appledb leaves empty for watchOS.
			var devices: [String: DeviceAssets]?
			struct DeviceAssets: Decodable { var ipsw: String?; var ota: String? }
		}
		// The iOS catalog (`iOS/main.json`) lists every iPhone *and* iPad build,
		// across the whole iOS/iPadOS history; the iPadOS catalog doesn't exist
		// (that URL 404s). Each platform browses its own list and keeps every device
		// it carries — the per-device firmware namespace is resolved later, by
		// device, in `firmware(os:build:device:)`.
		let entries = try await get([Entry].self, from: "https://api.appledb.dev/ios/\(os.rawValue)/main.json")
			.sorted { ($0.released ?? "") > ($1.released ?? "") }

		// appledb splits a build into several rows (one per device group) and mixes
		// in Simulator/SDK pseudo-builds. Drop the non-firmware rows and merge rows
		// that share a build, unioning their device lists. Order (newest first) is
		// preserved by first appearance.
		var byBuild: [String: Release] = [:]
		var order: [String] = []
		for entry in entries {
			let deviceMap = entry.deviceMap ?? []
			// A listed device must offer a full restore asset: an IPSW (always
			// full) or, for the OTA-only platforms, an OTA payload. We can't trust
			// the inline `sources` array here — appledb leaves it empty for watchOS.
			let downloadable = deviceMap.contains { device in
				guard let assets = entry.devices?[device] else { return false }
				return assets.ipsw != nil || (os.prefersOTA && assets.ota != nil)
			}
			guard let version = entry.version, let build = entry.build, !deviceMap.isEmpty,
				  downloadable,
				  !version.contains("Simulator"), !version.contains("SDK") else { continue }
			if var existing = byBuild[build] {
				existing.deviceMap = Array(Set(existing.deviceMap).union(deviceMap)).sorted()
				byBuild[build] = existing
			} else {
				byBuild[build] = Release(version: version, build: build,
										 deviceMap: deviceMap.sorted(), beta: entry.beta ?? false)
				order.append(build)
			}
		}
		return order.map { byBuild[$0]! }
	}

	/// Map of model identifier (e.g. "iPhone12,1") to marketing name (e.g.
	/// "iPhone 11"), for showing friendly names in place of the raw identifiers.
	static func deviceNames() async throws -> [String: String] {
		struct Device: Decodable { var key: String?; var name: String? }
		let devices = try await get([Device].self, from: "https://api.appledb.dev/device/main.json")
		return Dictionary(devices.compactMap { device in
			device.key.flatMap { key in device.name.map { (key, $0) } }
		}, uniquingKeysWith: { first, _ in first })
	}

	private static func get<T: Decodable>(_ type: T.Type, from urlString: String) async throws -> T {
		let (data, response) = try await URLSession.shared.data(from: URL(string: urlString)!)
		let http = response as! HTTPURLResponse
		try SharedCacheError.throw(.unexpectedStatus(http.statusCode), if: http.statusCode != 200)
		return try JSONDecoder().decode(T.self, from: data)   // DecodingError propagates as-is
	}
}

extension Firmware {
	/// Full (non-delta) sources of `type` that serve `device`.
	func fullSources(ofType type: String, for device: String) -> [Source] {
		sources.filter { $0.type == type && $0.isFull && $0.deviceMap.contains(device) }
	}

	/// The source to fetch the cache from for `device`: the OTA payload for the
	/// OSes that prefer it, the IPSW otherwise, each falling back to the other.
	func cacheSource(for device: String, on os: OperatingSystem) -> Source? {
		let ipsw = fullSources(ofType: "ipsw", for: device)
		let ota = fullSources(ofType: "ota", for: device)
		if os.prefersOTA, let source = ota.first { return source }
		return ipsw.first ?? ota.first
	}
}

// MARK: - HTTP range access
//
// The whole point of fetching the cache cheaply is to read only the parts of a
// multi-GB firmware archive we need, via HTTP range requests. This depends on
// the host honoring `Range` (Apple's CDN does — it returns 206 Partial Content).

enum HTTP {
	/// Total size of the resource, via a HEAD request.
	static func contentLength(of url: URL) async throws -> Int {
		var req = URLRequest(url: url)
		req.httpMethod = "HEAD"
		let (_, response) = try await URLSession.shared.data(for: req)
		let http = response as! HTTPURLResponse
		try SharedCacheError.throw(.unexpectedStatus(http.statusCode), if: http.statusCode != 200)
		guard let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int($0) }) else {
			throw SharedCacheError.missingContentLength
		}
		return length
	}

	/// Fetch the inclusive byte range [lo, hi]. Requires the server to answer 206;
	/// a 200 means it ignored Range and is sending the whole file.
	static func range(_ url: URL, _ lo: Int, _ hi: Int) async throws -> Data {
		var req = URLRequest(url: url)
		req.setValue("bytes=\(lo)-\(hi)", forHTTPHeaderField: "Range")
		let (data, response) = try await URLSession.shared.data(for: req)
		let http = response as! HTTPURLResponse
		try SharedCacheError.throw(.rangeNotHonored(http.statusCode), if: http.statusCode != 206)
		return data
	}

}

/// A forward cursor that reads little-endian fields from a byte buffer in order.
///
/// Records are described top-to-bottom in the order the format lays them out —
/// `read` for fields we keep, `skip` for the ones we don't — so there are no
/// hand-computed absolute offsets to misread.
private nonisolated struct ByteReader {
	let data: Data
	private(set) var offset: Int

	init(_ data: Data, at offset: Int = 0) {
		self.data = data
		self.offset = offset
	}

	mutating func u16() -> Int { read(UInt16.self) }
	mutating func u32() -> Int { read(UInt32.self) }
	mutating func u64() -> Int { read(UInt64.self) }

	/// Big-endian 64-bit read (pbzx stores its sizes big-endian).
	mutating func u64BigEndian() -> Int {
		defer { offset += 8 }
		return Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.bigEndian)
	}

	mutating func skip(_ count: Int) { offset += count }
	mutating func seek(to newOffset: Int) { offset = newOffset }

	mutating func bytes(_ count: Int) -> Data {
		defer { offset += count }
		return data.subdata(in: offset..<offset + count)
	}

	private mutating func read<Integer: FixedWidthInteger>(_ type: Integer.Type) -> Int {
		defer { offset += MemoryLayout<Integer>.size }
		return Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Integer.self) }.littleEndian)
	}
}

// MARK: - remote zip (ZIP64-aware central directory over range requests)
//
// Firmware archives (.ipsw, OTA .zip) are plain zips, often > 4 GB, so we must
// handle ZIP64. We read the end-of-central-directory from the tail, then the
// central directory itself, to learn where each member lives — all without
// downloading the (multi-GB) member payloads.

struct RemoteZip {
	struct Entry: Sendable {
		var name: String
		var method: Int          // 0 = stored, 8 = deflate
		var compressedSize: Int
		var localHeaderOffset: Int
	}

	var url: URL
	private(set) var entries: [String: Entry]

	/// Constants from the ZIP / ZIP64 specification.
	private enum Spec {
		static let centralFileHeaderSignature: UInt32 = 0x0201_4b50   // "PK\u{01}\u{02}"
		static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50   // "PK\u{05}\u{06}"
		static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4b50   // "PK\u{06}\u{06}"
		/// A 32-bit size/offset set to this means the real value lives in the ZIP64 extra field.
		static let zip64Sentinel = 0xffff_ffff
		/// Tag of the ZIP64 extended-information extra field.
		static let zip64ExtraTag = 1
		/// The local file header's fixed portion is exactly this many bytes.
		static let localHeaderFixedSize = 30
		/// The end-of-central-directory record sits after a comment that can be up to
		/// 65535 bytes, so scanning the last ~64 KB (plus slack for the ZIP64 records)
		/// is enough to find it.
		static let trailerScanSize = 66_000

		/// The on-disk (little-endian) bytes of a signature, for locating it by search.
		static func bytes(_ signature: UInt32) -> Data {
			withUnsafeBytes(of: signature.littleEndian) { Data($0) }
		}
	}

	/// Read the central directory of the remote zip.
	static func read(_ url: URL) async throws -> RemoteZip {
		let size = try await HTTP.contentLength(of: url)
		let tail = try await HTTP.range(url, max(0, size - Spec.trailerScanSize), size - 1)

		let (cdOffset, cdSize) = try locateCentralDirectory(in: tail, url: url)
		let cd = try await HTTP.range(url, cdOffset, cdOffset + cdSize - 1)

		var entries: [String: Entry] = [:]
		var recordStart = 0
		while recordStart + 46 <= cd.count {
			var r = ByteReader(cd, at: recordStart)
			guard r.u32() == Int(Spec.centralFileHeaderSignature) else { break }
			r.skip(2 + 2 + 2)               // version made by, version needed, general-purpose flags
			let method = r.u16()
			r.skip(2 + 2 + 4)               // last-mod time, last-mod date, CRC-32
			var compressedSize = r.u32()
			let uncompressedSize = r.u32()
			let nameLength = r.u16()
			let extraLength = r.u16()
			let commentLength = r.u16()
			r.skip(2 + 2 + 4)               // disk number start, internal attrs, external attrs
			var localHeaderOffset = r.u32()
			let name = String(decoding: r.bytes(nameLength), as: UTF8.self)
			let extra = r.bytes(extraLength)

			// Any field set to the sentinel has its real (64-bit) value in `extra`.
			if compressedSize == Spec.zip64Sentinel
				|| uncompressedSize == Spec.zip64Sentinel
				|| localHeaderOffset == Spec.zip64Sentinel {
				var e = ByteReader(extra)
				while e.offset + 4 <= extra.count {
					let tag = e.u16()
					let fieldSize = e.u16()
					let fieldEnd = e.offset + fieldSize
					if tag == Spec.zip64ExtraTag {
						// Present in this fixed order, but only for fields that were the sentinel.
						if uncompressedSize == Spec.zip64Sentinel { e.skip(8) }
						if compressedSize == Spec.zip64Sentinel { compressedSize = e.u64() }
						if localHeaderOffset == Spec.zip64Sentinel { localHeaderOffset = e.u64() }
					}
					e.seek(to: fieldEnd)
				}
			}

			entries[name] = Entry(name: name, method: method,
								  compressedSize: compressedSize, localHeaderOffset: localHeaderOffset)
			recordStart += 46 + nameLength + extraLength + commentLength
		}
		return RemoteZip(url: url, entries: entries)
	}

	/// Find the central directory's offset and size from the archive tail,
	/// preferring the ZIP64 record (firmware archives exceed 4 GB).
	private static func locateCentralDirectory(in tail: Data, url: URL) throws -> (offset: Int, size: Int) {
		if let found = tail.range(of: Spec.bytes(Spec.zip64EndOfCentralDirectorySignature), options: .backwards) {
			var r = ByteReader(tail, at: found.lowerBound)
			r.skip(4)                       // signature
			r.skip(8)                       // size of this record
			r.skip(2 + 2)                   // version made by, version needed
			r.skip(4 + 4)                   // this disk, disk where CD starts
			r.skip(8 + 8)                   // entries on this disk, total entries
			let size = r.u64()
			let offset = r.u64()
			return (offset, size)
		}
		if let found = tail.range(of: Spec.bytes(Spec.endOfCentralDirectorySignature), options: .backwards) {
			var r = ByteReader(tail, at: found.lowerBound)
			r.skip(4)                       // signature
			r.skip(2 + 2)                   // this disk, disk where CD starts
			r.skip(2 + 2)                   // entries on this disk, total entries
			let size = r.u32()
			let offset = r.u32()
			return (offset, size)
		}
		throw SharedCacheError.malformedArchive("no end-of-central-directory in \(url.lastPathComponent)")
	}

	/// Where this entry's raw (possibly compressed) payload begins/ends in the zip.
	func payloadRange(of entry: Entry) async throws -> (start: Int, end: Int) {
		let header = try await HTTP.range(url, entry.localHeaderOffset,
										  entry.localHeaderOffset + Spec.localHeaderFixedSize)
		var r = ByteReader(header)
		r.skip(4)                           // local file header signature
		r.skip(2 + 2 + 2)                   // version needed, general-purpose flags, method
		r.skip(2 + 2 + 4)                   // last-mod time, last-mod date, CRC-32
		r.skip(4 + 4)                       // compressed size, uncompressed size
		let nameLength = r.u16()
		let extraLength = r.u16()
		let start = entry.localHeaderOffset + Spec.localHeaderFixedSize + nameLength + extraLength
		return (start, start + entry.compressedSize - 1)
	}
}

// MARK: - Apple Encrypted Archive (AEA) key acquisition
//
// Since iOS 18 the cache-bearing images ship as profile-1 `.dmg.aea`: encrypted
// with a symmetric key that isn't in the file. The key is wrapped for Apple's
// Web Key Management Service (WKMS) and must be unwrapped via the parameters in
// the archive's auth-data prologue — fetch a per-file private key from the URL
// the archive names, then HPKE-`open` the wrapped key. No external `aea` tool.

enum AEA {
	/// The fixed prologue (magic + profile + auth-data size) preceding the records.
	private static let headerSize = 12
	private static let magic = Data("AEA1".utf8)

	/// Parse the auth-data records — repeated `[u32-LE size][key]\0[value]` — out
	/// of an AEA prologue. `prologue` must hold at least the full auth-data region.
	static func authFields(in prologue: Data) throws -> [String: Data] {
		var header = ByteReader(prologue)
		try SharedCacheError.throw(.malformedArchive("not an AEA1 archive"), if: header.bytes(4) != magic)
		header.skip(4)                          // profile (1 = symmetric / WKMS)
		let authDataEnd = headerSize + header.u32()   // size of the auth-data region

		var fields: [String: Data] = [:]
		var r = ByteReader(prologue, at: headerSize)
		while r.offset + 4 <= authDataEnd {
			let recordStart = r.offset
			let size = r.u32()
			guard size >= 4, recordStart + size <= prologue.count else { break }
			let body = prologue.subdata(in: (recordStart + 4)..<(recordStart + size))
			if let separator = body.firstIndex(of: 0) {
				fields[String(decoding: body[..<separator], as: UTF8.self)] = Data(body[(separator + 1)...])
			}
			r.seek(to: recordStart + size)
		}
		return fields
	}

	/// Derive the symmetric key for a profile-1 (WKMS) archive from its prologue:
	/// GET the per-file key the archive names, then HPKE-unwrap the wrapped key.
	static func symmetricKey(fromPrologue prologue: Data) async throws -> SymmetricKey {
		let fields = try authFields(in: prologue)
		guard let keyURL = fields["com.apple.wkms.fcs-key-url"]
				.flatMap({ String(data: $0, encoding: .utf8) }).flatMap(URL.init(string:)),
			  let responseData = fields["com.apple.wkms.fcs-response"] else {
			throw SharedCacheError.malformedArchive("AEA auth data is missing its WKMS key fields")
		}

		// fcs-response is JSON carrying the HPKE encapsulated key and wrapped key.
		struct FCSResponse: Decodable {
			var encRequest: String
			var wrappedKey: String
			enum CodingKeys: String, CodingKey {
				case encRequest = "enc-request"
				case wrappedKey = "wrapped-key"
			}
		}
		let fcs = try JSONDecoder().decode(FCSResponse.self, from: responseData)
		guard let encapsulatedKey = Data(base64Encoded: fcs.encRequest),
			  let wrappedKey = Data(base64Encoded: fcs.wrappedKey) else {
			throw SharedCacheError.malformedArchive("AEA fcs-response keys are not valid base64")
		}

		// The key URL is unauthenticated and returns a PEM-encoded P-256 private key.
		let (pem, response2) = try await URLSession.shared.data(from: keyURL)
		let http = response2 as! HTTPURLResponse
		try SharedCacheError.throw(.unexpectedStatus(http.statusCode), if: http.statusCode != 200)

		let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: String(decoding: pem, as: UTF8.self))
		var recipient = try HPKE.Recipient(privateKey: privateKey,

										   ciphersuite: .P256_SHA256_AES_GCM_256,
										   info: Data(),
										   encapsulatedKey: encapsulatedKey)
		return SymmetricKey(data: try recipient.open(wrappedKey))
	}

	/// Decrypt a profile-1 AEA file to `destination` using a WKMS-derived key.
	/// The decryption stream yields the decrypted (and decompressed) payload —
	/// for a `.dmg.aea` that's the raw disk image.
	static func decrypt(to destination: URL, key: SymmetricKey,
						readingFrom makeInput: @escaping @Sendable () -> ArchiveByteStream?) async throws {
		try await offMain {
			let permissions = FilePermissions(rawValue: 0o644)
			guard let input = makeInput() else {
				throw SharedCacheError.malformedArchive("could not open the encrypted image stream")
			}
			defer { try? input.close() }
			guard let context = ArchiveEncryptionContext(from: input) else {
				throw SharedCacheError.malformedArchive("could not read AEA encryption context")
			}
			try context.setSymmetricKey(key)
			guard let decryption = ArchiveByteStream.decryptionStream(readingFrom: input, encryptionContext: context) else {
				throw SharedCacheError.malformedArchive("could not open AEA decryption stream")
			}
			defer { try? decryption.close() }
			guard let output = ArchiveByteStream.fileStream(path: FilePath(destination.path),
					  mode: .writeOnly, options: [.create, .truncate], permissions: permissions) else {
				throw SharedCacheError.malformedArchive("could not create \(destination.lastPathComponent)")
			}
			defer { try? output.close() }
			_ = try ArchiveByteStream.process(readingFrom: decryption, writingTo: output)
		}
	}
}

// MARK: - locating and downloading the cache image

/// The slice of an IPSW's BuildManifest.plist we need: the path of each build
/// identity's components, so we can find which image holds the cache.
private struct BuildManifest: Decodable {
	var buildIdentities: [Identity]
	enum CodingKeys: String, CodingKey { case buildIdentities = "BuildIdentities" }

	struct Identity: Decodable {
		var manifest: [String: Component]
		enum CodingKeys: String, CodingKey { case manifest = "Manifest" }
	}

	struct Component: Decodable {
		var info: Info?
		enum CodingKeys: String, CodingKey { case info = "Info" }

		struct Info: Decodable {
			var path: String?
			enum CodingKeys: String, CodingKey { case path = "Path" }
		}
	}
}

extension RemoteZip {
	/// The entry holding the dyld_shared_cache, per the BuildManifest: the
	/// `Cryptex1,SystemOS` image on iOS 16+, else the `OS` root filesystem.
	func cacheImageEntry() async throws -> Entry {
		guard let manifestEntry = entries["BuildManifest.plist"] else {
			throw SharedCacheError.malformedArchive("IPSW has no BuildManifest.plist")
		}
		let (start, end) = try await payloadRange(of: manifestEntry)
		let raw = try await HTTP.range(url, start, end)
		let plistData = manifestEntry.method == 8 ? (try (raw as NSData).decompressed(using: .zlib) as Data) : raw
		let manifest = try PropertyListDecoder().decode(BuildManifest.self, from: plistData)
		for key in ["Cryptex1,SystemOS", "OS"] {
			for identity in manifest.buildIdentities {
				if let path = identity.manifest[key]?.info?.path, let entry = entries[path] {
					return entry
				}
			}
		}
		throw SharedCacheError.malformedArchive("no cache-bearing image found in BuildManifest")
	}

	/// Download `entry`'s payload to `destination`, saturating the link with many
	/// range requests in flight (each written at its file offset). Stored (method
	/// 0) entries — modern IPSWs' big DMGs — are written straight out; deflated
	/// (method 8) ones — old IPSWs — are fetched compressed and then inflated.
	/// `progress` reports (bytesWritten, totalBytes) of the download.
	func download(_ entry: Entry, to destination: URL,
				  chunkSize: Int = 16 << 20, concurrency: Int = 8,
				  progress: ((Int, Int) -> Void)? = nil) async throws {
		let (start, end) = try await payloadRange(of: entry)
		switch entry.method {
		case 0:
			try await fetchPayload(from: start, to: end, into: destination,
								   chunkSize: chunkSize, concurrency: concurrency, progress: progress)
		case 8:
			// zip stores raw DEFLATE; download the compressed bytes, then inflate.
			let compressed = destination.appendingPathExtension("deflate")
			defer { try? FileManager.default.removeItem(at: compressed) }
			try await fetchPayload(from: start, to: end, into: compressed,
								   chunkSize: chunkSize, concurrency: concurrency, progress: progress)
			let data = try Data(contentsOf: compressed, options: .mappedIfSafe)
			try ((data as NSData).decompressed(using: .zlib) as Data).write(to: destination)
		default:
			throw SharedCacheError.malformedArchive("\(entry.name) uses unsupported zip method \(entry.method)")
		}
	}

	/// Chunked, parallel range download of the byte range [start, end] into
	/// `destination`. Memory stays bounded by `chunkSize * concurrency`.
	private func fetchPayload(from start: Int, to end: Int, into destination: URL,
							  chunkSize: Int, concurrency: Int,
							  progress: ((Int, Int) -> Void)?) async throws {
		let total = end - start + 1

		var chunks: [(offset: Int, lo: Int, hi: Int)] = []
		var lo = start
		while lo <= end {
			let hi = min(lo + chunkSize - 1, end)
			chunks.append((lo - start, lo, hi))
			lo = hi + 1
		}

		FileManager.default.createFile(atPath: destination.path, contents: nil)
		let handle = try FileHandle(forWritingTo: destination)
		defer { try? handle.close() }

		let url = self.url
		var written = 0
		try await withThrowingTaskGroup(of: (offset: Int, data: Data).self) { group in
			var next = 0
			func enqueue() {
				let chunk = chunks[next]
				group.addTask { (chunk.offset, try await HTTP.range(url, chunk.lo, chunk.hi)) }
				next += 1
			}
			while next < min(concurrency, chunks.count) { enqueue() }
			for try await result in group {
				try handle.seek(toOffset: UInt64(result.offset))
				try handle.write(contentsOf: result.data)
				written += result.data.count
				progress?(written, total)
				if next < chunks.count { enqueue() }
			}
		}
	}

	/// Stream an OTA's `payloadv2/payload.NNN` chunks into an AppleArchive
	/// extraction at `directory`, fetching each chunk over the network.
	func extractOTAPayload(to directory: URL,
						   concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
						   progress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
		let names = entries.keys
			.filter { $0.range(of: #"payloadv2/payload\.\d+$"#, options: .regularExpression) != nil }
			.sorted()
		let chunkEntries = names.compactMap { entries[$0] }.filter { $0.compressedSize > 0 }
		let url = self.url
		try await OTAPayload.reconstruct(chunkCount: chunkEntries.count, to: directory,
										 concurrency: concurrency, progress: progress) { index in
			let entry = chunkEntries[index]
			let (start, end) = try await payloadRange(of: entry)
			let raw = try await HTTP.range(url, start, end)
			// A few chunks are zip-deflated (method 8); inflate before pbz-decoding.
			return entry.method == 8 ? (try (raw as NSData).decompressed(using: .zlib) as Data) : raw
		}
	}
}

// MARK: - pbz block-compression (OTA payloadv2 chunks)
//
// watchOS has no IPSW; its OTA delivers the cache inside `payloadv2/payload.NNN`
// chunks, each in Apple's pbz block-compression format: a 4-byte header
// `p`,`b`,`z`,<algo>, a 64-bit block size, then per block a 64-bit uncompressed
// size, a 64-bit compressed size, and the payload — stored raw when the two
// sizes are equal, else compressed with <algo>. All 64-bit values are big-endian.
// <algo> is m=lzraven, z=zlib, x=lzma, 4=lz4, e=lzfse. Decoding every chunk and
// concatenating yields one AppleArchive (.yaa).

nonisolated enum PBZX {
	/// Decode a pbz stream into its underlying (decompressed) bytes.
	static func decode(_ data: Data) throws -> Data {
		var reader = ByteReader(data)
		let header = Array(reader.bytes(4))
		try SharedCacheError.throw(.malformedArchive("not a pbz stream"),
								   if: Array(header.prefix(3)) != Array("pbz".utf8))
		let algorithm = try algorithm(for: header[3])
		reader.skip(8)                              // block size
		var output = Data()
		while reader.offset + 16 <= data.count {
			let uncompressedSize = reader.u64BigEndian()
			let compressedSize = reader.u64BigEndian()
			guard reader.offset + compressedSize <= data.count else { break }
			let block = reader.bytes(compressedSize)
			// A block is stored raw when its two sizes match, else <algo>-compressed.
			if uncompressedSize == compressedSize {
				output.append(block)
			} else {
				output.append(try inflate(block, using: algorithm, to: uncompressedSize))
			}
		}
		return output
	}

	private static func algorithm(for code: UInt8) throws -> compression_algorithm {
		switch code {
		case UInt8(ascii: "m"): return COMPRESSION_LZRAVEN
		case UInt8(ascii: "z"): return COMPRESSION_ZLIB
		case UInt8(ascii: "x"): return COMPRESSION_LZMA
		case UInt8(ascii: "4"): return COMPRESSION_LZ4_RAW
		case UInt8(ascii: "e"): return COMPRESSION_LZFSE
		default:
			throw SharedCacheError.malformedArchive("unknown pbz algorithm '\(Character(UnicodeScalar(code)))'")
		}
	}

	/// Decompress one block to its known output size via the low-level Compression
	/// buffer API — lzraven isn't exposed through `NSData.CompressionAlgorithm`.
	private static func inflate(_ block: Data, using algorithm: compression_algorithm, to size: Int) throws -> Data {
		var output = Data(count: size)
		let written = output.withUnsafeMutableBytes { destination in
			block.withUnsafeBytes { source in
				compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, size,
										  source.bindMemory(to: UInt8.self).baseAddress!, block.count,
										  nil, algorithm)
			}
		}
		try SharedCacheError.throw(.malformedArchive("pbz block decompression failed"), if: written != size)
		return output
	}
}

extension ArchiveByteStream {
	/// Write all of `data` to the stream, looping until every byte is accepted —
	/// a single `write(from:)` may consume only part of the buffer.
	nonisolated func writeAll(_ data: Data) throws {
		try data.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				offset += try write(from: UnsafeRawBufferPointer(rebasing: raw[offset...]))
			}
		}
	}

	/// Run jobs concurrently (up to `concurrency` in flight) and write each job's
	/// `Data` result to the stream in submission order, blocking on the stream's
	/// backpressure. `body` produces work by calling the `submit` it's handed —
	/// submission order is write order, and `submit` suspends for backpressure once
	/// the window is full. `onWrite` reports the running count of chunks written.
	/// Both OTA paths share this; they differ only in how each chunk is obtained
	/// (a `submit`-ted job fetches+decodes a network chunk, or just decodes one read
	/// sequentially out of the decrypted asset).
	nonisolated func writeOrdered(concurrency: Int,
								  onWrite: (@Sendable (Int) -> Void)? = nil,
								  _ body: (_ submit: (@escaping @Sendable () async throws -> Data) async throws -> Void) async throws -> Void) async throws {
		try await withThrowingTaskGroup(of: (index: Int, data: Data).self) { group in
			var pending: [Int: Data] = [:]
			var nextToWrite = 0
			var submitted = 0
			var inFlight = 0
			// Take one finished job, then flush everything now contiguous from
			// `nextToWrite` into the stream (blocking on its backpressure).
			func drainOne() async throws {
				guard let result = try await group.next() else { return }
				inFlight -= 1
				pending[result.index] = result.data
				while let data = pending.removeValue(forKey: nextToWrite) {
					try writeAll(data)
					nextToWrite += 1
					onWrite?(nextToWrite)
				}
			}
			func submit(_ job: @escaping @Sendable () async throws -> Data) async throws {
				let index = submitted
				submitted += 1
				group.addTask { (index, try await job()) }
				inFlight += 1
				if inFlight >= concurrency { try await drainOne() }
			}
			try await body(submit)
			while inFlight > 0 { try await drainOne() }
		}
	}
}

/// A `Sendable` per-entry selection filter — it crosses into the extraction task
/// (and AppleArchive's decode worker threads), so it must not capture mutable state.
typealias EntrySelector = @Sendable (ArchiveHeader.EntryMessage, FilePath, ArchiveHeader.EntryFilterData?) -> ArchiveHeader.EntryMessageStatus

extension SharedCache {
	/// Selects only what a cache build needs out of a firmware's filesystem — the
	/// shared-cache directories and `SystemVersion.plist`, plus the ancestor
	/// directories that must exist for them — and skips everything else, so the
	/// whole OS tree is never written to disk just to recover the cache.
	nonisolated static func cacheSelectionFilter() -> EntrySelector {
		let keep = [
			"System/Library/Caches/com.apple.dyld",
			"System/Library/dyld",
			"System/DriverKit/System/Library/dyld",
			"System/Library/CoreServices/SystemVersion.plist",
		]
		return { _, path, _ in
			// Entry paths are relative to the tree root; drop any "./" or "/" lead.
			var entry = path.string
			if entry.hasPrefix("./") { entry.removeFirst(2) }
			entry = String(entry.drop(while: { $0 == "/" }))
			for target in keep where entry == target
				|| entry.hasPrefix(target + "/")    // a file inside a kept directory
				|| target.hasPrefix(entry + "/") {  // an ancestor of a kept path
				return .ok
			}
			return .skip
		}
	}
}

/// Streams a reconstructed Apple Archive into an extraction at `directory`: opens
/// a backpressuring buffer pipe, runs the AppleArchive decode→extract consumer on
/// one end, and hands the write end to `produce`, which writes the (decompressed)
/// archive bytes and returns. `selecting` filters which entries are written to
/// disk (skipped ones are still decoded, since the stream can't be seeked, but
/// never land). The write end is closed automatically on return, signaling EOF;
/// memory stays bounded by the pipe's capacity. The two OTA paths — network zip
/// chunks and a decrypted segmented asset — differ only in how they produce those
/// bytes, so the pipe-and-extract scaffolding lives here.
nonisolated enum SegmentedArchive {
	static func extract(to directory: URL,
						selecting selector: EntrySelector? = nil,
						produce: @escaping @Sendable (ArchiveByteStream) async throws -> Void) async throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		guard let pipe = ArchiveByteStream.sharedBufferPipe(capacity: 64 << 20) else {
			throw SharedCacheError.malformedArchive("could not create archive pipe")
		}
		let input = pipe.input, output = pipe.output
		try await withThrowingTaskGroup(of: Void.self) { group in
			// Consumer: extract the archive as it streams in from the pipe.
			group.addTask {
				guard let decode = ArchiveStream.decodeStream(readingFrom: input) else {
					throw SharedCacheError.malformedArchive("could not open AppleArchive decode stream")
				}
				defer { try? decode.close() }
				guard let extract = ArchiveStream.extractStream(extractingTo: FilePath(directory.path),
						  flags: [.ignoreOperationNotPermitted]) else {
					throw SharedCacheError.malformedArchive("could not open AppleArchive extract stream")
				}
				defer { try? extract.close() }
				// The selector gates extraction only as `process`'s per-entry callback;
				// on `decodeStream` it's silently ignored and every entry is written.
				_ = try ArchiveStream.process(readingFrom: decode, writingTo: extract, selectUsing: selector)
			}
			// Producer: write the reconstructed archive bytes; closing signals EOF.
			group.addTask {
				defer { try? output.close() }
				try await produce(output)
			}
			try await group.waitForAll()
		}
	}
}

/// Reconstructs an OTA's payloadv2 stream into a system tree at `directory`,
/// decoding chunks in parallel and piping them, in order, straight into an
/// AppleArchive extraction so the multi-GB .yaa is never written to disk. The
/// chunk bytes come from `fetch` — the network for a zip OTA, local files for a
/// decrypted asset.
nonisolated enum OTAPayload {
	static func reconstruct(chunkCount: Int, to directory: URL,
							concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
							progress: (@Sendable (Int, Int) -> Void)? = nil,
							fetch: @escaping @Sendable (Int) async throws -> Data) async throws {
		try SharedCacheError.throw(.malformedArchive("OTA has no payloadv2 chunks"), if: chunkCount == 0)
		try await SegmentedArchive.extract(to: directory, selecting: SharedCache.cacheSelectionFilter()) { output in
			// Each chunk's job fetches it over the network and pbz-decodes it; the
			// shared writer runs them concurrently and pipes them in index order.
			try await output.writeOrdered(concurrency: concurrency, onWrite: { progress?($0, chunkCount) }) { submit in
				for index in 0..<chunkCount {
					try await submit { try PBZX.decode(try await fetch(index)) }
				}
			}
		}
	}
}

// MARK: - mounting a disk image and extracting the cache

/// A decrypted SystemOS cryptex is a raw APFS image; there's no public API to
/// attach a disk image, so we shell out to diskutil (the app is unsandboxed).
enum DiskImage {
	/// The slice of `diskutil image attach --plist` output we need (same plist
	/// shape hdiutil produced: `system-entities` with `mount-point`).
	private struct AttachResult: Decodable {
		var systemEntities: [Entity]
		enum CodingKeys: String, CodingKey { case systemEntities = "system-entities" }

		struct Entity: Decodable {
			var mountPoint: String?
			enum CodingKeys: String, CodingKey { case mountPoint = "mount-point" }
		}
	}

	/// Child processes must not inherit our `DYLD_*` injections (the debug dylib
	/// Xcode loads into the app) — tools like diskutil crash when they do.
	private static var cleanEnvironment: [String: String] {
		ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }
	}

	/// Attach `image` read-only and without showing it in the Finder, returning
	/// the mount point. Always pair with `detach`.
	static func attach(_ image: URL) throws -> URL {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.environment = cleanEnvironment
		process.arguments = ["image", "attach", "--readOnly", "--nobrowse", "--plist", image.path]
		let output = Pipe()
		process.standardOutput = output
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		try SharedCacheError.throw(.commandFailed("diskutil image attach exited \(process.terminationStatus)"),
								   if: process.terminationStatus != 0)
		let result = try PropertyListDecoder().decode(AttachResult.self, from: data)
		guard let mountPoint = result.systemEntities.compactMap(\.mountPoint).last else {
			throw SharedCacheError.commandFailed("diskutil image attach reported no mount point")
		}
		return URL(fileURLWithPath: mountPoint)
	}

	/// Detach a previously attached mount point. Best-effort; failures are ignored.
	static func detach(_ mountPoint: URL) {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.environment = cleanEnvironment
		process.arguments = ["eject", mountPoint.path]
		try? process.run()
		process.waitUntilExit()
	}
}

/// A read-only `ArchiveByteStream` over an in-memory `Data`, so a buffer we
/// already hold can be decoded as a (nested) archive without round-tripping it
/// through a scratch file. `ArchiveStream` decoding is pull-driven — bytes are
/// read only when the consumer calls `readHeader`/`readBlob` on its own thread —
/// so the cursor needs no locking.
private nonisolated final class DataByteStream: ArchiveByteStreamProtocol {
	private let data: Data
	private var position = 0

	init(_ data: Data) { self.data = data }

	func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
		let read = try read(into: buffer, atOffset: Int64(position))
		position += read
		return read
	}

	func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
		let start = Int(offset)
		guard start < data.count, let destination = buffer.baseAddress else { return 0 }
		let count = min(buffer.count, data.count - start)
		data.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress! + start, byteCount: count) }
		return count
	}

	func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
		let base: Int
		switch origin {
		case .current: base = position
		case .end: base = data.count
		default: base = 0   // .start
		}
		position = base + Int(offset)
		return Int64(position)
	}

	// Decode-only: the archive engine never writes to this stream.
	func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
		throw SharedCacheError.malformedArchive("DataByteStream is read-only")
	}
	func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
		throw SharedCacheError.malformedArchive("DataByteStream is read-only")
	}

	func cancel() {}
	func close() throws {}
}

/// A read-only `ArchiveByteStream` over an HTTP resource, served by range requests
/// with a sliding read-ahead window, so the AEA decryptor can consume the asset
/// straight off the network — no multi-GB file staged on disk. Reads are driven
/// synchronously by AppleArchive's pull thread; fetches run on `URLSession`'s own
/// threads (not the Swift cooperative pool, so a blocked reader can't deadlock
/// them) and the reader waits on `condition`. AEA decryption reads forward, so a
/// backward seek (rare) simply refetches. All mutable state is guarded by
/// `condition`, hence `@unchecked Sendable`.
private nonisolated final class NetworkByteStream: ArchiveByteStreamProtocol, @unchecked Sendable {
	private let url: URL
	private let length: Int
	private let baseOffset: Int   // byte offset in `url` where this logical stream begins
	private let chunkSize: Int
	private let readAhead: Int
	private let onProgress: (@Sendable (Int) -> Void)?

	private let condition = NSCondition()
	private var cache: [Int: Data] = [:]   // chunk index → fetched bytes
	private var fetching: Set<Int> = []     // chunk indices with a request in flight
	private var fetched = 0                  // cumulative bytes fetched, for progress
	private var position = 0                 // sequential read cursor
	private var failure: Error?              // first fetch error, surfaced to the reader
	private var closed = false

	init(url: URL, length: Int, baseOffset: Int = 0, chunkSize: Int = 16 << 20, readAhead: Int = 8,
		 onProgress: (@Sendable (Int) -> Void)? = nil) {
		self.url = url
		self.length = length
		self.baseOffset = baseOffset
		self.chunkSize = chunkSize
		self.readAhead = readAhead
		self.onProgress = onProgress
	}

	/// Start fetching chunk `index` unless it's cached or already in flight. The
	/// caller must hold `condition`; the completion handler reacquires it.
	private func fetch(_ index: Int) {
		let start = index * chunkSize
		guard start < length, cache[index] == nil, !fetching.contains(index) else { return }
		fetching.insert(index)
		var request = URLRequest(url: url)
		// Translate the logical chunk into an absolute byte range within `url`.
		request.setValue("bytes=\(baseOffset + start)-\(baseOffset + min(start + chunkSize, length) - 1)", forHTTPHeaderField: "Range")
		URLSession.shared.dataTask(with: request) { [self] data, response, error in
			condition.lock()
			defer { condition.unlock() }
			fetching.remove(index)
			if let data, (response as? HTTPURLResponse)?.statusCode == 206 {
				cache[index] = data
				fetched += data.count
				onProgress?(fetched)
			} else {
				failure = failure ?? (error ?? SharedCacheError.rangeNotHonored((response as? HTTPURLResponse)?.statusCode ?? -1))
			}
			condition.broadcast()
		}.resume()
	}

	func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
		condition.lock()
		let offset = position
		condition.unlock()
		let read = try self.read(into: buffer, atOffset: Int64(offset))
		condition.lock()
		position = offset + read
		condition.unlock()
		return read
	}

	func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
		let start = Int(offset)
		guard start < length, let destination = buffer.baseAddress, buffer.count > 0 else { return 0 }
		let index = start / chunkSize
		condition.lock()
		defer { condition.unlock() }
		// Prime this chunk and fill the read-ahead window.
		for ahead in index...(index + readAhead) { fetch(ahead) }
		while cache[index] == nil {
			if let failure { throw failure }
			if closed { return 0 }
			condition.wait()
		}
		let chunk = cache[index]!
		let within = start - index * chunkSize
		let count = min(buffer.count, chunk.count - within)
		chunk.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress! + within, byteCount: count) }
		// Drop chunks fully behind the cursor so memory stays bounded by the window.
		for key in Array(cache.keys) where key < index { cache.removeValue(forKey: key) }
		return count
	}

	func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
		condition.lock()
		defer { condition.unlock() }
		switch origin {
		case .current: position += Int(offset)
		case .end: position = length + Int(offset)
		default: position = Int(offset)   // .start
		}
		return Int64(position)
	}

	// Decode-only: the archive engine never writes to this stream.
	func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
		throw SharedCacheError.malformedArchive("NetworkByteStream is read-only")
	}
	func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
		throw SharedCacheError.malformedArchive("NetworkByteStream is read-only")
	}

	func cancel() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
	func close() throws { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
}

/// A decrypted OTA asset is a *segmented* Apple Archive: the outer archive's
/// entries are opaque "main" blobs, each itself an Apple Archive holding a slice
/// of the file tree, with the system payload in `payloadv2/payload.NNN` chunks.
/// This decrypts the AEA and streams those chunks straight into an AppleArchive
/// extraction — nothing (the decrypted asset, the segments, or the payload chunks)
/// is ever written to disk. Public APIs throughout (no `aa` subprocess); valid
/// because for a full OTA no file spans a segment.
nonisolated enum OTAAsset {
	static func decryptAndExtract(to directory: URL, key: SymmetricKey,
								  readingFrom makeEncryptedStream: @escaping @Sendable () -> ArchiveByteStream?) async throws {
		// Decrypt + walk the segmented asset, decoding its payloadv2 chunks into the
		// extraction pipe. The encrypted bytes come from `makeEncryptedStream` — a
		// file or a range-request-backed network stream.
		try await SegmentedArchive.extract(to: directory, selecting: SharedCache.cacheSelectionFilter()) { output in
			guard let encryptedStream = makeEncryptedStream() else {
				throw SharedCacheError.malformedArchive("could not open the encrypted asset stream")
			}
			defer { try? encryptedStream.close() }
			guard let context = ArchiveEncryptionContext(from: encryptedStream) else {
				throw SharedCacheError.malformedArchive("could not read AEA encryption context")
			}
			try context.setSymmetricKey(key)
			guard let decryption = ArchiveByteStream.decryptionStream(readingFrom: encryptedStream, encryptionContext: context),
				  let outer = ArchiveStream.decodeStream(readingFrom: decryption) else {
				throw SharedCacheError.malformedArchive("could not open AEA decryption stream")
			}
			defer { try? outer.close(); try? decryption.close() }
			let datKey = ArchiveHeader.FieldKey("DAT"), patKey = ArchiveHeader.FieldKey("PAT")
			// Reading the decrypted, segmented asset is inherently sequential, but
			// pbz-decoding each chunk is CPU-bound, so submit each chunk as a decode
			// job: the shared writer runs them concurrently and pipes them in read
			// order — the order they must be concatenated. Jobs decode the in-memory
			// `raw`, so the segment streams can be torn down while chunks still decode.
			let concurrency = ProcessInfo.processInfo.activeProcessorCount
			var fed = Set<Int>()
			try await output.writeOrdered(concurrency: concurrency) { submit in
				while let segmentHeader = try outer.readHeader() {
					guard let f = segmentHeader.field(forKey: datKey), case let .blob(_, size, _) = f else { continue }
					var segment = Data(count: Int(size))
					try segment.withUnsafeMutableBytes { try outer.readBlob(key: datKey, into: $0) }
					guard let segmentStream = ArchiveByteStream.customStream(instance: DataByteStream(segment)),
						  let inner = ArchiveStream.decodeStream(readingFrom: segmentStream) else { continue }
					defer { try? inner.close(); try? segmentStream.close() }
					while let entry = try inner.readHeader() {
						guard let pf = entry.field(forKey: patKey), case let .string(_, path) = pf,
							  path.contains("payloadv2/payload."),
							  let range = path.range(of: #"payload\.\d+$"#, options: .regularExpression),
							  let index = Int(path[range].dropFirst("payload.".count)), !fed.contains(index),
							  let df = entry.field(forKey: datKey), case let .blob(_, chunkSize, _) = df, chunkSize > 0 else { continue }
						// The same chunk name recurs data-less in the trailing manifest
						// segment, so `fed` keeps the first (real, data-bearing) one only.
						fed.insert(index)
						var chunk = Data(count: Int(chunkSize))
						try chunk.withUnsafeMutableBytes { try inner.readBlob(key: datKey, into: $0) }
						let raw = chunk
						try await submit { try PBZX.decode(raw) }
					}
				}
				try SharedCacheError.throw(.malformedArchive("OTA asset has no payloadv2 chunks"), if: fed.isEmpty)
			}
		}
	}
}

enum SharedCache {
	/// A primary dyld shared cache (the `dyld_shared_cache_<arch>` file with no
	/// suffix; its subcaches `.01`, `.symbols`, etc. sit beside it) and its arch.
	struct Cache: Sendable {
		var url: URL
		var architecture: String
		var isDriverKit: Bool
	}

	private static let prefix = "dyld_shared_cache_"

	/// The primary shared caches under a mounted/extracted system tree, by
	/// checking the known cache locations (so it works regardless of OS version
	/// or architecture — not just iOS arm64e). Includes the DriverKit cache when
	/// present; Xcode extracts both into the same Symbols tree.
	static func caches(under root: URL) -> [Cache] {
		let locations = [
			("System/Library/Caches/com.apple.dyld", false),
			("System/Library/dyld", false),
			("System/DriverKit/System/Library/dyld", true),
		]
		var caches: [Cache] = []
		for (path, isDriverKit) in locations {
			let directory = root.appendingPathComponent(path)
			let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
			for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension.isEmpty {
				caches.append(Cache(url: file,
									architecture: String(file.lastPathComponent.dropFirst(prefix.count)),
									isDriverKit: isDriverKit))
			}
		}
		return caches
	}
}
/// Run CPU-bound work off the main actor (on a detached task), bridged to async.
private func offMain<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
	try await Task.detached { try work() }.value
}

// MARK: - dsc_extractor (Xcode's shared-cache → dylibs extractor)
//
// Xcode ships dsc_extractor.bundle, which turns a dyld_shared_cache (plus its
// subcaches in the same directory) into the tree of individual dylibs that lands
// in DeviceSupport/.../Symbols. It exports one function taking an Objective-C
// block; in Swift a `@convention(block)` closure *is* that block, so we can call
// it directly (no C shim).

enum DSCExtractor {
	private typealias ExtractFunction = @convention(c) (
		UnsafePointer<CChar>, UnsafePointer<CChar>, @convention(block) (UInt32, UInt32) -> Void
	) -> Int32

	/// The dsc_extractor.bundle for `os` in the selected Xcode (override with DSC_BUNDLE).
	static func bundleURL(for os: OperatingSystem) throws -> URL {
		if let override = ProcessInfo.processInfo.environment["DSC_BUNDLE"] {
			return URL(fileURLWithPath: override)
		}
		// /var/db/xcode_select_link symlinks to the selected Developer directory.
		let developer = try FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")
		return URL(fileURLWithPath: developer)
			.appendingPathComponent("Platforms/\(os.extractorPlatform)/usr/lib/dsc_extractor.bundle")
	}

	/// Extract every dylib from `cache` (and the subcaches beside it) into
	/// `destination`, using the extractor for `os`. Safe to call repeatedly into
	/// the same destination for the main and DriverKit caches.
	static func extract(cache: URL, into destination: URL, os: OperatingSystem,
						progress: @escaping @Sendable (Double) -> Void) async throws {
		try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
		let bundle = try bundleURL(for: os)
		try SharedCacheError.throw(.commandFailed("dsc_extractor.bundle not found at \(bundle.path)"),
								   if: !FileManager.default.fileExists(atPath: bundle.path))
		try await offMain {
			guard let handle = dlopen(bundle.path, RTLD_LAZY) else {
				throw SharedCacheError.commandFailed("dlopen dsc_extractor failed: \(String(cString: dlerror()))")
			}
			defer { dlclose(handle) }
			guard let symbol = dlsym(handle, "dyld_shared_cache_extract_dylibs_progress") else {
				throw SharedCacheError.commandFailed("dsc_extractor is missing dyld_shared_cache_extract_dylibs_progress")
			}
			let function = unsafeBitCast(symbol, to: ExtractFunction.self)
			let result = cache.path.withCString { cachePath in
				destination.path.withCString { outputPath in
					function(cachePath, outputPath, { current, total in
						if total > 0 { progress(Double(current) / Double(total)) }
					})
				}
			}
			try SharedCacheError.throw(.commandFailed("dsc_extractor returned \(result) for \(cache.lastPathComponent)"),
									   if: result != 0)
		}
	}
}

// MARK: - building a DeviceSupport folder (the public entry point)
//
// `populate` is the whole job behind a platform/build/device picker + a
// "Populate" button — `OperatingSystem.allCases` feeds the platform list,
// `AppleDB.firmware(...).deviceMap` the device list, and `populate(target)` is the
// button action. It resolves → downloads → decrypts/extracts → runs dsc_extractor
// → lays out the folder at the right place under ~/Library/Developer/Xcode, and
// streams `Progress`. Scratch is cleaned up; only the finished folder remains.

enum DeviceSupport {
	/// A stage of the populate pipeline, for driving UI.
	enum Progress: Sendable {
		case resolving
		case downloading(Double)   // fraction complete, 0...1
		case decrypting
		case mounting
		case extracting(cache: String, fraction: Double)   // which cache, 0...1
		case finished(URL)                                 // the created DeviceSupport folder
	}

	/// Xcode's device-support root, `~/Library/Developer/Xcode`.
	static var xcodeDirectory: URL {
		FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode")
	}

	/// The device-support folders already present, parsed from their
	/// `<device> <version> (<build>)` names. iOS and iPadOS share one folder, so
	/// each folder is scanned once.
	static func installed(root: URL = xcodeDirectory) -> [InstalledSupport] {
		let fileManager = FileManager.default
		var scanned: Set<String> = []
		var result: [InstalledSupport] = []
		for os in OperatingSystem.allCases where scanned.insert(os.deviceSupportDirectory).inserted {
			let platform = os.deviceSupportDirectory.replacingOccurrences(of: " DeviceSupport", with: "")
			let directory = root.appendingPathComponent(os.deviceSupportDirectory)
			let folders = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
			for folder in folders {
				guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
				// "<device> <version> (<build>)" — device and version have no spaces.
				let name = folder.lastPathComponent
				guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { continue }
				let build = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
				let head = String(name[..<open]).trimmingCharacters(in: .whitespaces)
				guard let space = head.firstIndex(of: " ") else { continue }
				result.append(InstalledSupport(platform: platform,
											   device: String(head[..<space]),
											   version: String(head[head.index(after: space)...]),
											   build: build, url: folder))
			}
		}
		return result.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
	}

	/// Total size on disk of a device-support folder, summing its files. Walks
	/// thousands of extracted dylibs, so call it off the main actor.
	nonisolated static func size(of folder: URL) -> Int64 {
		let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
		guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
		var total: Int64 = 0
		for case let url as URL in enumerator {
			guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
			total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
		}
		return total
	}

	/// Download `target`'s shared cache and write its DeviceSupport folder to the
	/// appropriate location — `<root>/<OS> DeviceSupport/<device> <version>
	/// (<build>)` — streaming `Progress` for each stage. The work runs while the
	/// stream is consumed; cancelling the stream cancels it, and any error
	/// finishes the stream. Scratch lives under `scratch` and is cleaned up.
	static func populate(_ target: FirmwareTarget,
						 root: URL = xcodeDirectory,
						 scratch: URL = URL(fileURLWithPath: NSTemporaryDirectory())) -> AsyncThrowingStream<Progress, Error> {
		// dsc_extractor fires its progress block thousands of times in a couple of
		// seconds. Buffer only the newest value so the UI renders current progress
		// and drops the backlog, instead of replaying every stale frame long after
		// the work is done.
		AsyncThrowingStream(Progress.self, bufferingPolicy: .bufferingNewest(1)) { continuation in
			let task = Task {
				do {
					let folder = try await run(target, root: root, scratch: scratch) { continuation.yield($0) }
					continuation.yield(.finished(folder))
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private static func run(_ target: FirmwareTarget, root: URL, scratch: URL,
							emit: @escaping @Sendable (Progress) -> Void) async throws -> URL {
		emit(.resolving)
		let firmware = try await AppleDB.firmware(os: target.os, build: target.build, device: target.device)
		guard let source = firmware.cacheSource(for: target.device, on: target.os),
			  let link = source.links.first?.url else {
			throw SharedCacheError.malformedArchive(
				"no full cache source for \(target.device) in \(target.os.rawValue) \(target.build)")
		}

		let work = scratch.appendingPathComponent("DeviceSupport-\(target.build)-\(target.device)")
		try? FileManager.default.removeItem(at: work)
		try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
		var mountToDetach: URL?
		defer {
			if let mount = mountToDetach { DiskImage.detach(mount) }
			try? FileManager.default.removeItem(at: work)
		}

		// A modern OTA is one AEA-encrypted asset archive, not a zip, so there's no
		// central directory to read; the encrypted-OTA branch handles it from `link`.
		let isEncryptedOTA = source.type != "ipsw" && link.pathExtension == "aea"
		let zip = isEncryptedOTA ? nil : try await RemoteZip.read(link)
		let filesystem = try await filesystemRoot(link: link, zip: zip, source: source, work: work,
												  mountToDetach: &mountToDetach, emit: emit)

		let caches = SharedCache.caches(under: filesystem)
		guard let primary = caches.first(where: { !$0.isDriverKit }) else {
			throw SharedCacheError.malformedArchive("no dyld shared cache found in firmware")
		}
		let architecture = primary.architecture
		let toExtract = [primary] + caches.filter { $0.isDriverKit && $0.architecture == architecture }

		// Name the folder from the firmware's own SystemVersion.plist — the
		// official ProductVersion/ProductBuildVersion Xcode uses (e.g. "26.5",
		// "23F77") — not appledb's display string, which carries "beta"/"RC".
		let system = await systemVersion(in: filesystem, zip: zip)
		let version = system?.productVersion ?? firmware.version
		let build = system?.productBuildVersion ?? firmware.build

		let folder = root.appendingPathComponent(target.os.deviceSupportDirectory)
			.appendingPathComponent("\(target.device) \(version) (\(build))")
		let symbols = folder.appendingPathComponent(architecture).appendingPathComponent("Symbols")
		try FileManager.default.createDirectory(at: symbols, withIntermediateDirectories: true)
		FileManager.default.createFile(atPath: folder.appendingPathComponent(".copying_lock").path, contents: nil)

		for cache in toExtract {
			let label = cache.isDriverKit ? "DriverKit" : "system"
			try await DSCExtractor.extract(cache: cache.url, into: symbols, os: target.os) { fraction in
				emit(.extracting(cache: label, fraction: fraction))
			}
		}

		try finalize(folder: folder, architecture: architecture,
					 primaryCacheDirectory: primary.url.deletingLastPathComponent(), version: version)
		return folder
	}

	/// Produce a mounted/extracted filesystem root that contains the dyld caches.
	private static func filesystemRoot(link: URL, zip: RemoteZip?, source: Firmware.Source, work: URL,
									   mountToDetach: inout URL?,
									   emit: @escaping @Sendable (Progress) -> Void) async throws -> URL {
		// A modern OTA is a single AEA-encrypted, segmented asset Apple Archive. It
		// can't be range-sliced, so download it whole, then decrypt and stream its
		// `payloadv2/payload.NNN` chunks straight into the extraction — neither the
		// decrypted asset nor the chunks ever land on disk.
		if source.type != "ipsw", link.pathExtension == "aea" {
			// Stream the encrypted asset straight off the network into the decryptor
			// via a range-request-backed byte stream: only the filtered cache is ever
			// written to disk, never the multi-GB asset itself. Fetch just the
			// prologue first to unwrap the key.
			let length = try await HTTP.contentLength(of: link)
			let prologue = try await HTTP.range(link, 0, min(131_071, length - 1))
			let key = try await AEA.symmetricKey(fromPrologue: prologue)
			let extracted = work.appendingPathComponent("extracted")
			try await OTAAsset.decryptAndExtract(to: extracted, key: key) {
				ArchiveByteStream.customStream(instance: NetworkByteStream(url: link, length: length) { fetched in
					emit(.downloading(Double(fetched) / Double(length)))
				})
			}
			return extracted
		}
		guard let zip else {
			throw SharedCacheError.malformedArchive("missing archive index for \(link.lastPathComponent)")
		}
		if source.type == "ipsw" {
			let image = try await zip.cacheImageEntry()
			let dmg: URL
			if image.name.hasSuffix(".aea"), image.method == 0 {
				// Stream the encrypted cryptex image straight off the network into the
				// decryptor: the download overlaps decryption and the encrypted image
				// never lands on disk — only the decrypted dmg is written (diskutil
				// needs a file to attach). Stored (method 0) only, so the member bytes
				// are the raw `.aea`; the prologue (for the key) is its first bytes.
				let (payloadStart, payloadEnd) = try await zip.payloadRange(of: image)
				let size = payloadEnd - payloadStart + 1
				let prologue = try await HTTP.range(link, payloadStart, min(payloadStart + 131_071, payloadEnd))
				let key = try await AEA.symmetricKey(fromPrologue: prologue)
				dmg = work.appendingPathComponent("image.dmg")
				emit(.decrypting)
				try await AEA.decrypt(to: dmg, key: key) {
					ArchiveByteStream.customStream(instance: NetworkByteStream(url: link, length: size, baseOffset: payloadStart) { fetched in
						emit(.downloading(Double(fetched) / Double(size)))
					})
				}
			} else {
				// Older/unencrypted or deflated image: download (inflating if needed)
				// to disk, then decrypt in place when it's an AEA.
				let downloaded = work.appendingPathComponent("image")
				try await zip.download(image, to: downloaded) { written, total in
					emit(.downloading(Double(written) / Double(total)))
				}
				if image.name.hasSuffix(".aea") {
					emit(.decrypting)
					let handle = try FileHandle(forReadingFrom: downloaded)
					let head = try handle.read(upToCount: 131_072) ?? Data()
					try handle.close()
					let key = try await AEA.symmetricKey(fromPrologue: head)
					dmg = work.appendingPathComponent("image.dmg")
					let permissions = FilePermissions(rawValue: 0o644)
					try await AEA.decrypt(to: dmg, key: key) {
						ArchiveByteStream.fileStream(path: FilePath(downloaded.path), mode: .readOnly, options: [], permissions: permissions)
					}
					try? FileManager.default.removeItem(at: downloaded)
				} else {
					dmg = downloaded
				}
			}
			emit(.mounting)
			let mount = try DiskImage.attach(dmg)
			mountToDetach = mount
			return mount
		} else {
			let extracted = work.appendingPathComponent("extracted")
			try await zip.extractOTAPayload(to: extracted) { written, total in
				emit(.downloading(Double(written) / Double(total)))
			}
			return extracted
		}
	}

	/// Write the markers, Info.plist, and .finalized Xcode looks for.
	private static func finalize(folder: URL, architecture: String,
								 primaryCacheDirectory: URL, version: String) throws {
		let fileManager = FileManager.default
		// .processed_<name> at the folder level for the primary cache and its subcaches (not .atlas).
		let siblings = (try? fileManager.contentsOfDirectory(at: primaryCacheDirectory, includingPropertiesForKeys: nil)) ?? []
		for file in siblings where file.lastPathComponent.hasPrefix("dyld_shared_cache_\(architecture)") && file.pathExtension != "atlas" {
			fileManager.createFile(atPath: folder.appendingPathComponent(".processed_\(file.lastPathComponent)").path, contents: nil)
		}

		let archFolder = folder.appendingPathComponent(architecture)
		let info: [String: Any] = [
			"DSC Extractor Version": ProcessInfo.processInfo.environment["DSC_EXTRACTOR_VERSION"] ?? "27050.4.0.0.0",
			"DateCollected": Date(),
			"Version": version,
		]
		try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
			.write(to: archFolder.appendingPathComponent("Info.plist"))
		try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
			.write(to: archFolder.appendingPathComponent(".finalized"))
	}

	/// The firmware's official version/build, from its SystemVersion.plist.
	private struct SystemVersion: Decodable {
		var productVersion: String
		var productBuildVersion: String
		enum CodingKeys: String, CodingKey {
			case productVersion = "ProductVersion"
			case productBuildVersion = "ProductBuildVersion"
		}
	}

	/// Read SystemVersion.plist from the firmware: the mounted/extracted system
	/// carries it at the canonical path, and an IPSW also has it plaintext at the
	/// archive root.
	private static func systemVersion(in filesystem: URL, zip: RemoteZip?) async -> SystemVersion? {
		let onDisk = filesystem.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
		if let data = try? Data(contentsOf: onDisk),
		   let version = try? PropertyListDecoder().decode(SystemVersion.self, from: data) {
			return version
		}
		if let zip, let entry = zip.entries["SystemVersion.plist"],
		   let range = try? await zip.payloadRange(of: entry),
		   let raw = try? await HTTP.range(zip.url, range.start, range.end) {
			let data = entry.method == 8 ? ((try? (raw as NSData).decompressed(using: .zlib) as Data) ?? raw) : raw
			return try? PropertyListDecoder().decode(SystemVersion.self, from: data)
		}
		return nil
	}
}
