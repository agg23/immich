// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "TimelineAlgorithm",
  products: [
    .library(
      name: "TimelineAlgorithm",
      targets: ["TimelineAlgorithm"]
    ),
  ],
  targets: [
    .target(name: "TimelineAlgorithm"),
    .testTarget(
      name: "TimelineAlgorithmTests",
      dependencies: ["TimelineAlgorithm"]
    ),
  ]
)
