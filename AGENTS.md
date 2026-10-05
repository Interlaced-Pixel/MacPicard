---
description: Production standards and workflow rules for MacPicard.
applyTo: '**'
---

# Organization Authority

The commanding user's organization is Interlaced Pixel. Projects owned or managed by Interlaced Pixel are authorized for the agent to use and alter within the scope of the user's instructions.

# Instruction Compliance

1. Complete every stated requirement before reporting success.
2. Do not commit or push unless the user explicitly requests it.
3. Before committing, pushing, or declaring completion, verify each requirement and report evidence.
4. A successful build proves compilation only; it does not prove runtime behavior, performance, or hardware compatibility.
5. Preserve unrelated user changes. Never reset, discard, or overwrite work without explicit authorization.
6. Read repository instructions before modifying code and inspect callers before changing public APIs.

# Operational Protocol

1. Audit the relevant files, targets, dependencies, and existing behavior.
2. State a concise implementation plan when the task spans multiple components.
3. Implement complete production code; do not leave stubs, placeholders, or speculative compatibility layers.
4. Validate the result with the narrowest relevant checks, then perform a broader build or test pass when practical.

# MacPicard Build and Test Policy

- MacPicard is a Swift 6 macOS 26 application using SwiftUI, native macOS APIs, SwiftPM targets, and an Xcode project.
- Use `xcodebuild` for native application builds and runs. The checked-in app scheme is `MacPicard App`.
- Use SwiftPM from the repository root for package builds and tests. Use `--scratch-path .build/shared` for commands that generate build state when practical.
- Run `swift test -Xswiftc -strict-concurrency=complete` for unit and integration validation when the task changes tested behavior or the user requests tests.
- Do not claim UI responsiveness, playback correctness, live API behavior, filesystem durability, or hardware support from compilation alone.
- Performance work must distinguish cold work, cache hits, main-actor work, I/O, and benchmark fixture limitations.
- Do not run live MusicBrainz, AcoustID, cover-art, trash, cross-volume, or hardware tests unless explicitly requested and the required opt-in environment is configured.
- Never commit `.build`, `DerivedData`, packaged applications, temporary downloads, logs, or generated build artifacts.

# Coding Standards

## General

- Prefer clear names, small cohesive types, and immutable state by default.
- Keep imports and dependencies explicit. Code must compile under complete strict-concurrency checking.
- Preserve existing safety guarantees around external file changes, symlinks, collisions, recovery, and user confirmation.
- Avoid explanatory comments when structure and names can express the behavior; document non-obvious durability, identity, concurrency, and compatibility contracts.

## Error Handling

- Propagate errors explicitly and provide actionable user-facing failures.
- Avoid force unwraps, unchecked assumptions, silent data loss, and broad catch-and-ignore behavior.
- Treat malformed, partial, corrupt, future-version, and externally modified data as distinct cases.

## Concurrency and State

- Keep UI state on the appropriate actor and move CPU-heavy or blocking work off the main actor.
- Propagate cancellation and gate worker results against current workspace, selection, and file revisions before staging changes.
- Bound caches, downloads, concurrent workers, and retained decoded data.
- Preserve ordering and durable-checkpoint semantics when replacing full snapshots with deltas or caches.

# Persistence and File Safety

- Imports must leave source files unchanged.
- Organization previews must remain read-only; execution must revalidate identities, destinations, symlink boundaries, and collisions.
- Existing destinations must not be overwritten without an explicit, tested policy.
- Session, operation, review, artwork, and update data must use atomic publication and preserve recoverability.
- Do not garbage-collect shared artwork or recovery data without reference analysis and explicit authorization.
- Validate archive and blob paths against traversal, symlink, size, checksum, and partial-write risks.

# Migration Rules

- Preserve supported schema compatibility and reject unknown future versions safely.
- Convert existing implementations in place when migrating; do not add stubs, bypasses, or silent fallback behavior.
- Search all callers before removing or changing APIs, schemas, files, or compatibility data.
- Remove obsolete compatibility paths only when the task explicitly requires a strict removal and all callers are migrated.

# Commit Standards

- Use focused, dependency-ordered commits for multi-phase work. Each commit should build cleanly when practical.
- Use conventional tagged messages with an explicit scope, for example:

  `perf(browser): cache incremental collection projections`

- The body should identify the affected targets, important behavior or compatibility changes, validation performed, and any known verification limits.
- Before committing or pushing, provide a requirement/status/evidence table in the task response.
- Push only the requested completed commits to the current branch's configured upstream.

# Workspace Cleanliness

- Keep scratch files in `/tmp` or the designated artifact directory, not in the repository.
- Remove temporary logs, generated reports, downloaded archives, and benchmark output after use unless the user asks to retain them.
- Do not generate Python scripts for repository changes; use existing scripts, native shell tools, or direct patches.
