# MacPicard updates

MacPicard checks the latest stable GitHub release once per day and also exposes a manual check in Settings → Updates. Checks are non-blocking and use HTTPS with a reload policy so stale metadata is not treated as current.

An installable release must include:

- a semantic-version tag such as `v1.2.3`;
- a macOS `.zip` containing `MacPicard.app`;
- a `.sha256` or `.sha256sum` asset containing the SHA-256 digest for that exact archive.

Before changing the running installation, MacPicard downloads the archive as a stream, hashes the bytes while downloading, verifies the checksum, extracts the bundle, checks the bundle identifier and version, and copies every regular file in 1 MiB chunks while publishing completed and total byte counts. The original bundle is not moved until the staged copy has completed. The replacement is then made as a bundle-level move; if the move fails, the original bundle is restored.

The update UI reports checking, downloading/verifying, staging, and installing separately. A missing checksum, invalid release URL, version mismatch, symbolic link in the archive, checksum mismatch, cancellation, or filesystem failure prevents installation and leaves the current app available.
