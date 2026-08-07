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
import Logging

private let snapshotLogger = Logger(label: "com.utmapp.UTM.snapshot") { label in
    UTMLoggingSwift(label: label)
}

/// Coordinates named full-VM snapshots across backends.
///
/// The `Snapshots/manifest.plist` inside the `.utm` bundle is the source of truth for the list
/// of snapshots. Backend-specific state (QEMU: inside the qcow2; Apple: a per-snapshot vmstate
/// file) is written/read by the backend's `saveSnapshot(name:)`, `restoreSnapshot(name:)`, and
/// `deleteSnapshot(name:)`. The manifest is only mutated after the backend operation succeeds so
/// the manifest never claims a snapshot that was not actually written (or fails to delete one).
///
/// This is distinct from the internal suspend/resume feature which uses the reserved name
/// `"suspend"` and `registryEntry.isSuspended`; user snapshots never touch that state.
@MainActor
enum UTMSnapshotService {
    /// Create a named snapshot capturing the full VM state (RAM + devices + disk).
    static func createSnapshot(name: String, description: String?, on vm: any UTMVirtualMachine) async throws {
        try UTMSnapshotManifest.validate(name: name)
        if let error = vm.snapshotUnsupportedError {
            throw error
        }
        var manifest = try UTMSnapshotManifest.load(fromBundle: vm.pathUrl)
        guard manifest.find(name: name) == nil else {
            throw UTMSnapshotError.duplicateName(name)
        }
        // capturing RAM requires the VM to be running or paused on both backends
        guard vm.state == .started || vm.state == .paused else {
            throw UTMSnapshotError.invalidVmState
        }
        let backend = manifestBackend(of: vm)
        let stateFile: String?
        if backend == .apple {
            stateFile = "\(UTMSnapshotManifest.sanitizedFolderName(for: name))/\(kSnapshotStateFileName)"
        } else {
            stateFile = nil
        }
        snapshotLogger.debug("Creating snapshot '\(name)' on \(backend.rawValue) VM")
        try await vm.saveSnapshot(name: name)
        let entry = UTMSnapshotEntry(name: name, created: Date(), backend: backend, description: description, stateFile: stateFile)
        try manifest.add(entry)
        try manifest.save(toBundle: vm.pathUrl)
    }

    /// List all named snapshots recorded in the manifest, newest first.
    static func listSnapshots(on vm: any UTMVirtualMachine) throws -> [UTMSnapshotEntry] {
        let manifest = try UTMSnapshotManifest.load(fromBundle: vm.pathUrl)
        return manifest.all().sorted { $0.created > $1.created }
    }

    /// Restore the VM to a previously captured named snapshot.
    static func restoreSnapshot(name: String, on vm: any UTMVirtualMachine) async throws {
        let manifest = try UTMSnapshotManifest.load(fromBundle: vm.pathUrl)
        guard let entry = manifest.find(name: name) else {
            throw UTMSnapshotError.notFound(name)
        }
        snapshotLogger.debug("Restoring snapshot '\(entry.name)' on \(entry.backend.rawValue) VM")
        try await vm.restoreSnapshot(name: entry.name)
    }

    /// Delete a named snapshot and its backend state.
    static func deleteSnapshot(name: String, on vm: any UTMVirtualMachine) async throws {
        var manifest = try UTMSnapshotManifest.load(fromBundle: vm.pathUrl)
        guard let entry = manifest.find(name: name) else {
            throw UTMSnapshotError.notFound(name)
        }
        // QEMU deletes the tag from the running qcow2 via the monitor, so it must be running.
        // Apple simply removes the on-disk state file and can do so in any state.
        if entry.backend == .qemu && vm.state != .started && vm.state != .paused {
            throw UTMSnapshotError.invalidVmState
        }
        snapshotLogger.debug("Deleting snapshot '\(entry.name)' on \(entry.backend.rawValue) VM")
        try await vm.deleteSnapshot(name: entry.name)
        manifest.remove(name: entry.name)
        try manifest.save(toBundle: vm.pathUrl)
    }

    // MARK: - Helpers

    private static func manifestBackend(of vm: any UTMVirtualMachine) -> UTMBackend {
        #if os(macOS)
        if #available(macOS 11, *), vm is UTMAppleVirtualMachine {
            return .apple
        }
        #endif
        return .qemu
    }
}

/// File name for a per-snapshot saved state (Apple backend).
let kSnapshotStateFileName = "vmstate"
