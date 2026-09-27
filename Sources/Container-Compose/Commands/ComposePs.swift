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
//  ComposePs.swift
//  Container-Compose
//
//  `container-compose ps` — list the compose project's services with their
//  container state, mirroring `docker compose ps` (subset).
//

import ArgumentParser
import ContainerAPIClient
import ContainerCommands
import Foundation

public struct ComposePs: AsyncParsableCommand {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "ps",
        abstract: "List the project's services and their container state"
    )

    @Argument(help: "Specify the services to list")
    var services: [String] = []

    @Flag(help: "Only show running services (like `docker compose ps`, which defaults to running-only)")
    var runningOnly = false

    @Flag(help: "Also list services gated by an inactive Compose profile")
    var all = false

    @OptionGroup
    var projectOptions: ComposeProjectOptions

    public func run() async throws {
        let project = try projectOptions.resolve(filteringBy: services)
        let client = ContainerClient()

        var rows: [(service: String, container: String, status: String, ip: String)] = []
        for target in project.services {
            var found: (name: String, status: String, ip: String)? = nil
            // Pod init members do not have their own container — they execute
            // inside the primary's VM.
            let isPodInitMember = target.service.pod != nil
                && target.service.podPrimary != true

            for candidate in target.candidateContainerNames {
                guard let container = try? await client.get(id: candidate) else { continue }
                let status: String
                switch container.status {
                case .running: status = "running"
                case .stopped: status = "exited"
                @unknown default: status = "\(container.status)"
                }
                let ip = container.networks.compactMap { $0.ipv4Address.address.description }.first ?? ""
                found = (candidate, status, ip)
                break
            }

            if isPodInitMember && found == nil {
                rows.append((target.serviceName, "(pod: \(podPrimaryName(for: target, in: project)))", "pod-exec", ""))
                continue
            }

            guard let f = found else {
                if !runningOnly {
                    rows.append((target.serviceName, "—", "not created", ""))
                }
                continue
            }
            if runningOnly && f.status != "running" { continue }
            rows.append((target.serviceName, f.name, f.status, f.ip))
        }

        // Column widths
        let widths = (
            service: max(rows.map(\.service.count).max() ?? 7, 7),
            container: max(rows.map(\.container.count).max() ?? 9, 9),
            status: max(rows.map(\.status.count).max() ?? 6, 6)
        )
        func pad(_ s: String, _ w: Int) -> String { s.padding(toLength: w, withPad: " ", startingAt: 0) }
        print("\(pad("SERVICE", widths.service))  \(pad("CONTAINER", widths.container))  \(pad("STATUS", widths.status))  IP")
        for row in rows {
            print("\(pad(row.service, widths.service))  \(pad(row.container, widths.container))  \(pad(row.status, widths.status))  \(row.ip)")
        }
        _ = all
    }

    private func podPrimaryName(for target: ComposeProject.ServiceTarget, in project: ComposeProject) -> String {
        let podName = target.service.pod ?? ""
        let primaries = project.services.filter {
            $0.service.pod == podName && $0.service.podPrimary == true
        }
        if primaries.isEmpty {
            // Fall back to the first non-init member.
            return project.services.first {
                $0.service.pod == podName && !($0.service.restart.map { $0.lowercased() == "no" } ?? true)
            }?.serviceName ?? podName
        }
        return primaries[0].serviceName
    }
}
