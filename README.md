# Notty

Native iPad notebooks for handwriting, annotated PDFs, and lecture review.

Notty uses SwiftUI for navigation and PencilKit inside a UIKit editor. Paper is one continuous surface with subtle A4 boundaries for future page-wise export. The primary device is the 12.9-inch iPad Pro, fifth generation, running iPadOS 27.0.1 with Apple Pencil.

## Current version

The writing study contains native PencilKit input, finger scrolling, pinch zoom, the drawing palette, and continuous paper that can grow from three to twelve A4 sections. It saves and reopens one notebook with explicit saving, saved, and failure states. Failed loads preserve the stored data and keep the editor closed; failed saves retain pending changes for retry.

Individual stroke archives are shared across immutable revisions. Native stroke IDs, ordered asset references, original edit timestamps, and prior saved states are retained for future recording links and replay. Replay itself is not available.

This increment requires iPadOS 27. Native stable stroke identity is part of the iPadOS 27 PencilKit API. Twelve sections and storage validation limits are feasibility bounds, rather than final notebook capacity.

Library organization, recording, PDF annotation, bookmarks, and export remain subsequent checkpoints.

## Storage and recovery

The notebook repository serializes writes outside the drawing interface, rejects stale revisions, verifies hashes and schema versions, and publishes a new head only after stroke assets and revision metadata are written. Unpublished remnants do not replace the last committed note. Corrupt or unsupported stored content produces an error rather than an empty notebook.

The current bounds are 10,000 strokes, 10 MiB per stroke asset, 64 MiB aggregate current stroke data, and 2 MiB metadata. Pending edits remain dirty until a save receipt arrives. Device interruption, file protection, performance, and abrupt power-loss durability require physical testing before acceptance. This study is not yet a daily-use release.

## Cloud checks

The Native checks workflow runs geometry, persistence/fault, and native PencilKit archive tests on macOS 27. It also compiles unsigned iPad Simulator and iPad device applications using Xcode 27. The standard GitHub image is currently a preview; the workflow verifies actual host, toolchain, and SDK versions before testing.

A single job has a fifteen-minute limit and cancels superseded checks on the same pull request. No Apple membership or signing credentials are needed for cloud checks. These builds do not install or distribute an application. Personal iPad previews use local Xcode and a free Personal Team only when requested; TestFlight and external distribution remain deferred.

macOS archive tests do not establish iPad runtime behavior, Pencil latency, or device recovery guarantees.

## Source layout

- `Notty/App`: application entry point and configuration.
- `Notty/Features/Notebook`: native editor and save coordination.
- `Packages/NottyCore`: paper geometry, versioned storage, stroke codec, and tests.
- `Notty.xcodeproj`: shared application project and scheme.
- `.github/workflows`: cloud validation.

The repository is the source of truth. Local application checkout and builds are reserved for explicitly requested previews.

## Product direction

The first usable release will add an organized local library, PDF annotation, built-in microphone recording, linked bookmarks, and PDF/archive export. Requested on-device AI and private AWS backup/restore follow. Multi-device synchronization and collaboration are outside the product scope.
