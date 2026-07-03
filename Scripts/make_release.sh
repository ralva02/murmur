#!/bin/bash
# Builds a distributable zip of Murmur for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make_release.sh <version>   e.g. make_release.sh 0.2.0}"

MURMUR_VERSION="$VERSION" bash Scripts/make_app.sh

ZIP="build/Murmur-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves the code signature; plain zip does not.
ditto -c -k --keepParent build/Murmur.app "$ZIP"

echo
codesign --verify --deep --strict build/Murmur.app && echo "signature: OK"
shasum -a 256 "$ZIP"
echo
echo "Publish with:"
echo "  gh release create v$VERSION $ZIP --title \"Murmur $VERSION\" --notes \"<what changed>\""
