#!/bin/sh
# Downloads the Depth Range mask's monocular depth model into Models/ (gitignored; the app builds and runs without it and then offers only
# embedded iPhone depth). Model: Depth Anything V2 Small, Apple's Core ML conversion (F16), Apache-2.0.
#   https://huggingface.co/apple/coreml-depth-anything-v2-small
# The download is pinned to one repository REVISION and every file is checked against a SHA-256 recorded when the model was evaluated
# (docs/ROADMAP_HISTORY.md "Depth Range spike"). Re-run `xcodegen generate` afterwards so the model is bundled.
set -eu

REVISION="cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/${REVISION}/DepthAnythingV2SmallF16.mlpackage"
DEST="$(cd "$(dirname "$0")/.." && pwd)/Models/DepthAnythingV2SmallF16.mlpackage"

fetch() { # path sha256
    target="$DEST/$1"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$2" ]; then
        echo "ok      $1"
        return
    fi
    mkdir -p "$(dirname "$target")"
    echo "fetch   $1"
    curl -fsSL --retry 3 -o "$target.part" "$BASE/$1"
    actual="$(shasum -a 256 "$target.part" | cut -d' ' -f1)"
    if [ "$actual" != "$2" ]; then
        rm -f "$target.part"
        echo "ERROR: $1 has SHA-256 $actual, expected $2" >&2
        exit 1
    fi
    mv "$target.part" "$target"
}

fetch "Manifest.json" "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7"
fetch "Data/com.apple.CoreML/model.mlmodel" "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"
fetch "Data/com.apple.CoreML/weights/weight.bin" "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"
echo "Depth model ready in Models/. Run: xcodegen generate"
