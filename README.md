# Notty

Native iPad notebooks for handwriting, annotated PDFs, and lecture review.

Notty uses SwiftUI for navigation and PencilKit inside a UIKit editor. Paper is a continuous surface with subtle A4 boundaries for page-wise export. The primary device is the 12.9-inch iPad Pro, fifth generation.

## Current version

The first writing study contains a native PencilKit canvas, finger scrolling, pinch zoom, an Apple Pencil tool palette, and continuous paper that can grow from three to twelve A4 sections. Ink stays in memory for this feasibility study. Closing the app discards it. Durable notebooks, audio, PDF annotation, bookmarks, and export are subsequent delivery checkpoints.

This version targets iPadOS 17 or later. Compilation and geometry tests run on GitHub; input latency, guide alignment, rotation, and device performance require physical iPad testing before acceptance.

## Cloud checks

The Native checks workflow runs the dependency-free NottyCore geometry tests and builds unsigned iPad Simulator and iPad device applications. It does not install or distribute an application. Builds use a standard macOS runner with a fixed job timeout and cancel superseded checks on the same pull request.

No Apple Developer Program membership or signing secrets are needed for these checks. Personal iPad previews use local Xcode and a free Personal Team only when requested. TestFlight and external distribution are deferred.

## Source layout

- `Notty/App`: application entry point and configuration.
- `Notty/Features/Notebook`: native notebook editor.
- `Packages/NottyCore`: document geometry and its tests.
- `Notty.xcodeproj`: shared application project and scheme.
- `.github/workflows`: cloud validation.

The repository is the source of truth. Local application checkout and builds are reserved for requested previews.

## Product direction

The first usable release will add durable local notebooks, PDF annotation, built-in microphone recording, linked bookmarks, and export. Requested on-device AI and private AWS backup/restore follow. Multi-device synchronization and collaboration are outside the product scope.
