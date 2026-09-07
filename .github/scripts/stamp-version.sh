#!/usr/bin/env bash
# Stamp the release version into flugo.yaml (app.version) and the Flutter
# pubspec.yaml (version:). flugo has no version command, and `flugo build` does
# not restamp pubspec, so CI must do it. Uses perl (present on Linux + macOS
# runners) to avoid the GNU-vs-BSD `sed -i` incompatibility.
#
# Usage: stamp-version.sh <version-without-leading-v>   e.g. 0.1.0
set -euo pipefail

VER="${1:?usage: stamp-version.sh <version>}"
BUILD="${GITHUB_RUN_NUMBER:-1}"
export VER BUILD

# flugo.yaml: app.version is the only indented `version:` key (flugo_version,
# runtime_version, minimum_version are different keys, so ^\s+version: is unique).
perl -i -pe 's/^(\s+)version:.*/$1 . "version: " . $ENV{VER}/e' flugo.yaml

# pubspec.yaml: the single top-level `version:`; append a monotonic build number
# so Android gets a fresh versionCode per run.
perl -i -pe 's/^version:.*/"version: " . $ENV{VER} . "+" . $ENV{BUILD}/e' frontend/pubspec.yaml

echo "Stamped version ${VER}+${BUILD}:"
grep -nE '^[[:space:]]+version:' flugo.yaml || true
grep -nE '^version:' frontend/pubspec.yaml || true
