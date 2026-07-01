#!/usr/bin/env bash
# fetch_artifacts.sh — download the large TIDL artifacts + model weights that are too
# big to keep in git, so the runtime can be run out-of-the-box.
#
# These live as a GitHub Release asset on this repo. Publish them once (see
# ../GITHUB_UPLOAD_GUIDE.md step "Attach the large artifacts"), then anyone can run:
#
#     ./fetch_artifacts.sh
#
# and get:
#   artifacts/yolo_tidl/          compiled C7x artifacts for the deployed YOLO (~5 MB)
#   artifacts/twinlite_tidl/      compiled TwinLiteNet (reference)
#   models/yolo26n_carla8_trunc.onnx   truncated YOLO graph
#   models/best.pt                     the trained checkpoint
set -euo pipefail

# ---- configure these two once ---------------------------------------------
REPO="Mohamed-khalid1/beaglebone-ai64-adas"   # owner/repo
TAG="artifacts-v1"                             # the Release tag holding the assets
# ---------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
mkdir -p artifacts models

# tarball published on the release: bundles artifacts/ + models/
ASSET="adas-artifacts.tar.gz"
URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"

echo ">> Downloading ${ASSET} from ${URL}"
if command -v gh >/dev/null 2>&1; then
    gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --clobber
else
    curl -fL --retry 3 -o "$ASSET" "$URL"
fi

echo ">> Extracting"
tar -xzf "$ASSET"
rm -f "$ASSET"

echo ">> Done. Contents:"
find artifacts models -maxdepth 2 -type f 2>/dev/null | sed 's/^/   /' | head -40
echo
echo "Now run:  ./run_native.sh   (or see ../README.md → Run inference)"
