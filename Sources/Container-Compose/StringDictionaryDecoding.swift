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
//  StringDictionaryDecoding.swift
//  container-compose-app
//

import Foundation

extension KeyedDecodingContainer {
    /// Decodes an optional `[String: String]` value that the Compose spec allows
    /// in two forms: a mapping (`KEY: value`) or a list of strings
    /// (`- KEY=value`). Entries in the list form without a separator decode to
    /// an empty string (Docker treats a bare `- KEY` label/arg as empty).
    ///
    /// Usage: `try container.decodeIfPresent([String: String].self, forKey: .labels, orListWithSeparator: "=")`
    public func decodeIfPresent(
        _ type: [String: String].Type,
        forKey key: KeyedDecodingContainer<K>.Key,
        orListWithSeparator separator: Character
    ) throws -> [String: String]? {
        if let map = try? decodeIfPresent([String: String].self, forKey: key), map != nil {
            return map
        }
        guard case .some(let list) = try? decodeIfPresent([String].self, forKey: key) else {
            return nil
        }
        var result: [String: String] = [:]
        for entry in list {
            if let idx = entry.firstIndex(of: separator) {
                result[String(entry[..<idx])] = String(entry[entry.index(after: idx)...])
            } else {
                result[entry] = ""
            }
        }
        return result
    }
}
