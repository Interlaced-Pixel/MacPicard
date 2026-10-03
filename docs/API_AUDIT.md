# API integration audit — 2026-10-03

Scope: every remote request path in MusicBrainz, Cover Art Archive, and the AcoustID client module, including their UI consumers.

| Service | Contract | App behavior |
| --- | --- | --- |
| MusicBrainz | GET `/ws/2/release?query=…` and `/ws/2/release/{UUID}` | JSON format, escaped literal searches, release-only includes separated by spaces, recordings included when requesting ISRCs. |
| Cover Art Archive | GET `/release/{UUID}` and `/release-group/{UUID}`, then artwork URL | JSON metadata and image-specific Accept headers; validated image bytes; known archive HTTP links upgraded to HTTPS. |
| AcoustID | POST `/v2/lookup` and `/v2/submit` | Form-encoded UTF-8 bodies, space-separated metadata, JSON format, indexed submission fields; keys and fingerprints stay out of URLs. |

All client instances share a per-host request gate. The default interval is one second; suspended concurrent callers recheck the gate. Retry-After seconds and HTTP dates defer subsequent calls. Read operations retry temporary failures, not invalid requests or decoding errors. Submissions are never automatically repeated, since an uncertain write could already have succeeded. Cancellation is propagated without retries.

Metadata endpoints enforce HTTPS and same-origin redirects. Cover-art redirects preserve standard TLS/ATS verification. Cached MusicBrainz responses are validated before storage and partitioned by authorization; invalid cached images are discarded individually. The default User-Agent includes an application version and contact URL, with automatic upgrade of the previous bare default.

The UI clears stale failures when loading another match. Applying a release matches each selected song rather than assigning from selection order, and keeps recording IDs separate from release-track IDs. Both identifiers round-trip through the supported audio formats.

## Verification

Deterministic tests cover request parameters, escaping, headers, secure redirects, concurrency, cancellation, cache validity, permanent errors, submission consent, and non-duplicating writes. Opt-in live tests exercise Lukas Graham release search, full release details, release-group artwork lookup, and the 1200-pixel cover download:

```sh
MACPICARD_LIVE_API_TESTS=1 MACPICARD_LIVE_COVER_ART_TEST=1 swift test
```

Final run: **89 tests, zero failures, zero skips**, including all three live checks and MusicBrainz identifier read/write verification for MP3, FLAC, M4A/AAC, Ogg Vorbis, Opus, and WAV. The archive's release-group redirect intermittently returned HTTP 500 during the audit; bounded read retries now cover this status and the final live lookup passed. No client can guarantee upstream availability.

AcoustID is contract-tested with recorded-response fixtures. No live fingerprint submissions were sent: those would mutate its database and require registered application/user keys and explicit consent. No user audio files need to be saved to verify search and release loading.

The optimized release bundle passed property-list and code-signature validation (local ad-hoc signature, not notarized). Native on-screen verification was blocked by the locked Mac; the real application-model match/loading/apply path is regression-tested without writing user audio. The existing running app and pending edits were left intact, with the updated build delivered alongside it as `MacPicard-API-Fix.app`.

## Primary references

- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [MusicBrainz search](https://musicbrainz.org/doc/MusicBrainz_API/Search)
- [MusicBrainz rate limits and User-Agent](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)
- [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API)
- [AcoustID web service](https://acoustid.org/webservice)
- [Picard identifier tag mappings](https://picard-docs.musicbrainz.org/en/latest/appendices/tag_mapping.html)
