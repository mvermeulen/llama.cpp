#!/usr/bin/env bash
# Build llama.cpp tuned for an AMD Ryzen AI APU (Zen 5 CPU + RDNA 3.5 iGPU) with Vulkan (Mesa RADV).
#
# Usage:
#   ./scripts/build-ryzen-ai-vulkan.sh [options]
#
# Options:
#   -c, --clean        remove the build dir first
#   -j, --jobs N       parallel build jobs (default: nproc)
#   -B, --build-dir D  build dir (default: build-vulkan)
#       --lto          enable link time optimization for the CPU code
#       --tests        also build tests
#   -h, --help         show this help
#
# Extra args after "--" go to cmake configure.
#
# Needs (Ubuntu/Debian): sudo apt-get install libvulkan-dev glslc spirv-headers mesa-vulkan-drivers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLEAN=0
LTO=OFF
TESTS=OFF
JOBS="$(nproc)"
BUILD_DIR="${ROOT_DIR}/build-vulkan"
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--clean)     CLEAN=1 ;;
        -j|--jobs)      JOBS="$2"; shift ;;
        -B|--build-dir) BUILD_DIR="$(realpath -m "$2")"; shift ;;
        --lto)          LTO=ON ;;
        --tests)        TESTS=ON ;;
        -h|--help)      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)             shift; EXTRA_ARGS=("$@"); break ;;
        *) echo "error: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

MISSING=()
command -v cmake &>/dev/null || MISSING+=(cmake)
command -v glslc &>/dev/null || MISSING+=(glslc)
[ -f /usr/include/vulkan/vulkan.h ] || MISSING+=(libvulkan-dev)
compgen -G "/usr/share/cmake*/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null \
    || compgen -G "/usr/lib/*/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null \
    || compgen -G "/usr/lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null \
    || MISSING+=(spirv-headers)
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "error: missing packages: ${MISSING[*]}" >&2
    echo "hint: sudo apt-get install ${MISSING[*]}" >&2
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
    LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

echo "CPU:        $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
if command -v vulkaninfo &>/dev/null; then
    echo "Vulkan GPU: $(vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | cut -d= -f2 | xargs)"
fi
echo "Build dir:  ${BUILD_DIR}"

if [ "${CLEAN}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
fi

# shaders are SPIR-V and get compiled for the GPU by the driver at run time, so only the CPU part needs -march=native
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" "${GENERATOR[@]}" "${LAUNCHER[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_NATIVE=ON \
    -DGGML_LTO="${LTO}" \
    -DGGML_OPENMP=ON \
    -DGGML_VULKAN=ON \
    -DLLAMA_BUILD_TESTS="${TESTS}" \
    "${EXTRA_ARGS[@]}"

cmake --build "${BUILD_DIR}" --config Release -j "${JOBS}"

cat <<EOF

Build done: ${BUILD_DIR}/bin

Runtime tips for this APU:
  - Check the iGPU is picked (not llvmpipe): ${BUILD_DIR}/bin/llama-cli --list-devices
  - Offload all layers to the iGPU: -ngl 99
  - Always use flash attention: -fa on (30-50% faster prompt processing)
  - Faster long prompts: -ub 2048 -b 2048 (+12-71% at 4096 tokens on gfx1151, most on large MoE models; -ub 1024 is best on gfx1152)
  - A q8_0 KV cache halves its memory for ~1% speed: -ctk q8_0 -ctv q8_0
  - Models with an MTP head (e.g. Qwen3.5-122B): --spec-type draft-mtp (+58% generation on gfx1151)
  - EAGLE3 drafts for gpt-oss did not help on gfx1151 (0 to -14% generation, -13% prompt)
  - For CPU work use the physical core count: -t $(lscpu -p=CORE | grep -v '^#' | sort -u | wc -l)
  - Compare with the ROCm build: ${BUILD_DIR}/bin/llama-bench -m model.gguf -ngl 99 -fa 1 -ub 512,2048 -p 512,4096
EOF
