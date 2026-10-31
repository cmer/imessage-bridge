#!/bin/bash
# Build the on-device prompt-injection model that the app downloads:
# Llama Prompt Guard 2 (86M), converted to Core ML.
#
#   scripts/build-prompt-guard.sh            # download, convert, package
#   scripts/build-prompt-guard.sh --install  # also install it for this user,
#                                            # as if the app had downloaded it
#
# Outputs, in build/prompt-guard:
#   Llama-Prompt-Guard-2-86M-coreml.zip  what scripts/publish-prompt-guard.sh
#                                        uploads to GitHub and the app downloads
#   ...zip.sha256
# and build/PromptGuard, the compiled model plus reference.json, which
# `swift test` uses to check the Swift tokenizer and Core ML output against
# PyTorch.
#
# The source model is gated. Once per account: sign in at
# https://huggingface.co/meta-llama/Llama-Prompt-Guard-2-86M, accept the Llama 4
# Community License, and create a read token at
# https://huggingface.co/settings/tokens. Pass it as HF_TOKEN (or log in with
# `hf auth login`).
#
# Needs Python 3.10-3.13 (set PYTHON to choose one). Everything else goes in a
# virtualenv under build/prompt-guard/work. Set PROMPT_GUARD_REVISION to pin a
# model commit; the one used is recorded in the zip's manifest.json.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO=meta-llama/Llama-Prompt-Guard-2-86M
NAME=Llama-Prompt-Guard-2-86M
REVISION="${PROMPT_GUARD_REVISION:-main}"
OUTDIR="$ROOT/build/prompt-guard"
WORK="$OUTDIR/work"
VENV="$WORK/venv"
SRC="$WORK/source"
CONVERTED="$WORK/converted"
PACKAGE="$WORK/package"
ZIP="$OUTDIR/$NAME-coreml.zip"
TESTDIR="$ROOT/build/PromptGuard"
PYTHON="${PYTHON:-python3}"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

INSTALL=0
for a in "$@"; do
    case "$a" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument $a" ;;
    esac
done

command -v "$PYTHON" >/dev/null || die "$PYTHON not found; set PYTHON=/path/to/python3.12"
PYV="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
case "$PYV" in
    3.10|3.11|3.12|3.13) ;;
    *) die "Python $PYV isn't supported by the pinned torch; set PYTHON to a 3.10-3.13 interpreter" ;;
esac

step "Python environment ($WORK)"
mkdir -p "$WORK"
[[ -x "$VENV/bin/python" ]] || "$PYTHON" -m venv "$VENV"
# Versions the conversion was tested with; coremltools lags torch releases.
"$VENV/bin/pip" install -q --disable-pip-version-check \
    "torch==2.7.0" "transformers==4.57.6" "coremltools==9.0" "numpy>=2,<3" \
    "huggingface_hub>=0.30" "safetensors"

step "Downloading $REPO ($REVISION)"
rm -rf "$SRC"
mkdir -p "$SRC"
"$VENV/bin/python" -I - "$REPO" "$REVISION" "$SRC" <<'PY'
import json, sys
from huggingface_hub import HfApi, snapshot_download
from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError
repo, revision, dest = sys.argv[1:]
try:
    info = HfApi().model_info(repo, revision=revision)
    snapshot_download(repo, revision=info.sha, local_dir=dest,
                      allow_patterns=["config.json", "model.safetensors", "tokenizer.json",
                                      "tokenizer_config.json", "special_tokens_map.json",
                                      "LICENSE", "USE_POLICY.md"])
except (GatedRepoError, RepositoryNotFoundError) as e:
    sys.exit(f"Hugging Face refused the download. Accept the license at https://huggingface.co/{repo} "
             f"and set HF_TOKEN to a token from that account.\n{type(e).__name__}: {e}")
json.dump({"repo": repo, "revision": info.sha}, open(f"{dest}/source.json", "w"))
PY

step "Converting to Core ML"
rm -rf "$CONVERTED"
"$VENV/bin/python" -I scripts/convert_prompt_guard.py --model-dir "$SRC" --out "$CONVERTED" --name "$NAME"

step "Packaging $ZIP"
rm -rf "$PACKAGE"
mkdir -p "$PACKAGE"
cp -R "$CONVERTED/$NAME.mlpackage" "$CONVERTED/embeddings.bin" "$SRC/tokenizer.json" "$PACKAGE/"
cp "$SRC/LICENSE" "$PACKAGE/LICENSE.txt"
[[ -f "$SRC/USE_POLICY.md" ]] && cp "$SRC/USE_POLICY.md" "$PACKAGE/"
cat > "$PACKAGE/NOTICE.txt" <<'TXT'
Llama 4 is licensed under the Llama 4 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved.

Llama Prompt Guard 2 (86M) by Meta, converted to Core ML for iMessage Bridge
(https://github.com/cmer/imessage-bridge). Built with Llama.

The weights are unchanged except for format: the transformer weights and the
token embedding table are stored as 8-bit integers. LICENSE.txt is the license;
USE_POLICY.md is Meta's Acceptable Use Policy, which applies to this model.
TXT
"$VENV/bin/python" -I - "$SRC/source.json" "$PACKAGE/manifest.json" "$NAME" <<'PY'
import json, sys, datetime
m = json.load(open(sys.argv[1]))
m["name"] = sys.argv[3]
m["converted"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
json.dump(m, open(sys.argv[2], "w"), indent=1)
PY
rm -f "$ZIP"
# Flat archive: the files sit at the top level, which the app expects.
(cd "$PACKAGE" && /usr/bin/ditto -c -k --norsrc --noextattr . "$ZIP")
shasum -a 256 "$ZIP" | cut -d' ' -f1 > "$ZIP.sha256"

step "Compiling for tests ($TESTDIR)"
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"
swift scripts/compile_coreml.swift "$PACKAGE/$NAME.mlpackage" "$TESTDIR/$NAME.mlmodelc"
cp "$CONVERTED/embeddings.bin" "$CONVERTED/reference.json" "$SRC/tokenizer.json" "$TESTDIR/"

if [[ $INSTALL == 1 ]]; then
    DEST="$HOME/Library/Application Support/iMessage Bridge/PromptGuard"
    step "Installing to $DEST"
    rm -rf "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -R "$TESTDIR" "$DEST"
    rm -f "$DEST/reference.json"
    printf '{"sha256": "%s"}\n' "$(cat "$ZIP.sha256")" > "$DEST/installed.json"
fi

echo
echo "==> Done"
echo "    $ZIP ($(du -h "$ZIP" | cut -f1), sha256 $(cat "$ZIP.sha256"))"
echo "    Publish it with: scripts/publish-prompt-guard.sh <version>"
