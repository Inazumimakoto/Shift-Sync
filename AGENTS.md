# Repository Guidelines

## Project Structure & Module Organization
- `main.go` + `go.mod`: Go CLI (`shift-sync`) that logs into ShiftWeb and syncs to iCloud.
- `shift_sync.py`, `shift_parser.py`, `login.py`, `shift.py`: Python prototypes and utilities.
- `shift_sync_rc/`: Rust prototype crate (sources in `shift_sync_rc/src`).
- `ShiftSync/`: Swift app with Xcode project (`ShiftSync.xcodeproj`), assets in `ShiftSync/ShiftSync/Media.xcassets`.
- `shift_page*.html`, `shifts.ics`: sample inputs/outputs for parser/debug work.

## Build, Test, and Development Commands
- Go CLI: `go run .` (from repo root) or `go build -o shift-sync` to build a local binary.
- Python CLI: `python shift_sync.py` for interactive sync; `python shift_parser.py` for parser-only checks.
- Rust prototype: `cargo run` (from `shift_sync_rc`).
- Swift app: `open ShiftSync/ShiftSync.xcodeproj` and build/run in Xcode.
- No unified build script; run commands from the relevant module directory.

## Coding Style & Naming Conventions
- Go: run `gofmt` on `*.go`; keep exported identifiers `CamelCase`.
- Python: 4-space indentation, `snake_case` for functions/vars, `UPPER_SNAKE_CASE` for constants.
- Swift: 4-space indentation, types in `PascalCase`, members in `camelCase`.
- Rust: use `rustfmt`; follow `snake_case` for functions/fields.
- No repo-specific lint configs are checked in; rely on language standard formatters.

## Testing Guidelines
- No automated tests are present today.
- If adding tests, keep them beside the code (`*_test.go`, `test_*.py`, Swift XCTest in a `ShiftSyncTests` target, or Rust `#[cfg(test)]`/`tests/`), and document how to run them.

## Commit & Pull Request Guidelines
- Git history is not available in this workspace; use concise, imperative commit subjects (optionally scoped like `go:`, `python:`, `ios:`).
- PRs should include a short summary, manual test notes, and screenshots for UI changes in the Swift app.

## Security & Configuration Tips
- Go/Python tools store config in `~/.shift_sync/config.toml` and credentials in the OS keychain; never commit secrets.
- If you touch `shift_parser.py`, avoid hard-coding real IDs/passwords—use local-only placeholders.
