//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing
import Foundation
@testable import ContainerComposeCore

/// Coverage for shared (host-backed) volume support: apple/container block
/// volumes attach to a single VM at a time, so volumes referenced by multiple
/// services are backed by a host directory instead.
@Suite("Shared Volumes")
struct SharedVolumesTests {

    let serviceVolumes: [(serviceName: String, volumes: [String])] = [
        ("postgres", ["postgres-socket:/var/run/postgresql", "postgres-data:/var/lib/postgresql/data"]),
        ("pw-reconcile", ["postgres-socket:/var/run/postgresql", "./config:/cfg"]),
        ("app", ["app-data:/data"]),
    ]

    // MARK: - computeSharedVolumes

    @Test("Auto mode selects volumes referenced by 2+ services")
    func autoMode() {
        let shared = computeSharedVolumes(serviceVolumes: serviceVolumes, mode: "auto")
        #expect(shared == ["postgres-socket"])
    }

    @Test("Never mode selects nothing")
    func neverMode() {
        #expect(computeSharedVolumes(serviceVolumes: serviceVolumes, mode: "never").isEmpty)
    }

    @Test("Always mode selects every named volume")
    func alwaysMode() {
        let shared = computeSharedVolumes(serviceVolumes: serviceVolumes, mode: "always")
        #expect(shared == Set(["postgres-socket", "postgres-data", "app-data"]))
    }

    @Test("Default (no env var) is auto")
    func defaultMode() {
        let shared = computeSharedVolumes(serviceVolumes: serviceVolumes, mode: nil)
        #expect(shared == ["postgres-socket"])
    }

    @Test("Interpolated volume names are resolved before refcounting")
    func interpolatedNames() {
        let shared = computeSharedVolumes(
            serviceVolumes: [
                ("a", ["${VOL_NAME}:/x"]),
                ("b", ["${VOL_NAME}:/x"]),
            ],
            environmentVariables: ["VOL_NAME": "shared-data"],
            mode: "auto"
        )
        #expect(shared == ["shared-data"])
    }

    @Test("Bind-mount entries are never treated as named volumes")
    func bindMountsExcluded() {
        let shared = computeSharedVolumes(
            serviceVolumes: [
                ("a", ["./host/dir:/x"]),
                ("b", ["/abs/path:/x"]),
            ],
            mode: "always"
        )
        #expect(shared.isEmpty)
    }

    // MARK: - composeVolumeToRunArgs

    @Test("Shared volume mounts a host directory")
    func sharedVolumeBecomesBindMount() throws {
        let args = try composeVolumeToRunArgs(
            "postgres-socket:/var/run/postgresql",
            cwd: "/tmp",
            projectName: "myproj",
            sharedVolumes: ["postgres-socket"]
        )
        #expect(args.count == 2)
        #expect(args[0] == "-v")
        #expect(args[1].hasSuffix(":/var/run/postgresql"))
        #expect(args[1].contains("shared-volumes/myproj_postgres-socket"))
        // The host directory must have been created.
        let hostPath = String(args[1].dropLast(":/var/run/postgresql".count))
        #expect(FileManager.default.fileExists(atPath: hostPath))
        try? FileManager.default.removeItem(atPath: hostPath)
    }

    @Test("Non-shared volume keeps the project-prefixed block volume name")
    func nonSharedKeepsBlockVolume() throws {
        let args = try composeVolumeToRunArgs(
            "app-data:/data",
            cwd: "/tmp",
            projectName: "myproj",
            sharedVolumes: []
        )
        #expect(args == ["-v", "myproj_app-data:/data"])
    }

    @Test("Mode suffix is preserved for shared volumes")
    func modeSuffixPreserved() throws {
        let args = try composeVolumeToRunArgs(
            "postgres-socket:/var/run/postgresql:ro",
            cwd: "/tmp",
            projectName: "myproj",
            sharedVolumes: ["postgres-socket"]
        )
        #expect(args[1].hasSuffix(":/var/run/postgresql:ro"))
    }

    // MARK: - sharedVolumeHostPath

    @Test("Host path is deterministic and project-prefixed")
    func hostPathDeterministic() {
        let a = sharedVolumeHostPath(projectName: "proj", volumeName: "data")
        let b = sharedVolumeHostPath(projectName: "proj", volumeName: "data")
        #expect(a == b)
        #expect(a.hasSuffix("com.apple.container/shared-volumes/proj_data"))
    }
}
