# Notty

Native iPad notebooks for handwriting, annotated PDFs, and lecture review.

Notty uses SwiftUI for navigation and PencilKit inside a UIKit editor. Paper is one continuous surface with subtle A4 boundaries for future page-wise export. The primary device is the 12.9-inch iPad Pro, fifth generation, running iPadOS 27.0.1 with Apple Pencil.

## Current version

The writing study contains native PencilKit input, finger scrolling, pinch zoom, the drawing palette, and continuous paper that can grow from three to twelve A4 sections. It saves and reopens one notebook. Save failures distinguish content limits, changed revisions, damaged or unsupported files, and unavailable storage. Pending edits retain their original order and timestamps.

Writing pauses while saves catch up or a failure needs attention. Brief capacity pauses keep the drawing palette, focus and viewport stable; failure and recovery screens suspend palette access. Reading, scrolling and zoom remain available. Errors explain the available actions; retry is offered when the underlying condition can recover.

## Recovery copies

After a save failure, preserve a recovery copy before returning to the committed notebook. Recovery copies retain every pending completed drawing, its original stroke identities, edit timestamps, title and paper extent. A copy must cover the current pending edits before returning to the saved version; newer edits invalidate that permission. If preservation or reopening fails, current pending work remains unsaved and retained.

Recovery copies are stored locally in a separate directory and can be opened to inspect their ordered drawing states even when the notebook cannot open. Listing reports unavailable copies alongside healthy copies; damaged originals are retained. Reopening saved work revalidates the preserved copy against the exact pending edit states before releasing them. Recovery publication is separate from a normal notebook save. Copies remain retained; this study does not provide deletion or general archive export.

Recovery bounds are 32 edits per copy, 20,000 stroke identities per drawing, 128 MiB per native drawing archive, and 512 MiB total drawing data per copy. These emergency bounds are independent of normal notebook limits. If recovery also exceeds its limits or storage is unavailable, the interface reports the failure without discarding current work. Native archive size is checked after PencilKit serialization; these file bounds do not establish peak memory usage.

## Storage and history

Individual stroke archives are shared across immutable revisions. Native stroke IDs, ordered asset references, original edit timestamps, and prior saved states are retained for future recording links and replay. Replay itself is not available.

Notebook publication verifies hashes and schema versions, rejects stale revisions, and updates its head after assets and revision metadata are written. First creation publishes a complete notebook from a private transaction. Missing publication metadata in an existing notebook requires recovery and does not create a blank notebook. Failed writes clean up their stages; recovery maintenance removes validated internal temporary transactions under the writer lock. Notebook-stage cleanup follows successful content validation and skips temporary-looking directories and links without touching their targets. Cleanup errors retain the note for another maintenance attempt. Once maintenance succeeds, consecutive successful saves avoid directory scans; cleanup failures remain eligible for retry even after a successful publication.

Normal bounds are 10,000 strokes, 10 MiB per stroke asset, 64 MiB aggregate current stroke data, and 2 MiB metadata. This increment requires iPadOS 27 for native stable PencilKit stroke identities. Twelve sections and the validation bounds are study limits.

Full stroke-reference manifests are still retained per edit, and normal saves still verify current committed assets. Compact history and incremental save costs are subsequent remediation checkpoints before library expansion. This study is not a daily-use release.

File synchronization and atomic publication target process-crash recovery. Physical interruption, file protection, latency, thermal behavior, and abrupt power-loss durability remain acceptance checks.

Library organization, recording, PDF annotation, bookmarks, and export remain subsequent checkpoints.

## Cloud checks

The suite contains 84 core tests, including 16 native archive cases, and 24 hosted iPad tests. The Native checks workflow runs geometry, persistence/fault, recovery, and native PencilKit archive tests on macOS 27. It compiles unsigned iPad Simulator and iPad device applications using Xcode 27 and runs hosted notebook session, canvas and lifecycle tests in an iPadOS 27 Simulator.

The standard GitHub image is currently a preview; the workflow verifies actual host, toolchain and SDK versions and selects an available iPadOS 27.0 tablet simulator. A single job has a fifteen-minute limit and cancels superseded checks on the same pull request.

No Apple membership or signing credentials are needed for these cloud checks. Personal iPad previews use local Xcode and a free Personal Team when requested; TestFlight and external distribution remain deferred.

Cloud tests establish only their declared cases. They do not establish physical Pencil latency, live-canvas identity behavior, device suspension or power-loss recovery.

## Source layout

- `Notty/App`: application entry point and configuration.
- `Notty/Features/Notebook`: native editor, save coordination and recovery inspection.
- `NottyTests`: hosted iPad notebook and lifecycle tests.
- `Packages/NottyCore`: paper geometry, versioned storage, recovery models/store, stroke codec, and tests.
- `Notty.xcodeproj`: shared application project and scheme.
- `.github/workflows`: cloud validation.

The repository is the source of truth. Local application checkout and builds are reserved for explicitly requested previews.

## Product direction

The first usable release will add an organized local library, PDF annotation, built-in microphone recording, linked bookmarks, and PDF/archive export. Requested on-device AI and private AWS backup/restore follow. Multi-device synchronization and collaboration are outside the product scope.
