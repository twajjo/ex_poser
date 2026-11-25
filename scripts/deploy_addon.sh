#!/usr/bin/env bash
# Copy the ExPoser Bridge add-on into Poser's addons folder.
# Override the destination with POSER_ADDONS=/mnt/.../Runtime/Python/addons
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/python/ex_poser_bridge/"
addons="${POSER_ADDONS:-/mnt/d/Program Files/Poser Software/Poser 14/Runtime/Python/addons}"

[[ -d "$addons" ]] || { echo "addons folder not found: $addons" >&2; exit 1; }

rsync -a --delete --exclude __pycache__ "$src" "$addons/ex_poser_bridge/"
cp "$root/priv/poser_api.json" "$addons/ex_poser_bridge/poser_api.json"  # strict-mode allowlist
# Build stamp the add-on prints when it loads: the working copy's jj commit id
# (it changes with every edit) and the deploy time.
commit="$(jj -R "$root" log -r @ --no-graph -T 'commit_id.short(8)' 2>/dev/null || echo unknown)"
stamp="$commit $(date '+%Y-%m-%d %H:%M')"
echo "$stamp" > "$addons/ex_poser_bridge/build.txt"
echo "deployed build $stamp to $addons/ex_poser_bridge/"
echo "restart Poser to load it (add-ons are imported once, at startup)"
