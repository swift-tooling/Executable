import Foundation
import Version

/// Whether a project's products are current. Each product's metadata (in the deploy directory
/// for deployed products, in `.build/<mode>/` for local ones) records the source fingerprint it
/// was built from; a product is current while that matches the package's fingerprint now.
public struct PackageVersionStatus: Sendable {
    public struct Product: Sendable, Equatable {
        public let product: String
        public let metadata: ProductMetadata?
        /// Where the metadata lives (deploy directory or build record directory).
        public let root: URL
    }

    public let release: ObjectVersion?
    public let head: BuildIdentity?
    /// The package's source fingerprint now; nil when it could not be computed.
    public let source: SourceFingerprint?
    public let deployed: [Product]
    /// Products built without deploying (`localProducts`), with their build records.
    public let built: [Product]

    /// A product is behind when it has no metadata, or its recorded source fingerprint differs
    /// from the current one (metadata from before fingerprints has none, so it is behind once).
    /// A deployed product is also behind while its version is below the newest release tag.
    ///
    /// When the fingerprint cannot be computed, the recorded commit is compared with HEAD instead.
    public var behind: [String] {
        (deployed.filter { isBehind($0, releases: true) } + built.filter { isBehind($0, releases: false) })
            .map(\.product)
    }

    /// Why `product` is behind, for `sbm version` and `sbm rr`; nil when it is current.
    public func reason(
        _ product: String
    ) -> String? {
        guard let entry = (deployed + built).first(where: { $0.product == product }),
              isBehind(entry, releases: deployed.contains(entry))
        else {
            return nil
        }

        guard let metadata = entry.metadata else {
            return "never built"
        }

        if let source {
            guard let recorded = metadata.source else {
                return "no source fingerprint recorded"
            }
            if recorded != source.value {
                return "source changed (\(Self.short(recorded)) → \(Self.short(source.value)))"
            }
        }

        if let release, deployed.contains(entry) {
            return "deployed \(metadata.version.map(ReleaseTag.name(for:)) ?? "untagged") below release \(ReleaseTag.name(for: release))"
        }

        return "built from another commit"
    }

    private func isBehind(
        _ entry: Product,
        releases: Bool
    ) -> Bool {
        guard let metadata = entry.metadata else {
            return true
        }

        if let source {
            if metadata.source != source.value {
                return true
            }
        } else {
            guard let commit = metadata.commit else {
                return true
            }
            if (!releases || release == nil), commit != head?.commit {
                return true
            }
        }

        if releases, let release {
            guard let built = metadata.version else {
                return true
            }
            return built < release
        }

        return false
    }

    static func short(
        _ fingerprint: String
    ) -> String {
        String(fingerprint.split(separator: ":").last?.prefix(12) ?? "")
    }

    public static func inspect(
        at project: URL,
        configuration: PackageConfiguration,
        deployedTo root: URL = Build.defaultDeploymentDirectory
    ) async throws -> PackageVersionStatus {
        let head = await BuildIdentity.current(at: project)
        let source = try? await SourceFingerprint.compute(package: project)
        let deployed = try (configuration.deployProducts ?? []).map { product in
            Product(product: product, metadata: try ProductMetadata.read(product: product, in: root), root: root)
        }
        let records = BuildRecord.directory(project: project, mode: (configuration.mode ?? .release).config)
        let built = try configuration.localProducts.map { product in
            Product(product: product, metadata: try ProductMetadata.read(product: product, in: records), root: records)
        }
        return .init(release: head?.version, head: head, source: source, deployed: deployed, built: built)
    }

    /// Records the current fingerprint as built for every product that has metadata, without
    /// building (`sbm rr --record`). Returns the products updated.
    @discardableResult
    public func recordSource() throws -> [String] {
        guard let source else {
            return []
        }

        var recorded: [String] = []

        for entry in deployed + built where entry.metadata != nil {
            if try BuildRecord.recordSource(source.value, product: entry.product, in: entry.root) {
                recorded.append(entry.product)
            }
        }

        return recorded
    }
}
