// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GuanpanNextCore", platforms: [.iOS(.v17), .macOS(.v10_15)], products: [.library(name: "GuanpanNextCore", targets: ["GuanpanNextCore"])], targets: [
    .target(name: "GuanpanNextCore", path: "Sources", sources: ["NextCore.swift", "LocalRules.swift", "GlobalIndices.swift", "PortfolioSummary.swift", "InstrumentCatalog.swift"]),
    .testTarget(name: "GuanpanNextCoreTests", dependencies: ["GuanpanNextCore"], path: "Tests")
])
