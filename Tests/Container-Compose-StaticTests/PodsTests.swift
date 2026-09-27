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
@testable import Yams
@testable import ContainerComposeCore

/// Coverage for `x-pod` support: grouping, primary election, validation, and
/// volume union. See Pods.swift for the semantics.
@Suite("Pods")
struct PodsTests {

    private func service(
        image: String = "app:latest",
        restart: String? = nil,
        pod: String? = nil,
        podPrimary: Bool? = nil,
        command: [String]? = nil,
        entrypoint: [String]? = nil,
        volumes: [String]? = nil
    ) -> Service {
        let yaml = """
        services:
          svc:
            image: \(image)
            \(restart.map { "restart: \($0)" } ?? "")
            \(pod.map { "x-pod: \($0)" } ?? "")
            \(podPrimary.map { "x-pod-primary: \($0)" } ?? "")
            \(command.map { "command: [\($0.map { "'\($0)'" }.joined(separator: ", "))]" } ?? "")
            \(entrypoint.map { "entrypoint: [\($0.map { "'\($0)'" }.joined(separator: ", "))]" } ?? "")
            \(volumes.map { "volumes: [\($0.map { "'\($0)'" }.joined(separator: ", "))]" } ?? "")
        """
        return try! YAMLDecoder().decode(DockerCompose.self, from: yaml).services["svc"]!!
    }

    private func svc(_ name: String, _ service: Service) -> (serviceName: String, service: Service) {
        (name, service)
    }

    // MARK: - resolvePods

    @Test("Primary elected automatically from non-init member")
    func primaryElection() throws {
        let (standalone, pods) = try PodSupport.resolvePods([
            // long-running (restart policy set) → primary
            svc("db", service(image: "pg:15", restart: "unless-stopped", pod: "db-plane")),
            svc("reconcile", service(image: "pg:15", pod: "db-plane", command: ["sh", "-c", "echo"])),
        ])
        #expect(standalone.count == 1)
        #expect(standalone[0].serviceName == "db")
        #expect(pods.count == 1)
        #expect(pods[0].primary.serviceName == "db")
        #expect(pods[0].initMembers.map(\.serviceName) == ["reconcile"])
    }

    @Test("Explicit x-pod-primary wins over election")
    func explicitPrimary() throws {
        let (_, pods) = try PodSupport.resolvePods([
            svc("one-shot", service(image: "pg:15", restart: "no", pod: "p", command: ["sh", "-c", "echo"])),
            svc("main", service(image: "pg:15", restart: "unless-stopped", pod: "p", podPrimary: true)),
        ])
        #expect(pods[0].primary.serviceName == "main")
    }

    @Test("All-init pod without explicit primary errors")
    func noPrimary() {
        #expect(throws: PodError.self) {
            _ = try PodSupport.resolvePods([
                svc("a", service(image: "pg:15", restart: "no", pod: "p", command: ["sh", "-c", "echo"])),
                svc("b", service(image: "pg:15", restart: "no", pod: "p", command: ["sh", "-c", "echo"])),
            ])
        }
    }

    @Test("Image mismatch errors")
    func imageMismatch() {
        #expect(throws: PodError.self) {
            _ = try PodSupport.resolvePods([
                svc("db", service(image: "pg:15", pod: "p")),
                svc("other", service(image: "alpine:3.19", pod: "p", command: ["sh", "-c", "echo"])),
            ])
        }
    }

    @Test("Non-init sidecar member errors in v1")
    func sidecarRejected() {
        #expect(throws: PodError.self) {
            _ = try PodSupport.resolvePods([
                svc("db", service(image: "pg:15", restart: "unless-stopped", pod: "p")),
                svc("sidecar", service(image: "pg:15", restart: "always", pod: "p", command: ["sh", "-c", "echo"])),
            ])
        }
    }

    @Test("Init member with entrypoint errors")
    func entrypointRejected() {
        #expect(throws: PodError.self) {
            _ = try PodSupport.resolvePods([
                svc("db", service(image: "pg:15", pod: "p")),
                svc("init", service(image: "pg:15", restart: "no", pod: "p", command: ["sh", "-c", "echo"], entrypoint: ["/bin/sh", "-c"])),
            ])
        }
    }

    @Test("Single-member pod runs standalone")
    func singleMemberStandalone() throws {
        let (standalone, pods) = try PodSupport.resolvePods([
            svc("solo", service(image: "pg:15", pod: "p")),
        ])
        #expect(pods.isEmpty)
        #expect(standalone.map(\.serviceName) == ["solo"])
    }

    // MARK: - volume union

    @Test("Volumes union dedupes and preserves order")
    func volumeUnion() {
        let primary = service(image: "pg:15", volumes: ["shared:/var/run/x", "own:/data"])
        let member = service(image: "pg:15", restart: "no", volumes: ["shared:/var/run/x", "extra:/cfg"])
        let union = PodSupport.unionVolumes(
            primary: primary,
            initMembers: [PodMember(serviceName: "m", service: member)])
        #expect(union == ["shared:/var/run/x", "own:/data", "extra:/cfg"])
    }

    // MARK: - exec environment

    @Test("Exec env flags resolve variables")
    func execEnv() {
        let member = service(image: "pg:15", command: ["sh", "-c", "echo"])
        let flags = PodSupport.execEnvironmentFlags(
            for: member,
            environmentVariables: ["HOST": "ignored"])  // process env overrides — but member env wins per-key
        // member has no explicit environment → no flags
        #expect(flags.isEmpty)
    }

    // MARK: - decoding

    @Test("x-pod keys decode from YAML and are Docker-ignored extensions")
    func podKeysDecode() throws {
        let yaml = """
        services:
          db:
            image: pg:15
            x-pod: db-plane
            x-pod-primary: true
          init:
            image: pg:15
            restart: "no"
            x-pod: db-plane
            command: ["sh", "-c", "echo hi"]
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.services["db"]??.pod == "db-plane")
        #expect(compose.services["db"]??.podPrimary == true)
        #expect(compose.services["init"]??.pod == "db-plane")
        #expect(compose.services["init"]??.podPrimary == nil)

        let (standalone, pods) = try PodSupport.resolvePods([
            svc("db", compose.services["db"]!!),
            svc("init", compose.services["init"]!!),
        ])
        #expect(pods.count == 1)
        #expect(pods[0].primary.serviceName == "db")
        #expect(pods[0].initMembers.map(\.serviceName) == ["init"])
        #expect(standalone.map(\.serviceName) == ["db"])
    }
}

extension PodsTests {
    @Test("Pod primary keeps its topological position in standalone order")
    func primaryKeepsTopologicalPosition() throws {
        let (standalone, pods) = try PodSupport.resolvePods([
            svc("gate", service(image: "pg:15", restart: "unless-stopped")),
            svc("one-shot", service(image: "pg:15", restart: "no", pod: "p", command: ["sh", "-c", "echo"])),
            svc("db", service(image: "pg:15", restart: "unless-stopped", pod: "p")),
            svc("dependent", service(image: "pg:15", restart: "unless-stopped")),
        ])
        // "db" (the primary) must stay at index 1 — after "gate", before
        // "dependent" — not appended to the end, or services gating on it
        // would evaluate before it exists.
        #expect(standalone.map(\.serviceName) == ["gate", "db", "dependent"])
        #expect(pods.count == 1)
        #expect(pods[0].initMembers.map(\.serviceName) == ["one-shot"])
    }
}
