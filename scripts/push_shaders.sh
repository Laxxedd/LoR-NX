#!/bin/bash
# Copy the shader libraries of a build made with DM_COPY_SHADERS=NO (the NSP script's --shaders separate) to its iPhone app's Documents/msl.
# Usage: push_shaders.sh <device UDID> <bundle ID> <msl folder>
#    or: push_shaders.sh <device UDID> <bundle ID> <game>_build/xcode/Gen/resources.env      (the Xcode project's staged folder, Gen/shaders/msl)
# The folder is the one the build staged: <msl folder>/<b-chain | vk | gl>/ and msl.id (dm/tools/msl_id.py; the IPA build prints its path, the NSP script's work folder holds it at ipa/build/ios/pkg/shaders/msl).
# The app uses Documents/msl only when its msl.id is the one the app was built with and its files add up to the count and size in it: push again whenever the shaders changed (a new build with another
# translation chain, game version or profile table), and rerun after a failed transfer.  A copy cut off partway is refused by the same check.
# By hand (Finder, the Files app): copy the folder's contents so that Documents/msl/msl.id and Documents/msl/<b-chain>/ exist. Run it while the app (any build with that bundle ID) is installed.
set -eu
[ "$#" = 3 ] || { echo "usage: $0 <device UDID> <bundle ID> <msl folder | resources.env>" >&2; exit 1; }
dev=$1 id=$2 src=$3
case "$src" in *.env) src=$(dirname "$src")/shaders/msl;; esac
[ -f "$src/msl.id" ] || { echo "[RED] $src has no msl.id: it is not a folder staged by a DM_COPY_SHADERS=NO build" >&2; exit 1; }
echo "shaders: $(cat "$src/msl.id")"
xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer --domain-identifier "$id" --source "$src" --destination Documents/msl --remove-existing-content true -q
echo "shader libraries on the phone: $id"
