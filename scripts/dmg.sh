#!/bin/bash
# Packages build/Pluck.app into build/Pluck.dmg with a drag-to-Applications link.
# Run scripts/bundle.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
staging=$(mktemp -d)
cp -R build/Pluck.app "$staging/"
ln -s /Applications "$staging/Applications"
rm -f build/Pluck.dmg
hdiutil create -volname Pluck -srcfolder "$staging" -fs HFS+ -format UDZO -quiet build/Pluck.dmg
rm -rf "$staging"
echo "Built build/Pluck.dmg"
