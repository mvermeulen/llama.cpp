# llama.cpp vs Ollama on a Radeon RX 6900 XT

Measured 2026-11-20 on llama.cpp `a946eb541` (b12431) and Ollama 0.40.16.

## System

- CPU: AMD Ryzen 9 5950X (16 cores, Zen 3, AVX2), 64 GB RAM
- GPU: AMD Radeon RX 6900 XT (Navi 21, gfx1030, 16 GiB), PCIe 4.0 x16
- ROCm 10.2 (HIP 7.17), Mesa 26.0.8 RADV, Ubuntu 26.04, kernel 7.0
- Power profile: performance

## Builds

```sh
./scripts/check-radeon.sh          # read-only setup check
./scripts/build-radeon-vulkan.sh   # -> build-vulkan
./scripts/build-radeon.sh          # -> build-rocm (ROCm/HIP, gfx1030)
```

Both engines ran the same GGUF files, taken from the Ollama blob store.

## Ollama is llama.cpp

Ollama 0.40 runs a bundled `llama-server` (ROCm build) with `--flash-attn auto -b 1024 -ub 1024`. That's why its numbers track the llama.cpp ROCm build closely, and why `OLLAMA_FLASH_ATTENTION=1` changed nothing (measured on 4 models).

## End-to-end (llama-server vs Ollama API)

The prompt is about 2.5-2.9K tokens, followed by 256 generated tokens, at ctx 16384. Each result is the mean of 3 runs after a warm-up. llama.cpp ran with `-ngl 99 -fa on -ub 2048 -b 2048`. Raw data: [data/server_vs_ollama.csv](data/server_vs_ollama.csv).

| model                  | Ollama pp / tg | llama.cpp Vulkan pp / tg | llama.cpp ROCm pp / tg |
| ---------------------- | -------------: | -----------------------: | ---------------------: |
| llama3.2 3B Q4_K_M     |  3354 / 129.1  |  3440 / **139.3**        |  3363 / 125.8          |
| qwen3 4B Q4_K_M        |  2575 / 102.7  |  2557 / **111.7**        |  2615 / 102.1          |
| qwen2.5-coder 7B Q4_K_M|  1668 / 80.9   |  1728 / **83.8**         |  1718 / 81.9           |
| qwen3.5 9B Q4_K_M      |  1394 / 61.4   |  1539 / **69.0**         |  1448 / 63.5           |
| mistral-nemo 12B Q4_0  |  1383 / 54.4   |  1277 / **55.9**         |  1353 / 54.0           |
| gemma4 12B Q4_K_M      |   820 / 88.0 * |   939 / 45.1             |   847 / 39.8           |

\* Ollama's gemma4:12b ships a `gemma4-assistant` draft model and runs speculative decoding (`--spec-type draft-mtp --spec-draft-n-max 3`). With the same draft, llama.cpp is ahead:

| gemma4 12B + assistant draft          | pp tok/s | tg tok/s |
| ------------------------------------- | -------: | -------: |
| Ollama (n-max 3)                      |      820 |     88.0 |
| llama.cpp Vulkan, n-max 3             |      940 |     90.0 |
| llama.cpp Vulkan, n-max 4             |      938 | **97.6** |
| llama.cpp ROCm, n-max 3               |      850 |     80.0 |

Ornith-1.5-9B has a built-in MTP head that Ollama doesn't use:

| Ornith-1.5 9B Q4_K_M                  | pp tok/s | tg tok/s |
| ------------------------------------- | -------: | -------: |
| Ollama                                |     1396 |     63.2 |
| llama.cpp Vulkan                      |     1540 |     69.1 |
| llama.cpp Vulkan `--spec-type draft-mtp` | 1442 | **115.2** |

Draft acceptance was about 65-75% for both models. A draft length of 3 is best for Ornith and 4 for gemma4. `--spec-draft-backend-sampling` made no difference.

## llama-bench sweep

All runs use `-ngl 99 -fa 1 -b 2048`, 3 repetitions. Raw data: [data/llama_bench.csv](data/llama_bench.csv).

- Vulkan generates 4-14% faster than ROCm on every model (tg128).
- Prompt speed is mixed. Vulkan is a little faster at pp512. ROCm is faster at pp4096 on Q4_0 mistral-nemo (+9%) and qwen3-4b (+8%), and at depth: pp2048 at 16K context is 932 vs 802 tok/s (+16%, qwen2.5-coder 7B).
- `-ub 2048` vs 512: +1-5% at pp4096, no change in generation.
- Flash attention: ROCm pp4096 went from 1198 to 2518 tok/s on qwen3-4b, and from 811 to 1331 tok/s on mistral-nemo. Always use `-fa on`.
- q8_0 KV cache ([data/kv_cache.csv](data/kv_cache.csv)): -1% to -4% generation at short context, about 0% at 16K depth. Halves KV memory, which matters with 16 GiB.

## Recommendations

- Default to the Vulkan build: `-ngl 99 -fa on -ub 2048 -b 2048`.
- For long-context, prompt-heavy work (RAG, summarizing 16K+ prompts), use the ROCm build.
- Use speculative decoding where a model provides it:
  - an MTP head: `--spec-type draft-mtp`
  - the gemma4 assistant draft: `--spec-type draft-mtp -md <assistant.gguf> -ngld 99 --spec-draft-n-max 4`
- `scripts/bench-vs-ollama.py` prints a note when an Ollama model uses a draft model, so the comparison stays fair.
