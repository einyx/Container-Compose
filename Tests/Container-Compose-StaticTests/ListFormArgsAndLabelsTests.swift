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

/// Coverage for the list shapes of `build.args` and `service.labels` allowed by
/// the Compose spec. Both previously failed to decode with
/// `DecodingError.typeMismatch: expected Mapping`.
@Suite("List Form Args and Labels")
struct ListFormArgsAndLabelsTests {

    // MARK: - build.args

    @Test("build.args list form decodes")
    func buildArgsListFormDecodes() throws {
        let yaml = """
        services:
          app:
            build:
              context: ./app
              args:
                - BASE_IMAGE=python:3.13-alpine3.23
                - VERSION
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let build = try #require(compose.services["app"]??.build)
        let args = try #require(build.args)
        #expect(args["BASE_IMAGE"] == "python:3.13-alpine3.23")
        #expect(args["VERSION"] == "")
    }

    @Test("build.args map form still decodes")
    func buildArgsMapFormDecodes() throws {
        let yaml = """
        services:
          app:
            build:
              context: ./app
              args:
                BASE_IMAGE: python:3.13-alpine3.23
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let args = try #require(compose.services["app"]??.build?.args)
        #expect(args["BASE_IMAGE"] == "python:3.13-alpine3.23")
    }

    // MARK: - labels

    @Test("labels list form decodes")
    func labelsListFormDecodes() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            labels:
              - com.example.foo=bar
              - com.example.bare
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let labels = try #require(compose.services["app"]??.labels)
        #expect(labels["com.example.foo"] == "bar")
        #expect(labels["com.example.bare"] == "")
    }

    @Test("labels map form still decodes")
    func labelsMapFormDecodes() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            labels:
              com.example.foo: bar
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let labels = try #require(compose.services["app"]??.labels)
        #expect(labels["com.example.foo"] == "bar")
    }
}
