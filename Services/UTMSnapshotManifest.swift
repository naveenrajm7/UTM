//
// Copyright © 2026 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

/// A single named full-VM snapshot recorded in the manifest.
struct UTMSnapshotEntry: Codable, Identifiable, Sendable, Equatable {
    /// User visible name. Unique (case-insensitive) within a VM.
    let name: String
    /// When the snapshot was taken.
    let created: Date
    /// Backend that owns the snapshot data.
    let backend: UTMBackend
    /// Optional user description.
    var description: String?
    var id: String { name }
}

/// The on-disk source of truth for named snapshots, stored at `{bundle}/Snapshots/manifest.plist`.
///
/// Snapshots live at the bundle root (sibling to `Data/`) so that they are not swept away by
/// `UTMConfiguration.save()` which cleans up unreferenced files under `Data/`.
struct UTMSnapshotManifest: Codable, Sendable {
    /// Snapshot name reserved for the internal suspend/resume feature.
    static let reservedSuspendName = "suspend"
    /// Directory (relative to the bundle root) that holds all snapshot data.
    static let directoryName = "Snapshots"
    /// Manifest file name inside `Snapshots/`.
    static let fileName = "manifest.plist"

    private(set) var entries: [UTMSnapshotEntry]

    init(entries: [UTMSnapshotEntry] = []) {
        self.entries = entries
    }

    // MARK: - Locations

    static func directoryURL(forBundle bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(directoryName)
    }

    static func manifestURL(forBundle bundleURL: URL) -> URL {
        directoryURL(forBundle: bundleURL).appendingPathComponent(fileName)
    }

    // MARK: - Persistence

    /// Load the manifest for a VM bundle, returning an empty manifest if none exists.
    static func load(fromBundle bundleURL: URL) throws -> UTMSnapshotManifest {
        let url = manifestURL(forBundle: bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return UTMSnapshotManifest()
        }
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(UTMSnapshotManifest.self, from: data)
    }

    /// Persist the manifest, creating the `Snapshots/` directory if needed.
    func save(toBundle bundleURL: URL) throws {
        let directoryURL = Self.directoryURL(forBundle: bundleURL)
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: Self.manifestURL(forBundle: bundleURL))
    }

    // MARK: - Queries

    func all() -> [UTMSnapshotEntry] {
        entries
    }

    func find(name: String) -> UTMSnapshotEntry? {
        entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Mutations

    /// Add a new entry, rejecting duplicates (case-insensitive) and reserved/invalid names.
    mutating func add(_ entry: UTMSnapshotEntry) throws {
        try Self.validate(name: entry.name)
        guard find(name: entry.name) == nil else {
            throw UTMSnapshotError.duplicateName(entry.name)
        }
        entries.append(entry)
    }

    /// Remove an entry by name (case-insensitive). Returns the removed entry, if any.
    @discardableResult
    mutating func remove(name: String) -> UTMSnapshotEntry? {
        guard let index = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        return entries.remove(at: index)
    }

    // MARK: - Validation

    /// Validate a user-supplied snapshot name.
    ///
    /// Rules: must match `[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}` and must not be the reserved
    /// suspend name.
    static func validate(name: String) throws {
        if name.caseInsensitiveCompare(reservedSuspendName) == .orderedSame {
            throw UTMSnapshotError.reservedName(name)
        }
        let pattern = "^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw UTMSnapshotError.invalidName(name)
        }
    }

}

// MARK: - Errors

enum UTMSnapshotError: Error {
    case reservedName(String)
    case duplicateName(String)
    case invalidName(String)
    case notFound(String)
    case notSupported
    case invalidVmState
}

extension UTMSnapshotError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .reservedName(let name):
            return String.localizedStringWithFormat(NSLocalizedString("The name '%@' is reserved and cannot be used for a snapshot.", comment: "UTMSnapshotManifest"), name)
        case .duplicateName(let name):
            return String.localizedStringWithFormat(NSLocalizedString("A snapshot named '%@' already exists.", comment: "UTMSnapshotManifest"), name)
        case .invalidName(let name):
            return String.localizedStringWithFormat(NSLocalizedString("The name '%@' is not a valid snapshot name. Use letters, numbers, spaces, and the characters _.- (up to 64 characters).", comment: "UTMSnapshotManifest"), name)
        case .notFound(let name):
            return String.localizedStringWithFormat(NSLocalizedString("No snapshot named '%@' was found.", comment: "UTMSnapshotManifest"), name)
        case .notSupported:
            return NSLocalizedString("Snapshots are not supported for this virtual machine.", comment: "UTMSnapshotManifest")
        case .invalidVmState:
            return NSLocalizedString("The virtual machine is in an invalid state for this snapshot operation.", comment: "UTMSnapshotManifest")
        }
    }
}
