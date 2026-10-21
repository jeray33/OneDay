// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OneDayMediaFilterTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MediaFilter",
            path: "OneDay/Services",
            exclude: [
                "ImageLoader.swift",
                "LocationResolver.swift",
                "MagazineLayoutEngine.swift",
                "PersonStickerExtractor.swift",
                "PhotoActionService.swift",
                "PhotoCaptionManager.swift",
                "PhotoLibraryService.swift",
                "PhotoMetadataService.swift",
                "PhotoSharpnessRanker.swift",
                "OtherImageClassificationService.swift",
                "RewindCandidateIndex.swift",
                "SharedAlbumCache.swift",
                "VisionSimilarity.swift"
            ],
            sources: ["MediaFilter.swift", "ImageClassificationStore.swift", "TunnelSelectionPlanner.swift", "DayMediaScope.swift", "DayMediaTabs.swift", "GridColumnPolicy.swift", "ContentScrollEdges.swift", "TitleSegmentationPolicy.swift", "LivePhotoPlaybackPolicy.swift", "PlaceNaming.swift", "OfflinePlaceIndex.swift"],
            linkerSettings: [.linkedFramework("Photos"), .linkedFramework("ImageIO")]
        ),
        .testTarget(
            name: "MediaFilterTests",
            dependencies: ["MediaFilter"],
            path: "Tests/MediaFilterTests",
            linkerSettings: [.linkedFramework("Photos")]
        )
    ]
)
