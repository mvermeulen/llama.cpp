#!/usr/bin/env bash
# Build llama.cpp tuned for an AMD Ryzen AI APU (Zen 5 CPU + RDNA 3.5 iGPU) with ROCm/HIP.
#
# Usage:
#   ./scripts/build-ryzen-ai.sh [options]
#
# Options:
#   -c, --clean        remove the build dir first
#   -j, --jobs N       parallel build jobs (default: nproc)
#   -B, --build-dir D  build dir (default: build-rocm)
#   -a, --arch GFX     GPU target, e.g. gfx1151, gfx1152 (default: auto-detect)
#       --lto          enable link time optimization for the CPU code
#       --tests        also build tests
#   -h, --help         show this help
#
# Extra args after "--" go to cmake configure, e.g.:
#   ./scripts/build-ryzen-ai.sh -- -DGGML_CUDA_FA_ALL_QUANTS=ON

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

# hipconfig -R gives the real ROCm root (may differ from /opt/rocm on newer layouts)
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
    echo "error: no AMD GPU found, pass --arch (e.g. --arch gfx1151)" >&2
    exit 1
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

# GGML_NATIVE: -march=native, picks up Zen 5 AVX-512 (VNNI, BF16, VBMI) for the CPU backend
# GGML_HIP_NO_VMM=ON is the default and is what the APU needs
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" "${GENERATOR[@]}" "${LAUNCHER[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
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

Runtime tips for this APU:
  - The iGPU shares system RAM. If the model does not fit in the BIOS carve-out, let it allocate beyond it with:
      export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1
    With a large carve-out (e.g. 96-160 GiB on Strix Halo) this is not needed.
  - Offload all layers to the iGPU: -ngl 99
  - Always use flash attention: -fa on
  - Faster long prompts: -ub 2048 -b 2048 (+7-19% on gfx1151, depending on model)
  - On gfx1151 Vulkan generates 4-9% faster; prompt speed is model dependent, see scripts/build-ryzen-ai-vulkan.sh
  - For CPU work use the physical core count: -t $(lscpu -p=CORE | grep -v '^#' | sort -u | wc -l)
  - Compare settings with: ${BUILD_DIR}/bin/llama-bench -m model.gguf -ngl 99 -fa 1 -ub 512,2048 -p 512,4096
EOF
