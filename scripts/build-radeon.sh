#!/usr/bin/env bash
# Build llama.cpp tuned for a discrete AMD Radeon GPU (e.g. RX 6900 XT, gfx1030) with ROCm/HIP.
#
# Usage:
#   ./scripts/build-radeon.sh [options]
#
# Options:
#   -c, --clean        remove the build dir first
#   -j, --jobs N       parallel build jobs (default: nproc)
#   -B, --build-dir D  build dir (default: build-rocm)
#   -a, --arch GFX     GPU target, e.g. gfx1030, gfx1100 (default: auto-detect)
#       --lto          enable link time optimization for the CPU code
#       --tests        also build tests
#   -h, --help         show this help
#
# Extra args after "--" go to cmake configure, e.g.:
#   ./scripts/build-radeon.sh -- -DGGML_CUDA_FA_ALL_QUANTS=ON

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLEAN=0
LTO=OFF
TESTS=OFF
JOBS="$(nproc)"
BUILD_DIR="${ROOT_DIR}/build-rocm"
GPU_ARCH=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean)     CLEAN=1 ;;
        -j|--jobs)      JOBS="$2"; shift ;;
        -B|--build-dir) BUILD_DIR="$(realpath -m "$2")"; shift ;;
        -a|--arch)      GPU_ARCH="$2"; shift ;;
        --lto)          LTO=ON ;;
        --tests)        TESTS=ON ;;
        -h|--help)      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)             shift; EXTRA_ARGS=("$@"); break ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

for tool in cmake hipconfig; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "error: ${tool} not found" >&2
        exit 1
    fi
done

# hipconfig -R gives the real ROCm root (e.g. /opt/rocm/core-10.2 on the TheRock-style layout)
ROCM_PATH="$(hipconfig -R)"
HIP_CLANG_DIR="$(hipconfig -l)"
export ROCM_PATH
export HIP_PATH="${ROCM_PATH}"
export HIPCXX="${HIP_CLANG_DIR}/clang"

if [ -z "${GPU_ARCH}" ]; then
    if command -v rocm_agent_enumerator &>/dev/null; then
        GPU_ARCH="$(rocm_agent_enumerator | grep -v '^gfx000$' | sort -u | paste -sd ';' -)"
    elif command -v rocminfo &>/dev/null; then
        GPU_ARCH="$(rocminfo | grep -oE '^\s+Name:\s+gfx[0-9a-f]+' | awk '{print $2}' | sort -u | paste -sd ';' -)"
    fi
fi
if [ -z "${GPU_ARCH}" ]; then
    echo "error: no AMD GPU found, pass --arch (e.g. --arch gfx1030)" >&2
    exit 1
fi

# the UI assets are downloaded for release b<commit count>, which does not exist on a branch with local commits,
# so use the nearest upstream tag instead
if [ -z "${HF_UI_VERSION:-}" ] && TAG="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 --match 'b[0-9]*' 2>/dev/null)"; then
    export HF_UI_VERSION="${TAG}"
fi

GENERATOR=()
if command -v ninja &>/dev/null; then
    GENERATOR=(-G Ninja)
fi

LAUNCHER=()
if command -v ccache &>/dev/null; then
    LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_HIP_COMPILER_LAUNCHER=ccache)
fi

echo "ROCm:       ${ROCM_PATH} ($(hipconfig --version))"
echo "GPU target: ${GPU_ARCH}"
echo "CPU:        $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "Build dir:  ${BUILD_DIR}"

if [ "${CLEAN}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
fi

# GGML_NATIVE: -march=native for the CPU backend (AVX2/FMA/F16C on Zen 3), used for layers that do not fit in VRAM
# CMAKE_HIP_FLAGS: clang adds the ROCm include dir with -idirafter, so an older distro HIP in /usr/include would win
# CMAKE_BUILD_RPATH: libggml-hip.so does not get the ROCm lib dir in its RUNPATH, so it fails to load when ROCm is not in the ld.so paths
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" "${GENERATOR[@]}" "${LAUNCHER[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_BUILD_RPATH="${ROCM_PATH}/lib" \
    -DCMAKE_HIP_FLAGS="-isystem ${ROCM_PATH}/include" \
    -DGGML_NATIVE=ON \
    -DGGML_LTO="${LTO}" \
    -DGGML_OPENMP=ON \
    -DGGML_HIP=ON \
    -DGGML_HIP_GRAPHS=ON \
    -DGPU_TARGETS="${GPU_ARCH}" \
    -DLLAMA_BUILD_TESTS="${TESTS}" \
    "${EXTRA_ARGS[@]}"

cmake --build "${BUILD_DIR}" --config Release -j "${JOBS}"

cat <<EOF

Build done: ${BUILD_DIR}/bin

Runtime tips for a discrete Radeon (measured on an RX 6900 XT, gfx1030, 16 GiB):
  - Vulkan generates 4-14% faster than ROCm on every tested model, see scripts/build-radeon-vulkan.sh
    ROCm is faster for long prompts at depth (+16% pp2048 at 16K context) and on Q4_0 models (+9% at 4096 tokens)
  - Offload all layers to the GPU: -ngl 99
  - Always use flash attention: -fa on (up to 2x faster prompts at 4096 tokens)
  - Long prompts: -ub 2048 -b 2048 (+1-5% at 4096 tokens)
  - A q8_0 KV cache halves its memory for 1-4% generation speed, ~0% at 16K depth: -ctk q8_0 -ctv q8_0
  - Models with an MTP head (e.g. Ornith-1.5-9B): --spec-type draft-mtp (+65% generation)
  - Gemma 4 with Ollama's assistant draft blob: --spec-type draft-mtp -md <gemma4-assistant.gguf> -ngld 99 --spec-draft-n-max 4
  - Compare settings with: ${BUILD_DIR}/bin/llama-bench -m model.gguf -ngl 99 -fa 1 -ub 512,2048 -p 512,4096
EOF
