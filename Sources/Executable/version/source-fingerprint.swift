import Foundation
import IO
import Readers
import Version
import Writers

/// What a package is built from: a hash over the files of the package directory and of its
/// local path dependencies (recursively). Recorded as `Source=` in the product metadata by
/// every successful build, and compared by `sbm rr`: a product is behind when the current
/// fingerprint differs from the one recorded beside its binary.
///
/// It reads only the files on disk, so it means the same after an rsync, a pull or a local
/// edit, and in a repository with many packages each package has its own. Same files, same
/// fingerprint.
public struct SourceFingerprint: Sendable, Equatable, CustomStringConvertible {
    /// `fnv1a64-lines:<hex>`.
    public let value: String
    /// The package directory first, then its local path dependencies.
    public let inputs: [URL]
    public let fileCount: Int

    public var description: String { value }

    /// Directories never part of a package's source.
    static let excludedDirectories: Set<String> = [
        ".build",
        ".index-build",
        ".swiftpm",
        ".git",
    ]

    public static func compute(
        package: URL
    ) async throws -> SourceFingerprint {
        // Resolved, so a dependency reported through a symlinked prefix (/var → /private/var)
        // still gets a short relative label.
        let package = package.resolvingSymlinksInPath().standardizedFileURL
        let inputs = try await Self.inputs(of: package)

        var lines: [String] = []

        for input in inputs {
            let label = relativePath(from: package, to: input)
            try collect(
                directory: input,
                root: input,
                label: label,
                into: &lines
            )
        }

        lines.sort()

        let combined = ContentFingerprint.fingerprint(for: lines)
            ?? ContentFingerprint.fingerprint(for: "")

        return .init(
            value: combined.description,
            inputs: inputs,
            fileCount: lines.count
        )
    }

    // MARK: - Inputs

    /// The package and its local path dependencies, recursively, each once.
    static func inputs(
        of package: URL
    ) async throws -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        var pending = [package]

        while let next = pending.first {
            pending.removeFirst()

            guard seen.insert(next.path).inserted else {
                continue
            }

            result.append(next)
            pending += try await localDependencies(of: next)
        }

        return result
    }

    /// Local path dependencies from `swift package dump-package`, cached in
    /// `.build/sbm/local-dependencies` against the fingerprint of `Package.swift`, so the
    /// manifest is evaluated again only when it changes.
    static func localDependencies(
        of package: URL
    ) async throws -> [URL] {
        let manifest = package.appendingPathComponent("Package.swift")
        let manifestRead = try DataFileReader(manifest).read(
            options: .init(missingFilePolicy: .returnEmpty)
        )

        guard manifestRead.existed else {
            return []
        }

        let manifestFingerprint = ContentFingerprint.fingerprint(for: manifestRead.data).description
        let cache = package
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("sbm", isDirectory: true)
            .appendingPathComponent("local-dependencies")

        let cached = try TextFileReader(cache).read(
            options: .init(missingFilePolicy: .returnEmpty)
        )

        if cached.existed {
            var lines = cached.text.split(whereSeparator: \.isNewline).map(String.init)

            if lines.first == "Manifest=\(manifestFingerprint)" {
                lines.removeFirst()
                return lines.compactMap { line in
                    guard line.hasPrefix("Path=") else { return nil }
                    return URL(fileURLWithPath: String(line.dropFirst(5)), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
                }
            }
        }

        let dump = try await SwiftPackageDumpInvocation.data(in: package)
        let paths = try parseLocalDependencies(dump, package: package)

        let content = (["Manifest=\(manifestFingerprint)"] + paths.map { "Path=\($0.path)" })
            .joined(separator: "\n")

        _ = try? FileWriter(cache).write(content, options: .overwriteWithoutBackup)

        return paths
    }

    /// `dependencies[].fileSystem[].path` of a dump-package document, resolved against the package.
    static func parseLocalDependencies(
        _ dump: Data,
        package: URL
    ) throws -> [URL] {
        guard let root = try JSONSerialization.jsonObject(with: dump) as? [String: Any],
              let dependencies = root["dependencies"] as? [[String: Any]]
        else {
            return []
        }

        return dependencies.compactMap { dependency in
            guard let fileSystem = dependency["fileSystem"] as? [[String: Any]],
                  let path = fileSystem.first?["path"] as? String
            else {
                return nil
            }

            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path, isDirectory: true)
                : package.appendingPathComponent(path, isDirectory: true)

            return url.resolvingSymlinksInPath().standardizedFileURL
        }
    }

    // MARK: - Files

    /// One line per file: `<input label>/<path in input>\t<content fingerprint>`. Hidden
    /// entries, build output and nested packages (Tests/, Benchmarks/, anything with its own
    /// `Package.swift`) are skipped. A symlinked directory is not followed.
    static func collect(
        directory: URL,
        root: URL,
        label: String,
        into lines: inout [String]
    ) throws {
        let entries = try FileSystem.default.directory.entries(directory)

        for entry in entries {
            let name = entry.url.lastPathComponent

            guard !name.hasPrefix("."), !excludedDirectories.contains(name) else {
                continue
            }

            let relative = label + "/" + relativePath(from: root, to: entry.url)

            switch entry.kind {
            case .directory:
                let nestedManifest = entry.url.appendingPathComponent("Package.swift")
                if FileSystem.default.exists(nestedManifest) {
                    continue
                }
                try collect(directory: entry.url, root: root, label: label, into: &lines)

            case .file, .symlink:
                // A symlink is read through (what the compiler sees); a dangling one hashes as empty.
                let hash: String
                if let read = try? DataFileReader(entry.url).read(options: .init(missingFilePolicy: .returnEmpty)) {
                    hash = read.existed ? ContentFingerprint.fingerprint(for: read.data).value : "missing"
                } else if entry.kind == .symlink {
                    hash = "link"
                } else {
                    throw SourceFingerprintError.unreadable(entry.url)
                }
                lines.append("\(relative)\t\(hash)")

            case .other:
                continue
            }
        }
    }

    /// `to` relative to `from` (`../../lib/Domains`), `.` when they are the same.
    static func relativePath(
        from base: URL,
        to target: URL
    ) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents

        var common = 0
        while common < baseComponents.count,
              common < targetComponents.count,
              baseComponents[common] == targetComponents[common] {
            common += 1
        }

        let up = Array(repeating: "..", count: baseComponents.count - common)
        let down = Array(targetComponents[common...])
        let components = up + down

        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}

public enum SourceFingerprintError: Error, LocalizedError, Sendable {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Cannot read \(url.path) for the source fingerprint"
        }
    }
}

extension ProductMetadata {
    /// The source fingerprint the product was built from (`Source=`), nil before fingerprints.
    public var source: String? {
        values["Source"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension BuildRecord {
    /// Writes `source` as the recorded fingerprint into an existing metadata file without
    /// building (`sbm rr --record`). Returns false when there is no metadata to update: a
    /// product never built stays behind and builds normally.
    @discardableResult
    public static func recordSource(
        _ source: String,
        product: String,
        in root: URL
    ) throws -> Bool {
        let file = root.appendingPathComponent("\(product).metadata")
        let current = try TextFileReader(file).read(options: .init(missingFilePolicy: .returnEmpty))

        guard current.existed else {
            return false
        }

        var lines = current.text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasPrefix("Source=") }

        lines.append("Source=\(source)")

        try FileWriter(file).write(lines.joined(separator: "\n"), options: .overwriteWithoutBackup)
        return true
    }
}
