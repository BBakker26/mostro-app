#!/usr/bin/env bash
# Set the app version everywhere it is declared, ahead of tagging a release.
#
# The release workflow refuses a tag whose version the tagged source does not already
# carry (docs/RELEASING.md): the About screen shows CARGO_PKG_VERSION from rust/Cargo.toml,
# and local builds read pubspec.yaml. Commit the result through a PR, then tag its merge.
#
# Usage:
#   ./scripts/bump-version.sh 2.0.1
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version="${1:-}"
if ! [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "usage: $0 MAJOR.MINOR.PATCH   (got '${version}')" >&2
  exit 64
fi
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

# Same Android versionCode scheme as .github/workflows/release.yml.
if [ "$minor" -gt 99 ] || [ "$patch" -gt 99 ]; then
  echo "MINOR and PATCH must stay below 100 (versionCode scheme, docs/RELEASING.md)." >&2
  exit 64
fi
build_number=$((major * 10000 + minor * 100 + patch))

# perl, not `sed -i`: the in-place flag and the `0,/re/` address differ between GNU and BSD
# (macOS) sed, and maintainers release from both.
perl -pi -e "s/^version: .*/version: ${version}+${build_number}/" pubspec.yaml
# Only the [package] version: the first `version =` line of the manifest.
perl -pi -e "\$done ||= s/^version = \".*\"/version = \"${version}\"/" rust/Cargo.toml
# The crate's own entry in the lockfile, so `cargo build --locked` (CI) still passes.
perl -0pi -e "s/(name = \"rust\"\nversion = \")[^\"]*/\${1}${version}/" rust/Cargo.lock

echo "Version set to ${version} (build ${build_number}):"
git --no-pager diff --stat -- pubspec.yaml rust/Cargo.toml rust/Cargo.lock
