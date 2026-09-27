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

//
//  Pods.swift
//  container-compose-app
//
//  Pod support: services annotated with `x-pod: <name>` coalesce into a single
//  container VM under container-compose, so they share the kernel — Unix
//  sockets, block volumes (exclusive-attach), and loopback all work between
//  them, which shared filesystems can never provide. Docker ignores `x-` keys,
//  so Docker runtimes keep running every member as its own container.
//

import Foundation

/// A resolved pod: the primary service (which owns the VM) plus the init
/// members that will be executed inside it via `container exec`, in order.
public struct PodMember: Codable, Hashable {
    public let serviceName: String
    public let service: Service
    public init(serviceName: String, service: Service) {
        self.serviceName = serviceName
        self.service = service
    }
}

public struct PodGroup: @unchecked Sendable, Codable {
    public let name: String
    /// The long-running member whose image defines the VM's root filesystem.
    public let primary: PodMember
    /// One-shot members (`restart: "no"`), in the order they should execute.
    public let initMembers: [PodMember]

    /// True when `serviceName` belongs to this pod and is not the primary.
    public func isInitMember(_ serviceName: String) -> Bool {
        initMembers.contains { $0.serviceName == serviceName }
    }

    public init(name: String, primary: PodMember, initMembers: [PodMember]) {
        self.name = name
        self.primary = primary
        self.initMembers = initMembers
    }
}

public enum PodError: Error, CustomStringConvertible, Sendable {
    case noPrimary(pod: String)
    case multiplePrimaries(pod: String, primaries: [String])
    case imageMismatch(pod: String, primary: String, primaryImage: String, member: String, memberImage: String)
    case unsupportedMember(pod: String, member: String, reason: String)

    public var description: String {
        switch self {
        case .noPrimary(let pod):
            return "Pod '\(pod)' has no primary: every member is one-shot (restart: \"no\"). Mark the long-running service with `x-pod-primary: true`."
        case .multiplePrimaries(let pod, let primaries):
            return "Pod '\(pod)' declares multiple primaries (\(primaries.joined(separator: ", "))). Exactly one `x-pod-primary: true` is allowed."
        case .imageMismatch(let pod, let primary, let primaryImage, let member, let memberImage):
            return "Pod '\(pod)' member '\(member)' uses image '\(memberImage)' but primary '\(primary)' uses '\(primaryImage)'. Pod members must share the primary's image (exec runs inside the primary's root filesystem)."
        case .unsupportedMember(let pod, let member, let reason):
            return "Pod '\(pod)' member '\(member)' is not supported: \(reason)"
        }
    }
}

public enum PodSupport {
    /// True when the service is a one-shot (init) container under Compose
    /// semantics: no restart policy or an explicit `restart: "no"`.
    public static func isInitService(_ service: Service) -> Bool {
        guard let restart = service.restart?.lowercased() else { return true }
        return restart == "no" || restart == "none" || restart == "off"
    }

    /// Groups the given (topologically ordered) services into pods. Returns the
    /// services that start standalone (untouched, including pod primaries —
    /// their pod members are attached via `group.podMembers`) and one
    /// `PodGroup` per pod with two or more members.
    ///
    /// Validation rules:
    ///   - Exactly one primary per pod: explicit `x-pod-primary: true`, else
    ///     the first non-init member in service order.
    ///   - All members must use the same image as the primary.
    ///   - Init members must not define `entrypoint` (exec runs the command
    ///     array directly; there is no image entrypoint to wrap).
    ///   - Long-running (non-init) members other than the primary are rejected
    ///     in v1 — their lifecycle cannot be supervised independently yet.
    public static func resolvePods(
        _ services: [(serviceName: String, service: Service)]
    ) throws -> (standalone: [(serviceName: String, service: Service)], pods: [PodGroup]) {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceName, $0.service) })

        var grouped: [String: [(serviceName: String, service: Service)]] = [:]
        var standalone: [(serviceName: String, service: Service)] = []
        for entry in services {
            guard let podName = entry.service.pod else {
                standalone.append(entry)
                continue
            }
            grouped[podName, default: []].append(entry)
        }

        var pods: [PodGroup] = []
        for (podName, members) in grouped {
            // A single-member "pod" has nothing to coalesce; run it standalone.
            guard members.count > 1 else {
                standalone.append(contentsOf: members)
                continue
            }

            let explicitPrimaries = members.filter { $0.service.podPrimary == true }
            let primary: (serviceName: String, service: Service)
            switch explicitPrimaries.count {
            case 1:
                primary = explicitPrimaries[0]
            case 0:
                guard let elected = members.first(where: { !isInitService($0.service) }) else {
                    throw PodError.noPrimary(pod: podName)
                }
                primary = elected
            default:
                throw PodError.multiplePrimaries(pod: podName, primaries: explicitPrimaries.map(\.serviceName))
            }

            let primaryImage = try requireImage(primary.service, serviceName: primary.serviceName)
            var initMembers: [PodMember] = []
            for member in members where member.serviceName != primary.serviceName {
                let memberImage = try requireImage(member.service, serviceName: member.serviceName)
                guard memberImage == primaryImage else {
                    throw PodError.imageMismatch(
                        pod: podName, primary: primary.serviceName, primaryImage: primaryImage,
                        member: member.serviceName, memberImage: memberImage)
                }
                if isInitService(member.service) {
                    if member.service.entrypoint != nil {
                        throw PodError.unsupportedMember(
                            pod: podName, member: member.serviceName,
                            reason: "init members with a custom `entrypoint` are not supported (only `command`)")
                    }
                    initMembers.append(PodMember(serviceName: member.serviceName, service: member.service))
                } else {
                    throw PodError.unsupportedMember(
                        pod: podName, member: member.serviceName,
                        reason: "long-running sidecars are not supported in v1 — only the primary may run continuously")
                }
            }

            // The primary starts like any standalone service (with the union
            // of pod volumes); init members are executed inside it afterwards.
            standalone.append(primary)
            pods.append(PodGroup(
                name: podName,
                primary: PodMember(serviceName: primary.serviceName, service: primary.service),
                initMembers: initMembers))
        }

        // Keep standalone ordering stable; pods are returned in first-seen order.
        return (standalone, pods)
    }

    /// Merged volume entries for a pod primary: its own volumes plus every
    /// init member's volumes (deduplicated, order-preserving). All of them
    /// attach to the primary's single VM, which is what makes Unix sockets and
    /// block volumes work between members.
    public static func unionVolumes(primary: Service, initMembers: [PodMember]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for entry in ([primary] + initMembers.map(\.service)).compactMap(\.volumes) {
            for volume in entry where !seen.contains(volume) {
                seen.insert(volume)
                merged.append(volume)
            }
        }
        return merged
    }

    /// Flattened `KEY=VALUE` list for `container exec -e` flags: the member's
    /// resolved environment, overriding nothing on the primary itself.
    public static func execEnvironmentFlags(for service: Service, environmentVariables: [String: String]) -> [String] {
        let resolved = (service.environment ?? [:]).map { key, value in
            "\(key)=\(resolveVariable(value, with: environmentVariables))"
        }.sorted()
        return resolved.flatMap { ["-e", $0] }
    }

    /// The argv for `container exec ... <primary> <member command…>`. Members
    /// must use command-array form (`/bin/sh -c …` or similar); there is no
    /// image entrypoint to wrap inside the primary's VM.
    public static func execArgv(for service: Service) throws -> [String] {
        guard let command = service.command, !command.isEmpty else {
            throw PodError.unsupportedMember(pod: service.pod ?? "?", member: "member", reason: "no `command` to execute")
        }
        return command
    }

    private static func requireImage(_ service: Service, serviceName: String) throws -> String {
        guard let image = service.image else {
            throw PodError.unsupportedMember(
                pod: service.pod ?? "?", member: serviceName,
                reason: "pod members must use a fixed `image` (build-backed services are not supported)")
        }
        return image
    }
}
