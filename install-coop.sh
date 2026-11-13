#!/bin/sh
# One command for Savage Wind with the BotW co-op mod (this fork, branch coop-mods), macOS (Apple silicon):
#
#   ./install-coop.sh "/path/to/base game.nsp" "/path/to/1.9.0 update.nsp"
#
# Downloads the newest co-op mod release from https://github.com/Jaiden56YT/botw-coop and runs its setup: it reads
# your own dump into extracted/ (about 15 GB), builds the mod's game files, puts the mod in and builds Savage Wind
# with it. The build tools (Homebrew packages, tools/venv) must be there already: docs/code-mods.md.
# Run it again to update (the dump files can be left out once extracted/ is there).
set -e
cd "$(dirname "$0")"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PKG=macos-arm64 ;;
  Darwin-*) PKG=macos-intel ;;
  *) PKG=linux-x64 ;;
esac
echo "== Downloading the newest co-op mod release ($PKG)"
rm -rf coop/package
mkdir -p coop/package
curl -fL -o coop/package/mod.zip "https://github.com/Jaiden56YT/botw-coop/releases/latest/download/botw-coop-$PKG.zip"
(cd coop/package && unzip -q mod.zip)
cat coop/package/botw-coop/VERSION
echo "== Setting up the co-op mod"
coop/package/botw-coop/setup.sh "$@" --no-ryujinx --recomp "$PWD"
echo
echo "Start the game with ./play-coop.sh in this folder."
