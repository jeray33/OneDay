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
                "PhotoRotationService.swift",
                "PhotoContentVersion.swift",
                "PhotoCaptionManager.swift",
                "PhotoLibraryService.swift",
                "PhotoMetadataService.swift",
                "PhotoSharpnessRanker.swift",
                "OtherImageClassificationService.swift",
                "RewindCandidateIndex.swift",
                "SharedAlbumCache.swift",
                "VisionSimilarity.swift"
            ],
            sources: ["MediaFilter.swift", "ImageClassificationStore.swift", "TunnelSelectionPlanner.swift", "DayMediaScope.swift", "DayMediaTabs.swift", "DayScrubberPolicy.swift", "GridColumnPolicy.swift", "ContentScrollEdges.swift", "TitleSegmentationPolicy.swift", "LivePhotoPlaybackPolicy.swift", "PreviewInteractionPolicy.swift", "PhotoCornerGeometry.swift", "PhotoFrameGeometry.swift", "PhotoRotationPolicy.swift", "PhotoRotationRenderer.swift", "PhotoRotationAdjustment.swift", "PlaceNaming.swift", "OfflinePlaceIndex.swift", "TimeZoneIndex.swift", "CaptureClock.swift", "SharedAssetPolicy.swift"],
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
