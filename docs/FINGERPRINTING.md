# Audio fingerprinting

## Calculator delivery and setup

MacPicard does **not** bundle Chromaprint/FFmpeg. Install the official `fpcalc` executable for your Mac's architecture from [Chromaprint releases](https://github.com/acoustid/chromaprint/releases), or use a trusted package manager. Select its absolute path in Settings → Fingerprinting and use Check Tool. With an empty path, standard `/opt/homebrew/bin`, `/usr/local/bin`, and `/usr/bin` locations are checked. There is no automatic download, installation, or licensing acceptance. The app therefore remains dependent on this configured external executable; release delivery must communicate this requirement.

The delivery path was validated with the official macOS arm64 fpcalc 1.6.1 and generated FLAC audio. Calculator version is checked asynchronously. Generation uses Chromaprint algorithm 2 and up to the first 120 seconds, with full duration returned by fpcalc. Process work and pipe draining run off the UI actor. At most two files are processed concurrently; cancellation terminates running calculators (with forced termination if needed) and propagates to service reads. Runtime and output-size limits protect against stuck or misconfigured tools. Tool stderr is not copied into logs or errors because it may contain private paths.

## Identification and review

Use Metadata → Audio Fingerprints → Scan Selected, Scan Album, or Scan Entire Library. Entire Library ignores the visible album, filter, and selection. Right-click a track/album or use the toolbar overflow for scoped scanning. Settings stores the AcoustID **application key** in Keychain; it is needed for identification, but not local generation. The user's submission token is a separate credential and is not used for lookups.

Each result displays recoverable per-file errors or MusicBrainz release candidates. Fingerprint confidence, release confidence, and track confidence are distinct measures, not interchangeable. A wrong/missing title can still produce recording-ID evidence. Review Candidate opens the ordinary file-to-release comparison; its assignment menus and drag/drop paths allow corrections. Applying the review stages metadata with undo; Save Tags is still the explicit disk-write action. Scanning never automatically applies or saves tags, regardless of the 85% library-match threshold.

Candidate resolution is bounded: the top three AcoustID results, up to three recordings per result, and five release IDs per recording are considered, with up to eight distinct recording/release candidates per file. When AcoustID returns recording IDs without releases, MusicBrainz's release browse endpoint resolves them. Existing HTTPS, user-agent, rate-limit, cancellation, and cache policies remain in use. See [AcoustID API](https://acoustid.org/webservice) and [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API).

## Offline generation and cache

Generate Selected Offline or Generate Entire Collection Offline computes locally without reading service credentials or sending anything. Results can be reopened from Show Fingerprint Results. Entries are reused only when path, captured file identity, calculator version, and algorithm/options match. Modified audio and different calculator versions invalidate reuse. Malformed cache entries are cache misses. Local cache files contain fingerprints, not tokens; they are owner-readable/writable only. Raw fingerprints are not displayed or logged.

## Optional submission

1. Explicitly approve file-to-recording mappings in a MusicBrainz review. Imported IDs alone do not authorize submission; trusted mapping evidence is retained for the current workspace lifetime.
2. Generate fingerprints again after applying metadata, and after saving if disk identity changed. This captures a current metadata/file baseline; cached audio calculations can still be reused when disk identity has not changed.
3. Configure the separate user submission token in Keychain. Select Submit Verified Selected AcoustIDs or Submit Verified Library AcoustIDs.
4. Review filenames, durations, and recording IDs, then consent to this exact batch before Submit enables. Audio is not uploaded; AcoustID receives fingerprints, durations, recording IDs, and service credentials over HTTPS.

Submission revalidates both the reviewed tag baseline and disk identity. A persistent hashed intent journal is atomically written **before** each non-idempotent request. Accepted, interrupted, and uncertain attempts are not repeated on subsequent clicks or relaunch. The UI reports outcomes per file and can cancel remaining items. Network failure is conservative: verify the result with AcoustID before any manually coordinated recovery; deleting the journal blindly risks duplicate writes. Application tests exercise this with controlled transports; development validation does not make unsolicited live submissions.

The UI does not expose tokens in configuration exports, request URLs, journal entries, result rows, or error messages. Request bodies necessarily contain credentials for the service, so avoid logging transport bodies when debugging.
