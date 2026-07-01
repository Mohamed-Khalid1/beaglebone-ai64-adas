# edgeai-tidl-models.bbappend — match the model artifacts to the board TIDL stack.
#
# ======================= WHY 11_00_04_00 (evidence-based) =======================
# Supersedes the earlier 10_01_00 EXPERIMENT. This value is proven on real
# BeagleBone AI-64 hardware by a third-party Yocto layer that runs TIDL on the C7x
# with the STOCK psdk_fw firmware (no firmware swap):
#   https://github.com/kevinacahalan/meta-beaglebone-ai64-edgeai-sdk-11-00-fix
# Its edgeai-tidl-models.bbappend pins EDGEAI_SDK_VERSION=11_00_04_00 and reports
# "TIDL model network version 0x20250429" working.
#
# The board's TIDL stack has two hard gates on the model artifacts:
#   1. io.bin SIZE: the arm-tidl runtime (libvx_tidl_rt.so) requires
#      subgraph_0_tidl_io_1.bin == sizeof(sTIDL_IOBufDesc_t) == 94616 bytes
#      (J721E, 1x C7x; identical across 11.00 and 11.01). Wrong size ->
#      "Config file size does not match" -> vxGetStatus NULL -> 0 nodes offloaded.
#   2. NET VERSION: the C7x firmware checks the model's tidl_net.bin version
#      ("Network version - 0x%08X, Expected version - 0x%08X"). The stock psdk_fw
#      blob (the SAME blob we and the working layer both use) expects 0x20250437.
#
# Net versions per published modelzoo (verified by downloading each):
#   09_02_00    -> 0x20240401 (io 93976, WRONG size)
#   10_00_00    -> 0x20240719 (io 94616)
#   10_01_00    -> 0x20241120 (io 94616)   2024-11, far from firmware 2025-04
#   11_00_04_00 -> 0x20250429 (io 94616)   <-- pinned here; 2025-04, matches fw month
#   11_00_00    -> 0x20250630 (io 94616)   2025-06, REJECTED (newer)
#   11_01_00    -> 0x20250821 (io 94616)   2025-08, REJECTED (newer)
#   11_02_00    -> 378392-byte io (4-core, WRONG size)
#
# Key insight: 0x20250429 (model) != 0x20250437 (firmware) yet WORKS on hardware,
# so the firmware net check is NOT strict equality — it tolerates the same
# year+month build window (2025-04). 11_00_04_00 lands inside that window; the
# older 10_01_00 (2024-11) almost certainly does not. io 94616 satisfies gate 1.
#
# NOTE on our runtime: we pin arm-tidl to 11.01.06 (ti-tidl.bbappend); the working
# layer is full 11.00. Both runtimes use io.bin == 94616, and the net check is
# firmware-side (identical 0x20250437 blob for both), so 11_00_04_00 should pass on
# our image too. If the 11.01 runtime rejects an 11.00 model for some ABI reason,
# the fallback is to also drop arm-tidl/vision-apps to 11.00 to fully match the
# proven stack. Confirm on hardware.
#
# 11_00_04_00 --recommended uses onnxrt cl-6360 (regnetx-200mf) for classification.
# ================================================================================

EDGEAI_MODELS_SDK_VERSION = "11_02_00"
EDGEAI_MODELS_SDK_VERSION:edgeai = "11_00_04_00"

# The 10_01_00 --recommended set includes tvmdlr models (TVM-OD-5120, TVM-SS-5710)
# that ship deploy_lib.so* artifacts. These are TVM data blobs, NOT ELF objects, but
# OE's packaging matches them against *.so* and runs `objcopy --only-keep-debug` to
# split debug symbols -> "Unable to recognise the format" -> do_package fails.
# (The 11_02_00 default set has no such artifacts, so this only bites the 10_01_00
# pin.) These are model data, not debuggable binaries, so disable strip/debug-split
# for this package.
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

do_fetch() {
    mkdir -p ${WORKDIR}/script
    cd ${WORKDIR}/script

    VERSION="${SRCREV}"

    wget https://raw.githubusercontent.com/TexasInstruments/edgeai-gst-apps/${VERSION}/download_models.sh
    chmod +x ./download_models.sh

    export SOC="${SOC}"
    export EDGEAI_SDK_VERSION=${EDGEAI_MODELS_SDK_VERSION}
    ./download_models.sh --recommended
}

# Drop the tvmdlr (TVM-*) models. They ship deploy_lib.so* artifacts whose
# extensions collide with THREE OE packaging heuristics, each of which aborts
# do_package on these binary blobs:
#   *.so*  -> debug-split   : objcopy "Unable to recognise the format"
#   *.so   -> shlibs        : spurious libc/libm RDEPENDS
#   *.so.pc-> pkgconfig     : process_pkgconfig readlines() a binary -> UnicodeDecodeError
# This board runs the onnxruntime TIDL path only; tvmdlr models are unused. Remove
# any model dir that contains a deploy_lib.so* so the package is clean data.
do_install:append:edgeai () {
    if [ -d ${D}/opt/model_zoo ]; then
        for f in $(find ${D}/opt/model_zoo -name 'deploy_lib.so*' 2>/dev/null); do
            moddir=$(dirname $(dirname "$f"))
            if [ -d "$moddir" ]; then
                bbnote "edgeai-tidl-models: dropping tvmdlr model dir $moddir (deploy_lib.so* breaks packaging)"
                rm -rf "$moddir"
            fi
        done
    fi
}
