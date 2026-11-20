#!/usr/bin/env bash
# Check that an AMD Ryzen AI APU machine is set up for llama.cpp (ROCm and Vulkan builds) and Ollama.
# Read-only: changes nothing and needs no sudo. Prints PASS/WARN/FAIL per item with a hint how to fix it.
#
# Usage:
#   ./scripts/check-ryzen-ai.sh [-h]
#
# Exit status is 1 if any check failed, 0 otherwise (warnings do not fail).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

N_FAIL=0
N_WARN=0

if [ -t 1 ]; then
    C_PASS=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_HEAD=$'\e[1m'; C_OFF=$'\e[0m'
else
    C_PASS=""; C_WARN=""; C_FAIL=""; C_HEAD=""; C_OFF=""
fi

section() { printf '\n%s== %s%s\n' "${C_HEAD}" "$1" "${C_OFF}"; }
pass()    { printf '  %sPASS%s  %s\n' "${C_PASS}" "${C_OFF}" "$1"; }
info()    { printf '  INFO  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "${@:2}"; return 0; }
warn()    { printf '  %sWARN%s  %s\n' "${C_WARN}" "${C_OFF}" "$1"; N_WARN=$((N_WARN + 1)); [ $# -gt 1 ] && printf '        -> %s\n' "${@:2}"; return 0; }
fail()    { printf '  %sFAIL%s  %s\n' "${C_FAIL}" "${C_OFF}" "$1"; N_FAIL=$((N_FAIL + 1)); [ $# -gt 1 ] && printf '        -> %s\n' "${@:2}"; return 0; }
have()    { command -v "$1" &>/dev/null; }
gib()     { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1073741824 }'; }

# ---------------------------------------------------------------------------------------------------------------------
section "System"

CPU="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
info "CPU:    ${CPU}"
info "Kernel: $(uname -r), $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown OS}")"

if grep -qw avx512f /proc/cpuinfo; then
    pass "AVX-512 available ($(grep -o -wE 'avx512_(vnni|bf16)|avx512vbmi' /proc/cpuinfo | sort -u | paste -sd ' ' -)), GGML_NATIVE=ON will use it"
else
    warn "no AVX-512, the CPU backend will be slower" "expected on Zen 4/5, check BIOS or virtualization settings"
fi

GOV="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
EPP="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo unknown)"
PROFILE="$(have powerprofilesctl && powerprofilesctl get 2>/dev/null || echo unknown)"
if [ "${PROFILE}" = "performance" ]; then
    pass "power profile: performance (governor ${GOV}, EPP ${EPP})"
else
    warn "power profile: ${PROFILE} (governor ${GOV}, EPP ${EPP})" "for benchmarking: powerprofilesctl set performance"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "GPU and access"

GPU_ARCH=""
for props in /sys/class/kfd/kfd/topology/nodes/*/properties; do
    v="$(awk '/^gfx_target_version/ { print $2 }' "${props}" 2>/dev/null)"
    if [ -n "${v}" ] && [ "${v}" != "0" ]; then
        GPU_ARCH="$(printf 'gfx%d%x%x' $((v / 10000)) $((v / 100 % 100)) $((v % 100)))"
        break
    fi
done

AMD_CARD=""
for c in /sys/class/drm/card[0-9]*; do
    [ -e "${c}/device/driver" ] || continue
    if [ "$(basename "$(readlink -f "${c}/device/driver")")" = "amdgpu" ]; then
        AMD_CARD="${c}"
        break
    fi
done

if [ -n "${AMD_CARD}" ]; then
    pass "amdgpu driver loaded ($(basename "${AMD_CARD}"))"
else
    fail "no GPU bound to the amdgpu driver" "check: lspci -k | grep -A3 -iE 'vga|display'"
fi

if [ -n "${GPU_ARCH}" ]; then
    pass "GPU arch from KFD: ${GPU_ARCH}"
else
    fail "no GPU found in /sys/class/kfd (ROCm cannot see the GPU)" "check: ls -l /dev/kfd; dmesg | grep -i kfd"
fi

for dev in /dev/kfd /dev/dri/renderD*; do
    [ -e "${dev}" ] || continue
    if [ -r "${dev}" ] && [ -w "${dev}" ]; then
        pass "read/write access to ${dev}"
    else
        fail "no access to ${dev} (owned by group $(stat -c %G "${dev}"))" "sudo usermod -aG render,video ${USER}, then log out and back in"
    fi
done

# ---------------------------------------------------------------------------------------------------------------------
section "Memory available to the iGPU"

RAM_KB="$(awk '/^MemTotal/ { print $2 }' /proc/meminfo)"
RAM_B=$((RAM_KB * 1024))
info "system RAM: $(gib ${RAM_B}) GiB"

if [ -n "${AMD_CARD}" ]; then
    VRAM_B="$(cat "${AMD_CARD}/device/mem_info_vram_total" 2>/dev/null || echo 0)"
    GTT_B="$(cat "${AMD_CARD}/device/mem_info_gtt_total" 2>/dev/null || echo 0)"
    info "BIOS VRAM carve-out: $(gib "${VRAM_B}") GiB, GTT (shared RAM the GPU may use): $(gib "${GTT_B}") GiB"

    # ~10 GiB is left for the OS; pages are 4 KiB
    WANT_PAGES=$(( (RAM_B - 10 * 1073741824) / 4096 ))
    GPU_TOTAL=$((VRAM_B + GTT_B))
    if grep -q 'ttm.pages_limit' /etc/default/grub 2>/dev/null && ! grep -q 'ttm.pages_limit' /proc/cmdline; then
        warn "the GPU can use only $(gib ${GPU_TOTAL}) GiB now, ttm.pages_limit is in /etc/default/grub but not in the running kernel" \
             "reboot to apply it"
    elif [ "${GPU_TOTAL}" -ge $((RAM_B * 3 / 4)) ]; then
        pass "the GPU can use $(gib ${GPU_TOTAL}) GiB (VRAM + GTT), at least 75% of RAM"
    else
        warn "the GPU can use only $(gib ${GPU_TOTAL}) GiB (VRAM + GTT), large models will not fit" \
             "add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub: ttm.pages_limit=${WANT_PAGES} ttm.page_pool_size=${WANT_PAGES}" \
             "then: sudo update-grub && reboot  (or raise the VRAM carve-out in the BIOS)"
    fi

fi

# ---------------------------------------------------------------------------------------------------------------------
section "Build tools"

for tool in git cmake gcc g++; do
    if have "${tool}"; then pass "${tool}: $(command -v "${tool}")"; else fail "${tool} not found" "sudo apt-get install build-essential cmake git"; fi
done
have ninja  && pass "ninja found"  || warn "ninja not found, builds fall back to make" "sudo apt-get install ninja-build"
have ccache && pass "ccache found" || warn "ccache not found, rebuilds are slower" "sudo apt-get install ccache"

if [ -f /usr/include/openssl/ssl.h ]; then
    pass "OpenSSL headers found (HTTPS for -hf model downloads)"
else
    warn "OpenSSL headers not found, llama.cpp is built without HTTPS" "sudo apt-get install libssl-dev"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "Vulkan build (scripts/build-ryzen-ai-vulkan.sh)"

have glslc && pass "glslc found" || fail "glslc not found" "sudo apt-get install glslc"
[ -f /usr/include/vulkan/vulkan.h ] && pass "Vulkan headers found" || fail "Vulkan headers not found" "sudo apt-get install libvulkan-dev"
if compgen -G "/usr/share/cmake*/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null \
    || compgen -G "/usr/lib/*/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null \
    || compgen -G "/usr/lib/cmake/SPIRV-Headers/SPIRV-HeadersConfig.cmake" >/dev/null; then
    pass "SPIRV-Headers found"
else
    fail "SPIRV-Headers not found (ggml-vulkan requires it)" "sudo apt-get install spirv-headers"
fi

if have vulkaninfo; then
    VK_DEVS="$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/ { gsub(/^ +| +$/, "", $2); print $2 }')"
    if grep -qv llvmpipe <<< "${VK_DEVS}"; then
        pass "Vulkan GPU: $(grep -v llvmpipe <<< "${VK_DEVS}" | head -1)"
    else
        fail "Vulkan sees only llvmpipe (CPU), not the iGPU" "sudo apt-get install mesa-vulkan-drivers"
    fi
else
    warn "vulkaninfo not found, cannot check the Vulkan driver" "sudo apt-get install vulkan-tools"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "ROCm build (scripts/build-ryzen-ai.sh)"

if have hipconfig; then
    ROCM_PATH_DET="$(hipconfig -R 2>/dev/null)"
    pass "hipconfig: ROCm at ${ROCM_PATH_DET}, HIP $(hipconfig --version 2>/dev/null)"

    if [ -n "${GPU_ARCH}" ]; then
        if have rocm_agent_enumerator && rocm_agent_enumerator 2>/dev/null | grep -qx "${GPU_ARCH}"; then
            pass "ROCm runtime sees ${GPU_ARCH}"
        else
            fail "ROCm runtime does not list ${GPU_ARCH}" "check: rocminfo | grep gfx"
        fi

        # per-arch math libraries: the AMD packages are split by arch (amdrocm-*-gfxNNNN), installing the wrong one is easy
        for lib in rocblas hipblaslt; do
            dir="${ROCM_PATH_DET}/lib/${lib}/library"
            [ -d "${dir}" ] || continue
            if ls "${dir}" | grep -q "${GPU_ARCH}"; then
                pass "${lib} has kernels for ${GPU_ARCH}"
            else
                pkg="$(apt-cache pkgnames 2>/dev/null | grep -E "^amdrocm-core-sdk[0-9.]+-${GPU_ARCH}$" | sort -V | tail -1)"
                fail "${lib} has no kernels for ${GPU_ARCH} (has: $(ls "${dir}" | grep -oE 'gfx[0-9a-f]+' | sort -u | paste -sd ' ' -))" \
                     "install the ROCm packages for this GPU${pkg:+: sudo apt-get install ${pkg} ${pkg/core-sdk/blas}}"
            fi
        done
    fi

    if have dpkg-query; then
        OTHER_ARCH="$(dpkg-query -W -f='${Package}\n' 'amdrocm-*-gfx*' 2>/dev/null | grep -oE 'gfx[0-9a-f]+$' | sort -u | grep -vx "${GPU_ARCH:-none}" | paste -sd ' ' -)"
        [ -n "${OTHER_ARCH}" ] && info "ROCm packages for other GPUs are installed too (${OTHER_ARCH}), harmless but unused"
    fi

    # a second HIP in /usr/include shadows the ROCm one: clang adds ROCm's include dir with -idirafter
    if [ "${ROCM_PATH_DET}" != "/usr" ] && [ -f /usr/include/hip/hip_version.h ]; then
        sys_ver="$(awk '/define HIP_VERSION_(MAJOR|MINOR) / { printf "%s.", $3 }' /usr/include/hip/hip_version.h | sed 's/\.$//')"
        owner="$(dpkg -S /usr/include/hip/hip_version.h 2>/dev/null | cut -d: -f1)"
        warn "a second HIP (${sys_ver}${owner:+, package ${owner}}) is in /usr/include next to ${ROCM_PATH_DET}" \
             "build-ryzen-ai.sh works around it; to remove it: sudo apt-get purge rocm and the distro lib*hip*/lib*roc* packages"
    else
        pass "only one HIP installation"
    fi
else
    warn "hipconfig not found, no ROCm build possible (the Vulkan build does not need it)" \
         "install ROCm for ${GPU_ARCH:-this GPU} from https://repo.radeon.com"
fi

# ---------------------------------------------------------------------------------------------------------------------
section "llama.cpp builds in ${ROOT_DIR}"

for b in build-rocm build-vulkan; do
    bin="${ROOT_DIR}/${b}/bin/llama-server"
    if [ ! -x "${bin}" ]; then
        info "${b}: not built"
        continue
    fi
    missing="$(ldd "${ROOT_DIR}/${b}"/bin/*.so "${bin}" 2>/dev/null | awk '/not found/ { print $1 }' | sort -u | paste -sd ' ' -)"
    if [ -n "${missing}" ]; then
        fail "${b}: missing shared libraries: ${missing}" "rebuild with the matching scripts/build-ryzen-ai*.sh"
        continue
    fi
    devs="$("${ROOT_DIR}/${b}/bin/llama-cli" --list-devices 2>/dev/null | grep -E '^\s+(ROCm|Vulkan)[0-9]' | xargs)"
    if [ -n "${devs}" ]; then
        pass "${b}: ${devs}"
    else
        fail "${b}: no GPU device found" "run: ${b}/bin/llama-cli --list-devices"
    fi
done

if git -C "${ROOT_DIR}" rev-parse --git-dir &>/dev/null; then
    tag="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 --match 'b[0-9]*' 2>/dev/null)"
    count="$(git -C "${ROOT_DIR}" rev-list --count HEAD)"
    if [ -n "${tag}" ] && [ "${tag}" != "b${count}" ]; then
        info "HEAD is build b${count} but the nearest tag is ${tag}: plain cmake builds fail to download the UI assets," \
             "use the build-ryzen-ai*.sh scripts or set HF_UI_VERSION=${tag}"
    fi
fi

# ---------------------------------------------------------------------------------------------------------------------
section "Ollama"

if ! have ollama; then
    info "ollama not installed"
else
    info "$(ollama --version 2>/dev/null | head -1)"
    if ! systemctl is-active --quiet ollama 2>/dev/null; then
        warn "ollama service is not running" "sudo systemctl enable --now ollama"
    else
        pass "ollama service is running"
        ENV="$(systemctl show ollama -p Environment --value 2>/dev/null)"
        chk_env() {
            if grep -qE "(^| )$1=$2( |$)" <<< "${ENV}"; then
                pass "$1=$2"
            else
                $3 "$1 is not $2 in the service environment ($4)" \
                   "add Environment=\"$1=$2\" to /etc/systemd/system/ollama.service.d/override.conf, then: sudo systemctl daemon-reload && sudo systemctl restart ollama"
            fi
        }
        chk_env OLLAMA_IGPU_ENABLE    1    warn "newer Ollama skips integrated GPUs without it"
        chk_env OLLAMA_FLASH_ATTENTION 1   warn "faster prompts, needed for a quantized KV cache"
        chk_env OLLAMA_KV_CACHE_TYPE  q8_0 warn "halves KV cache memory for ~1% speed"

        # what the running server actually picked, from its startup log
        LOG="$(journalctl -u ollama -b --no-pager 2>/dev/null | awk '/msg="server config"/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }')"
        if [ -z "${LOG}" ]; then
            info "cannot read the ollama journal (add yourself to group adm or systemd-journal to check the GPU it uses)"
        elif grep -q 'dropping integrated GPU' <<< "${LOG}" && ! grep -q 'inference compute.*library=\(ROCm\|Vulkan\)' <<< "${LOG}"; then
            fail "ollama dropped the iGPU and runs on the CPU only" "set OLLAMA_IGPU_ENABLE=1 as above"
        elif lib="$(grep -oE 'inference compute.*library=(ROCm|Vulkan)[^"]*name=[^ ]+' <<< "${LOG}" | grep -oE 'library=[A-Za-z]+|compute=[^ ]+' | paste -sd ' ' -)" && [ -n "${lib}" ]; then
            total="$(grep -oE 'inference compute.*library=(ROCm|Vulkan).*total="[^"]+"' <<< "${LOG}" | grep -oE 'total="[^"]+"' | head -1)"
            pass "ollama uses the GPU: ${lib} ${total}"
        else
            fail "ollama found no GPU (CPU only)" "check: journalctl -u ollama -b | grep -iE 'gpu|rocm|vulkan'"
        fi
    fi
fi

# ---------------------------------------------------------------------------------------------------------------------
section "Summary"
if [ "${N_FAIL}" -gt 0 ]; then
    printf '  %s%d failed%s, %d warnings\n' "${C_FAIL}" "${N_FAIL}" "${C_OFF}" "${N_WARN}"
    exit 1
fi
printf '  %sall checks passed%s, %d warnings\n' "${C_PASS}" "${C_OFF}" "${N_WARN}"
