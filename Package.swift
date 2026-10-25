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
                "SimilarityFeatureService.swift",
                "SharedVideoDuplicateService.swift",
                "LocationResolver.swift",
                "DaySectionComposer.swift",
                "PhotoActionService.swift",
                "PhotoRotationService.swift",
                "PhotoContentVersion.swift",
                "PhotoCaptionManager.swift",
                "PhotoLibraryService.swift",
                "PhotoMetadataService.swift",
                "PhotoSharpnessRanker.swift",
                "OtherImageClassificationService.swift",
                "RewindCandidateIndex.swift",
                "SharedAlbumCache.swift"
            ],
            sources: ["VideoWiFiAccess.swift", "VerifiedVideoDigestStore.swift", "VideoContentFingerprint.swift", "SharedVideoDuplicatePolicy.swift", "SimilarPhotoGrouping.swift", "HistorySelectionPolicy.swift", "CoverSelectionPolicy.swift", "MediaFilter.swift", "ImageClassificationStore.swift", "TunnelSelectionPlanner.swift", "DayMediaScope.swift", "DayMediaTabs.swift", "DayScrubberPolicy.swift", "GridColumnPolicy.swift", "GenericCaptionFilter.swift", "WaterfallLayoutPolicy.swift", "DayGridScrollAnchor.swift", "DayPhotoGridSizing.swift", "ContentScrollEdges.swift", "TitleSegmentationPolicy.swift", "PlaceSectionCard.swift", "PageBackground.swift", "DayAppearanceOptions.swift", "RouteMapStyle.swift", "LivePhotoPlaybackPolicy.swift", "VideoPlaybackPolicy.swift", "PreviewInteractionPolicy.swift", "PreviewBackground.swift", "PhotoCornerGeometry.swift", "PhotoFrameGeometry.swift", "PhotoRotationPolicy.swift", "PhotoRotationRenderer.swift", "PhotoRotationAdjustment.swift", "PlaceNaming.swift", "OfflinePlaceIndex.swift", "TimeZoneIndex.swift", "CaptureClock.swift", "SharedAssetPolicy.swift", "SharedCopyMatch.swift", "CoverRelativeCaption.swift", "BackCoverFlipPlacement.swift", "BackCoverGradient.swift"],
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
