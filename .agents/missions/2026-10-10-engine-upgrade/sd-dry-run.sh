#!/bin/zsh
# Dry-run of the exact build-engines.sh stable-diffusion.cpp patch sequence at a candidate
# commit, minus the cmake build. Resets the tree at the end. Usage: sd-dry-run.sh <commit>
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VENDOR="$ROOT/vendor/stable-diffusion.cpp"
CANDIDATE="$1"
cd "$VENDOR"

git -C ggml checkout -- . 2>/dev/null || true
git checkout -- . 2>/dev/null || true
git checkout -qf "$CANDIDATE" || exit 2
# submodule must still be the pin the candidate declares
declared=$(git ls-tree HEAD ggml | awk '{print $3}')
current=$(git -C ggml rev-parse HEAD)
if [ "$declared" != "$current" ]; then echo "SUBMODULE MISMATCH: candidate pins $declared, tree has $current"; exit 2; fi
git checkout -- . 2>/dev/null || true
git -C ggml checkout -- . 2>/dev/null || true

# shared-metal with expected rejects
expected_rejects="ggml-metal-device.cpp.rej ggml-metal-device.m.rej ggml-metal.cpp.rej ggml-metal.metal.rej"
for shared in "$ROOT"/patches/shared-metal/0001-*.patch; do
    git apply --reject --exclude='ggml/src/ggml-metal/ggml-metal-impl.h' \
              --include='ggml/src/ggml-metal/*' -p1 "$shared" >/dev/null 2>&1 || true
done
got_rejects=$(find ggml/src/ggml-metal -name '*.rej' -exec basename {} \; | sort -u | tr '\n' ' ')
got_rejects="${got_rejects% }"
if [ "$got_rejects" != "$expected_rejects" ]; then
    echo "REJECT-SET MISMATCH: expected [$expected_rejects] got [$got_rejects]"
    find ggml/src/ggml-metal \( -name '*.rej' -o -name '*.orig' \) -delete 2>/dev/null
    git checkout -qf 6dcb5bb 2>/dev/null; exit 1
fi
find ggml/src/ggml-metal \( -name '*.rej' -o -name '*.orig' \) -delete

fail() {
    echo "APPLY-FAIL: $(basename "$1")"
    git checkout -qf 6dcb5bb 2>/dev/null
    git -C ggml checkout -qf 4bf5f6000653b7881d00963cd6ddb665ccd62a8d 2>/dev/null
    exit 1
}

apply() { # apply <include-or-empty> <extra-flags-or-empty> <patch>
    local patch="$3"
    if [ -n "$1" ] && [ -n "$2" ]; then
        git apply --include="$1" $2 -p1 "$patch" || fail "$patch"
    elif [ -n "$1" ]; then
        git apply --include="$1" -p1 "$patch" || fail "$patch"
    else
        git apply -p1 "$patch" || fail "$patch"
    fi
}

apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0002-image-metal-divergent-hunks.patch
apply 'ggml/src/ggml-metal/ggml-metal-impl.h' '-C2' "$ROOT"/patches/shared-metal/0001-7-metal-backend-host.patch
apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0003-image-metal-ncb.patch
apply '' '' "$ROOT"/patches/image/0004-image-cpu-fallback-sched.patch
apply '' '' "$ROOT"/patches/image/0008-image-ext-wave64.patch
apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0021-image-metal-im2col-3d.patch
apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0047-image-fa-unet-heads.patch
apply '' '' "$ROOT"/patches/image/0049-image-free-diffusion-before-video-decode.patch
apply '' '' "$ROOT"/patches/image/0050-image-vae-tile-yield.patch
apply '' '' "$ROOT"/patches/image/0051-image-loader-pread.patch
apply '' '' "$ROOT"/patches/image/0052-image-bf16-promote-without-bfloat.patch
apply '' '' "$ROOT"/patches/image/0053-image-lora-f16-weight-cast.patch
apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0055-image-metal-live-vram-report.patch
apply 'ggml/src/ggml-metal/*' '' "$ROOT"/patches/image/0056-image-metal-half-partials.patch

# the two scripted landing assertions
local metal="ggml/src/ggml-metal/ggml-metal.metal"
if ! awk '/^kernel void kernel_cumsum_blk\(/,/\{$/' "$metal" | grep -q 'sgptg\[\[threads_per_simdgroup\]\]'; then
    echo "ASSERT-FAIL: cumsum_blk lost sgptg"; git checkout -qf 6dcb5bb 2>/dev/null; exit 1
fi
local impl="ggml/src/ggml-metal/ggml-metal-impl.h"
if ! awk '/ggml_metal_kargs_flash_attn_ext_vec;/{exit} {print}' "$impl" | grep -q 'int32_t  has_mask;'; then
    echo "ASSERT-FAIL: flash_attn_ext_vec lost has_mask"; git checkout -qf 6dcb5bb 2>/dev/null; exit 1
fi

echo "SD-DryRun-CLEAN: full sequence lands on $CANDIDATE"
# reset tree so the next real build starts fresh
git checkout -qf 6dcb5bb 2>/dev/null
git -C ggml checkout -- . 2>/dev/null; git checkout -- . 2>/dev/null
