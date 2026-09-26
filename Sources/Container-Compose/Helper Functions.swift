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
//  Helper Functions.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams
import Rainbow
import ContainerCommands
import ContainerAPIClient

public func resolvedPath(for path: String, relativeTo baseURL: URL) -> String {
    let expandedPath = NSString(string: path).expandingTildeInPath
    return URL(fileURLWithPath: expandedPath, relativeTo: baseURL).standardizedFileURL.path
}


/// The standard executable directories appended as a fallback when building the
/// PATH for spawned `container` processes.
public let standardExecutablePathFallback = [
    "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
]

/// Builds the PATH used for spawned child processes by preserving the user's
/// inherited PATH and appending any standard fallback directories that are not
/// already present. This keeps `container` binaries installed outside the
/// standard locations (e.g. Nix at `/run/current-system/sw/bin`) reachable while
/// still guaranteeing the common Homebrew/system directories are available.
/// - Parameters:
///   - existing: The inherited PATH value (typically `$PATH`), or `nil` if unset.
///   - fallback: The standard directories to ensure are present.
/// - Returns: A `:`-separated PATH string preserving the user's order, followed
///   by any missing fallback directories.
public func mergedExecutablePath(
    existing: String?,
    fallback: [String] = standardExecutablePathFallback
) -> String {
    let existingEntries = (existing ?? "")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map(String.init)

    var seen = Set(existingEntries)
    var merged = existingEntries

    for dir in fallback where !seen.contains(dir) {
        merged.append(dir)
        seen.insert(dir)
    }

    return merged.joined(separator: ":")
}

/// Loads environment variables from a .env file.
/// - Parameter path: The full path to the .env file.
/// - Returns: A dictionary of key-value pairs representing environment variables.
public func loadEnvFile(path: String) -> [String: String] {
    var envVars: [String: String] = [:]
    let fileURL = URL(fileURLWithPath: path)
    do {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Ignore empty lines and comments
            if !trimmedLine.isEmpty && !trimmedLine.starts(with: "#") {
                // Parse key=value pairs
                if let eqIndex = trimmedLine.firstIndex(of: "=") {
                    let key = String(trimmedLine[..<eqIndex])
                    let value = String(trimmedLine[trimmedLine.index(after: eqIndex)...])
                    envVars[key] = value
                }
            }
        }
    } catch {
        // print("Warning: Could not read .env file at \(path): \(error.localizedDescription)")
        // Suppress error message if .env file is optional or missing
    }
    return envVars
}

/// Resolves environment variables within a string (e.g., ${VAR:-default}, ${VAR:?error}).
/// This function supports default values and error-on-missing variable syntax.
/// - Parameters:
///   - value: The string possibly containing environment variable references.
///   - envVars: A dictionary of environment variables to use for resolution.
/// - Returns: The string with all recognized environment variables resolved.
public func resolveVariable(_ value: String, with envVars: [String: String]) -> String {
    // Combine process environment with loaded .env file variables, prioritizing process environment
    let combinedEnv = ProcessInfo.processInfo.environment.merging(envVars) { (current, _) in current }

    // Scan for `${...}` expressions, handling nested `${}` inside default values
    // (e.g. `${A:-${B:-fallback}}`), which regex-based matching cannot parse.
    var result = ""
    var i = value.startIndex
    while i < value.endIndex {
        if value[i] == "$", let (inner, afterExpr) = matchBracedExpression(value, at: i) {
            result += resolveExpression(inner, envVars: combinedEnv)
            i = afterExpr
        } else {
            result.append(value[i])
            i = value.index(after: i)
        }
    }
    return result
}

/// If `s` contains a well-braced `${` expression starting at `start`, returns
/// the inner expression text (without `${}`) and the index just past the
/// closing `}`, honouring nested `${` sequences.
private func matchBracedExpression(_ s: String, at start: String.Index) -> (String, String.Index)? {
    var i = s.index(after: start)
    guard i < s.endIndex, s[i] == "{" else { return nil }
    var depth = 1
    i = s.index(after: i)
    let contentStart = i
    while i < s.endIndex {
        if s[i] == "$", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "{" {
            depth += 1
            i = s.index(after: i)
        } else if s[i] == "}" {
            depth -= 1
            if depth == 0 {
                return (String(s[contentStart..<i]), s.index(after: i))
            }
        }
        i = s.index(after: i)
    }
    return nil
}

/// Resolves the inner text of a `${...}` expression: `VAR`, `VAR:-default`,
/// `VAR-default`, `VAR:?error`, `VAR?error`.
private func resolveExpression(_ expr: String, envVars: [String: String]) -> String {
    let twoCharOps = topLevelOperator(expr, operators: [":-", ":?"])
    let oneCharOps = twoCharOps == nil ? topLevelOperator(expr, operators: ["-", "?"]) : nil
    if let at = twoCharOps ?? oneCharOps {
        let isColonPrefixed = expr[at] == ":"
        let name = String(expr[expr.startIndex..<at])
        var operandStart = expr.index(after: at)
        if isColonPrefixed {
            // Skip the `-`/`?` after the `:` (an `=` after `:` is not a
            // supported operator and is treated as part of the operand).
            if operandStart < expr.endIndex, "-?".contains(expr[operandStart]) {
                operandStart = expr.index(after: operandStart)
            }
        }
        let op = String(expr[at..<(isColonPrefixed ? operandStart : expr.index(after: at))])
        let operand = String(expr[operandStart...])
        let hasValue = envVars.keys.contains(name) && envVars[name]!.isEmpty == false
        switch op {
        case ":-":
            if hasValue { return envVars[name]! }
            return resolveVariable(operand, with: envVars)
        case "-":
            if let value = envVars[name] { return value }
            return resolveVariable(operand, with: envVars)
        case ":?", "?":
            guard hasValue || (op == "?" && envVars[name] != nil) else {
                fputs("Error: Missing required environment variable '\(name)': \(operand)\n", stderr)
                Application.exit(withError: "Error: Missing required environment variable '\(name)': \(operand)\n")
            }
            return envVars[name]!
        default:
            break
        }
    }
    if let value = envVars[expr] {
        return value
    }
    // Unknown variable without default: leave the expression as written.
    return "${\(expr)}"
}

/// Finds the first top-level occurrence of any operator string in `expr`
/// (top-level = not inside a nested `${...}`), returning the index of its
/// first character. Length-2 operators (`:-`, `:?`) are preferred over `-`/`?`.
private func topLevelOperator(_ expr: String, operators: [String]) -> String.Index? {
    var depth = 0
    var i = expr.startIndex
    while i < expr.endIndex {
        if expr[i] == "$", expr.index(after: i) < expr.endIndex, expr[expr.index(after: i)] == "{" {
            depth += 1
            i = expr.index(after: i)
        } else if expr[i] == "}" {
            depth = max(0, depth - 1)
        } else if depth == 0 {
            for op in operators {
                let end = expr.index(i, offsetBy: op.count, limitedBy: expr.endIndex) ?? expr.endIndex
                if String(expr[i..<end]) == op {
                    return i
                }
            }
        }
        i = expr.index(after: i)
    }
    return nil
}

/// Derives a project name from the current working directory. It replaces any '.' characters with
/// '_' to ensure compatibility with container naming conventions.
///
/// - Parameter cwd: The current working directory path.
/// - Returns: A sanitized project name suitable for container naming.
public func deriveProjectName(cwd: String) -> String {
    // We need to replace '.' with _ because it is not supported in the container name
    let projectName = URL(fileURLWithPath: cwd).lastPathComponent.replacingOccurrences(of: ".", with: "_")
    return projectName
}

/// Converts Docker Compose port specification into a container run -p format.
/// Handles various formats: "PORT", "HOST:PORT", "IP:HOST:PORT", and optional protocol.
/// - Parameter portSpec: The port specification string from docker-compose.yml.
/// - Returns: A properly formatted port binding for `container run -p`.
public func composePortToRunArg(_ portSpec: String) -> String {
    // Check for protocol suffix (e.g., "/tcp" or "/udp")
    var protocolSuffix = ""
    var portBody = portSpec
    if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
        let afterSlash = portSpec[slashRange.lowerBound...]
        let protocolPart = String(afterSlash)
        if protocolPart == "/tcp" || protocolPart == "/udp" {
            protocolSuffix = protocolPart
            portBody = String(portSpec[..<slashRange.lowerBound])
        }
    }

    let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
    switch components.count {
    case 1:
        let containerPort = components[0]
        return "0.0.0.0:\(containerPort):\(containerPort)\(protocolSuffix)"
    case 2:
        let hostPart = components[0]
        let containerPart = components[1]
        let hasIPv4 = hostPart.contains(".")
        let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
        if hasIPv4 || hasIPv6 {
            return "\(hostPart):\(containerPart)\(protocolSuffix)"
        } else {
            return "0.0.0.0:\(hostPart):\(containerPart)\(protocolSuffix)"
        }
    case 3:
        let ipPart = components[0]
        let hostPart = components[1]
        let containerPart = components[2]
        return "\(ipPart):\(hostPart):\(containerPart)\(protocolSuffix)"
    default:
        return portSpec
    }
}

/// Converts a Docker Compose `volumes:` entry into the `--volume` arguments for `container run`.
/// Internal so tests can reach it via `@testable import ContainerComposeCore`.
///
/// Named volumes listed in `sharedVolumes` are backed by a host directory
/// (bind mount) instead of an apple/container block volume. apple/container
/// attaches block volumes to a single VM at a time, so services that must
/// share a volume concurrently (init/sidecar patterns) can only do so through
/// a virtiofs-backed host directory. See `computeSharedVolumes`.
func composeVolumeToRunArgs(
    _ volume: String,
    cwd: String,
    fileManager: FileManager = .default,
    environmentVariables: [String: String] = [:],
    projectName: String?,
    volumeDefinitions: [String: Volume?]? = nil,
    sharedVolumes: Set<String> = []
) throws -> [String] {
    let resolvedVolume = resolveVariable(volume, with: environmentVariables)
    var args: [String] = []

    let components = resolvedVolume.split(separator: ":", maxSplits: 2).map(String.init)
    guard components.count >= 2 else {
        print("Warning: Volume entry '\(resolvedVolume)' has an invalid format (expected 'source:destination'). Skipping.")
        return []
    }

    let source = components[0]
    let destination = components[1]
    let mode = components.count == 3 ? components[2] : nil

    func bindMountArg(source: String) -> String {
        if let mode { return "\(source):\(destination):\(mode)" }
        return "\(source):\(destination)"
    }

    func fallbackToNamedVolume() -> [String] {
        let volumeDefinition = volumeDefinitions?[source] ?? nil
        let actualVolumeName = composeNamedVolumeName(
            source: source,
            projectName: projectName,
            volumeDefinition: volumeDefinition
        )
        args.append("-v")
        args.append(bindMountArg(source: actualVolumeName))
        return args
    }

    if source.contains("/") || source.starts(with: ".") || source.starts(with: "..") {
        let fullHostPath = resolvedPath(for: source, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true))

        if fileManager.fileExists(atPath: fullHostPath) {
            args.append("-v")
            args.append(bindMountArg(source: fullHostPath))
        } else {
            do {
                try fileManager.createDirectory(atPath: fullHostPath, withIntermediateDirectories: true, attributes: nil)
                print("Info: Created missing host directory for volume: \(fullHostPath)")
                args.append("-v")
                args.append(bindMountArg(source: fullHostPath))
            } catch {
                print("Error: Could not create host directory '\(fullHostPath)' for volume '\(resolvedVolume)': \(error.localizedDescription). Skipping this volume.")
            }
        }
    } else {
        if sharedVolumes.contains(source) {
            let hostPath = sharedVolumeHostPath(projectName: projectName, volumeName: source)
            do {
                try fileManager.createDirectory(atPath: hostPath, withIntermediateDirectories: true)
            } catch {
                print("Warning: Could not create shared volume directory '\(hostPath)': \(error.localizedDescription). Falling back to a block volume.")
                return fallbackToNamedVolume()
            }
            print(
                "Info: Volume '\(source)' is shared by multiple services — backing it with host directory '\(hostPath)'.\n"
                + "      Note: Unix domain sockets do not work across virtiofs; services in this volume must communicate over TCP."
            )
            return ["-v", bindMountArg(source: hostPath)]
        }
        return fallbackToNamedVolume()
    }
    return args
}

/// Host directory backing a shared named volume. Kept under the container
/// application-support root so it lives alongside apple/container's own state
/// and is excluded from Time Machine by the same conventions.
public func sharedVolumeHostPath(projectName: String?, volumeName: String, fileManager: FileManager = .default) -> String {
    let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    let ns = "com.apple.container"
    let prefix = projectName.map { "\($0)_" } ?? ""
    return appSupport.appending(path: ns).appending(path: "shared-volumes").appending(path: "\(prefix)\(volumeName)").path
}

/// Determines which named volumes are shared by multiple services and must be
/// backed by a host directory (see `composeVolumeToRunArgs`).
///
/// Selection honours `CONTAINER_COMPOSE_SHARED_VOLUMES`:
///   - `never`  → no shared volumes (apple/container block volumes everywhere)
///   - `always` → every named volume is host-backed
///   - `auto` (default) → volumes referenced by two or more services
///
/// Returns volume names as written in the compose file (not project-prefixed).
public func computeSharedVolumes(
    serviceVolumes: [(serviceName: String, volumes: [String])],
    environmentVariables: [String: String] = [:],
    mode envMode: String? = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_SHARED_VOLUMES"]
) -> Set<String> {
    let mode = (envMode ?? "auto").lowercased()
    switch mode {
    case "never", "off", "false":
        return []
    case "always", "all", "true":
        return Set(serviceVolumes.flatMap { _, volumes in namedVolumeSources(volumes, environmentVariables: environmentVariables) })
    default:
        var refcounts: [String: Int] = [:]
        for (_, volumes) in serviceVolumes {
            for name in namedVolumeSources(volumes, environmentVariables: environmentVariables) {
                refcounts[name, default: 0] += 1
            }
        }
        return Set(refcounts.filter { $0.value >= 2 }.keys)
    }
}

/// Named-volume sources (no `/`, not relative) from raw `volumes:` entries,
/// after environment-variable resolution. Entries like `name:/path[:mode]`.
private func namedVolumeSources(_ volumes: [String], environmentVariables: [String: String]) -> [String] {
    volumes.compactMap { entry in
        let resolved = resolveVariable(entry, with: environmentVariables)
        guard let source = resolved.split(separator: ":", maxSplits: 2).first else { return nil }
        let name = String(source)
        if name.isEmpty || name.contains("/") || name.hasPrefix(".") { return nil }
        return name
    }
}

func composeNamedVolumeName(
    source: String,
    projectName: String?,
    volumeDefinition: Volume?
) -> String {
    if let explicitName = volumeDefinition?.name {
        return explicitName
    }

    if volumeDefinition?.external?.isExternal == true {
        return volumeDefinition?.external?.name ?? source
    }

    guard let projectName, !projectName.isEmpty else {
        return source
    }

    return "\(projectName)_\(source)"
}

extension String: @retroactive Error {}

/// A structure representing the result of a command-line process execution.
public struct CommandResult {
    /// The standard output captured from the process.
    public let stdout: String

    /// The standard error output captured from the process.
    public let stderr: String

    /// The exit code returned by the process upon termination.
    public let exitCode: Int32
}

extension NamedColor: @retroactive Codable {

}

extension Flags.Logging {
    /// Generates an array of flags that allow us to pass down Logging options
    func passThroughCommands() -> [String] {
        var flags: [String] = []
        
        if debug {
            flags.append("--debug")
        }
        
        return flags
    }
}
