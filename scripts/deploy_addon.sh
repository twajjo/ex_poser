#!/usr/bin/env bash
# Copy the Poser Bridge add-on into Poser's addons folder.
# Override the destination with POSER_ADDONS=/mnt/.../Runtime/Python/addons
set -euo pipefail

src="$(cd "$(dirname "$0")/.." && pwd)/python/poser_bridge/"
addons="${POSER_ADDONS:-/mnt/d/Program Files/Poser Software/Poser 14/Runtime/Python/addons}"

[[ -d "$addons" ]] || { echo "addons folder not found: $addons" >&2; exit 1; }

rsync -a --delete --exclude __pycache__ "$src" "$addons/poser_bridge/"
echo "deployed to $addons/poser_bridge/"
echo "restart Poser to load it (add-ons are imported once, at startup)"
