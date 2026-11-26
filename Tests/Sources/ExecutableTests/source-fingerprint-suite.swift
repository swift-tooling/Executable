import Executable
import Foundation
import Testing
import Version

extension ExecutableTestSuite {
    static let sourceFingerprintSuite = TestSuite(
        "source-fingerprint",
        title: "Per-package source fingerprints decide rebuilds in a repository of many packages",
        tags: ["executable", "version", "monorepo"]
    ) {
        Test("a change rebuilds the package it is in and the packages depending on it, nothing else") {
            let fixture = try MonorepoFixture()
            defer { fixture.remove() }

            let a0 = try await SourceFingerprint.compute(package: fixture.a)
            let b0 = try await SourceFingerprint.compute(package: fixture.b)
            try Expect.equal(a0.inputs.count, 2, "service A has itself and the shared library as inputs")
            try Expect.equal(a0.inputs.last?.lastPathComponent, "Shared", "the local path dependency is an input")

            try fixture.write("docs/notes.md", "outside every package")
            try Expect.equal(try await SourceFingerprint.compute(package: fixture.a), a0, "a file outside both packages changes neither")
            try Expect.equal(try await SourceFingerprint.compute(package: fixture.b), b0, "a file outside both packages changes neither")

            try fixture.write("services/A/Sources/A/main.swift", "print(\"a2\")\n")
            let a1 = try await SourceFingerprint.compute(package: fixture.a)
            try Expect.notEqual(a1.value, a0.value, "a change in A changes A")
            try Expect.equal(try await SourceFingerprint.compute(package: fixture.b), b0, "a change in A leaves B")

            try fixture.write("lib/Shared/Sources/Shared/shared.swift", "public let shared = 2\n")
            try Expect.notEqual(try await SourceFingerprint.compute(package: fixture.a).value, a1.value, "a change in the shared library changes A")
            try Expect.notEqual(try await SourceFingerprint.compute(package: fixture.b).value, b0.value, "a change in the shared library changes B")
        }

        Test("build output, hidden entries and nested packages are not source") {
            let fixture = try MonorepoFixture()
            defer { fixture.remove() }
            let before = try await SourceFingerprint.compute(package: fixture.a)

            try fixture.write("services/A/.build/release/A", "binary")
            try fixture.write("services/A/.DS_Store", "finder")
            try fixture.write("services/A/Tests/Package.swift", "// swift-tools-version: 5.9\n")
            try fixture.write("services/A/Tests/Sources/ATests/main.swift", "print(\"test\")\n")

            try Expect.equal(try await SourceFingerprint.compute(package: fixture.a), before, "only the package's own source counts")
        }

        Test("the same files give the same fingerprint at another path, as after an rsync") {
            let fixture = try MonorepoFixture()
            defer { fixture.remove() }
            let here = try await SourceFingerprint.compute(package: fixture.a)

            let copy = fixture.root.deletingLastPathComponent()
                .appendingPathComponent("fingerprint-copy-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: fixture.root, to: copy)
            try? FileManager.default.removeItem(at: copy.appendingPathComponent("services/A/.build"))

            let there = try await SourceFingerprint.compute(package: copy.appendingPathComponent("services/A", isDirectory: true))
            try Expect.equal(there.value, here.value, "the fingerprint depends on content and relative paths only")
        }

        Test("record adopts an existing build without compiling; a product never built stays behind") {
            let fixture = try MonorepoFixture()
            defer { fixture.remove() }
            let package = PackageConfiguration(buildArguments: ["--products", "A", "Other"])
            let records = BuildRecord.directory(project: fixture.a, mode: .release)

            try BuildRecord.write(
                products: ["A"],
                project: fixture.a,
                mode: .release,
                identity: BuildIdentity(version: nil, commit: "abc", dirty: false)
            )

            let before = try await PackageVersionStatus.inspect(at: fixture.a, configuration: package)
            try Expect.equal(before.behind, ["A", "Other"], "a build without a fingerprint and a product never built are both behind")
            try Expect.equal(before.reason("A"), "no source fingerprint recorded", "the reason names the missing fingerprint")
            try Expect.equal(before.reason("Other"), "never built", "the reason names the missing build")

            try Expect.equal(try before.recordSource(), ["A"], "only the product with a build is recorded")
            let after = try await PackageVersionStatus.inspect(at: fixture.a, configuration: package)
            try Expect.equal(after.behind, ["Other"], "the adopted build is current")
            try Expect.equal(
                try ProductMetadata.read(product: "A", in: records)?.commit,
                "abc",
                "recording keeps the rest of the metadata"
            )

            try fixture.write("services/A/Sources/A/main.swift", "print(\"changed\")\n")
            let changed = try await PackageVersionStatus.inspect(at: fixture.a, configuration: package)
            try Expect.contains(changed.reason("A") ?? "", "source changed", "a later change makes it behind again")
        }
    }
}

/// `services/A` and `services/B`, both depending on `lib/Shared` by path, in one directory.
private struct MonorepoFixture {
    let root: URL
    var a: URL { root.appendingPathComponent("services/A", isDirectory: true) }
    var b: URL { root.appendingPathComponent("services/B", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-fingerprint-\(UUID().uuidString)", isDirectory: true)

        try write("lib/Shared/Package.swift", Self.library("Shared"))
        try write("lib/Shared/Sources/Shared/shared.swift", "public let shared = 1\n")

        for name in ["A", "B"] {
            try write("services/\(name)/Package.swift", Self.service(name))
            try write("services/\(name)/Sources/\(name)/main.swift", "print(\"\(name.lowercased())\")\n")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    static func library(_ name: String) -> String {
        """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            products: [.library(name: "\(name)", targets: ["\(name)"])],
            targets: [.target(name: "\(name)")]
        )

        """
    }

    static func service(_ name: String) -> String {
        """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "\(name)",
            dependencies: [.package(path: "../../lib/Shared")],
            targets: [.executableTarget(name: "\(name)", dependencies: [.product(name: "Shared", package: "Shared")])]
        )

        """
    }
}
