#!/usr/bin/env python3
# Compare prompt-processing and generation speed of local llama-server builds against Ollama.
#
# Every engine gets the same chat prompt with a unique prefix per run, so no prompt cache can be reused.
# Engines run one at a time: each llama-server is started, measured and stopped, and each Ollama model is
# unloaded after use.
#
# Example:
#   ./scripts/bench-vs-ollama.py --gguf ~/models/gpt-oss-20b-Q8_0.gguf --ollama-model gpt-oss:20b

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def post(url, body, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def make_prompt(path, n_chars):
    with open(path, errors="replace") as f:
        text = f.read()[:n_chars]
    return "Summarize the following document in a few short paragraphs.\n\n" + text


def measure(run_once, prompt, runs):
    # first call is a warm-up: model load, shader/kernel compile
    run_once("warm-up %f\n\n%s" % (time.time(), prompt))
    pp, tg = [], []
    for i in range(runs):
        pn, pms, gn, gms = run_once("run %d %f\n\n%s" % (i, time.time(), prompt))
        pp.append(pn / pms * 1000)
        tg.append(gn / gms * 1000)
        print("    run %d: prompt %d tok @ %.1f tok/s, gen %d tok @ %.2f tok/s" % (i + 1, pn, pp[-1], gn, tg[-1]), file=sys.stderr)
    return {"prompt_tokens": pn, "pp": pp, "tg": tg}


def bench_ollama(args, model, prompt):
    host = args.ollama_host.rstrip("/")

    def run_once(p):
        d = post(host + "/api/chat", {
            "model": model, "stream": False,
            "messages": [{"role": "user", "content": p}],
            "options": {"num_ctx": args.ctx, "num_predict": args.n_predict, "temperature": 0, "seed": 1},
        }, args.timeout)
        return d["prompt_eval_count"], d["prompt_eval_duration"] / 1e6, d["eval_count"], d["eval_duration"] / 1e6

    try:
        res = measure(run_once, prompt, args.runs)
        # size_vram / size tells if Ollama put the model on the GPU
        # /api/ps reports a model without a tag as "<name>:latest"
        full_name = model if ":" in model else model + ":latest"
        where = "?"
        for m in get(host + "/api/ps").get("models", []):
            if full_name in (m.get("name"), m.get("model")):
                gpu = m.get("size_vram", 0) / max(m.get("size", 1), 1)
                where = "CPU" if gpu < 0.01 else "GPU %.0f%%" % (gpu * 100)
        res["device"] = where
        return res
    finally:
        try:
            post(host + "/api/generate", {"model": model, "keep_alive": 0}, 60)
        except (urllib.error.URLError, OSError):
            pass


def bench_llama(args, server_bin, extra, prompt, log_path):
    host = "http://127.0.0.1:%d" % args.port
    cmd = [server_bin, "-m", args.gguf, "-c", str(args.ctx), "-fa", "on", "--jinja",
           "--host", "127.0.0.1", "--port", str(args.port)] + extra
    print("    %s" % " ".join(cmd), file=sys.stderr)
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    try:
        deadline = time.time() + args.timeout
        while True:
            if proc.poll() is not None:
                raise RuntimeError("llama-server exited with code %d, see %s" % (proc.returncode, log_path))
            try:
                if get(host + "/health", 2).get("status") == "ok":
                    break
            except (urllib.error.URLError, OSError, ValueError):
                pass
            if time.time() > deadline:
                raise RuntimeError("llama-server not ready after %ds, see %s" % (args.timeout, log_path))
            time.sleep(0.5)

        def run_once(p):
            d = post(host + "/v1/chat/completions", {
                "stream": False, "cache_prompt": False, "max_tokens": args.n_predict,
                "temperature": 0, "seed": 1,
                "messages": [{"role": "user", "content": p}],
            }, args.timeout)
            t = d["timings"]
            return t["prompt_n"], t["prompt_ms"], t["predicted_n"], t["predicted_ms"]

        return measure(run_once, prompt, args.runs)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()


def default_llama_configs():
    # recommended GPU settings for Ryzen AI APUs, see scripts/build-ryzen-ai*.sh
    gpu = ["-ngl", "99", "-ub", "2048", "-b", "2048"]
    configs = []
    vulkan = os.path.join(ROOT_DIR, "build-vulkan", "bin", "llama-server")
    rocm = os.path.join(ROOT_DIR, "build-rocm", "bin", "llama-server")
    if os.access(vulkan, os.X_OK):
        configs.append(("llama.cpp vulkan (GPU)", vulkan, gpu))
    if os.access(rocm, os.X_OK):
        configs.append(("llama.cpp rocm (GPU)", rocm, gpu))
    if configs:
        configs.append(("llama.cpp (CPU only)", configs[0][1], ["-ngl", "0", "--device", "none"]))
    return configs


def fmt(values):
    if len(values) > 1:
        return "%.1f ± %.1f" % (statistics.mean(values), statistics.stdev(values))
    return "%.1f" % values[0]


def main():
    ap = argparse.ArgumentParser(description="Compare llama-server builds against Ollama on the same prompt.")
    ap.add_argument("--gguf", help="GGUF file for the llama-server runs (skip llama.cpp runs if not given)")
    ap.add_argument("--ollama-model", action="append", default=[], help="Ollama model to run (repeatable)")
    ap.add_argument("--server", action="append", default=[], metavar="NAME=PATH[:ARGS]",
                    help="llama-server to run instead of the auto-detected build-vulkan/build-rocm ones (repeatable), "
                         "e.g. 'upstream=~/.local/share/wspy/llama.cpp/current/llama-server:-ngl 99'")
    ap.add_argument("--no-cpu", action="store_true", help="skip the auto-detected CPU-only llama.cpp run")
    ap.add_argument("--prompt-file", default=os.path.join(ROOT_DIR, "README.md"), help="text used as the prompt body (default: %(default)s)")
    ap.add_argument("--prompt-chars", type=int, default=7500, help="characters taken from --prompt-file, ~4 per token (default: %(default)s)")
    ap.add_argument("-n", "--n-predict", type=int, default=256, help="tokens to generate per run (default: %(default)s)")
    ap.add_argument("-r", "--runs", type=int, default=3, help="measured runs per engine, after one warm-up (default: %(default)s)")
    ap.add_argument("-c", "--ctx", type=int, default=16384, help="context size for every engine (default: %(default)s)")
    ap.add_argument("--port", type=int, default=18100, help="port for the llama-server runs (default: %(default)s)")
    ap.add_argument("--ollama-host", default="http://localhost:11434")
    ap.add_argument("--timeout", type=int, default=900, help="per-request and server-start timeout in seconds (default: %(default)s)")
    ap.add_argument("--json", help="also write all results to this file")
    ap.add_argument("--log-dir", default="/tmp", help="where llama-server logs go (default: %(default)s)")
    args = ap.parse_args()

    if args.gguf:
        args.gguf = os.path.expanduser(args.gguf)
        if not os.path.isfile(args.gguf):
            ap.error("--gguf %r not found" % args.gguf)

    llama_configs = []
    if args.gguf:
        if args.server:
            for spec in args.server:
                name, _, rest = spec.partition("=")
                path, _, extra = rest.partition(":")
                llama_configs.append((name, os.path.expanduser(path), extra.split()))
        else:
            llama_configs = default_llama_configs()
            if args.no_cpu:
                llama_configs = [c for c in llama_configs if "CPU" not in c[0]]
            if not llama_configs:
                print("warning: no build-vulkan or build-rocm llama-server found, pass --server", file=sys.stderr)

    if not llama_configs and not args.ollama_model:
        ap.error("nothing to run: pass --gguf and/or --ollama-model")

    prompt = make_prompt(args.prompt_file, args.prompt_chars)
    results = []

    for model in args.ollama_model:
        name = "ollama %s" % model
        print("== %s" % name, file=sys.stderr)
        try:
            res = bench_ollama(args, model, prompt)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print("    failed: %s" % e, file=sys.stderr)
            continue
        results.append(dict(res, name=name))

    for name, server_bin, extra in llama_configs:
        print("== %s" % name, file=sys.stderr)
        log_path = os.path.join(args.log_dir, "bench-vs-ollama-%s.log" % "".join(ch if ch.isalnum() else "_" for ch in name))
        try:
            res = bench_llama(args, server_bin, extra, prompt, log_path)
        except (RuntimeError, urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print("    failed: %s" % e, file=sys.stderr)
            continue
        results.append(dict(res, name=name, device="CPU" if "--device" in extra else "GPU"))

    if not results:
        return 1

    print()
    print("%d tokens generated, %d runs each after a warm-up, ctx %d" % (args.n_predict, args.runs, args.ctx))
    print()
    w = max(len(r["name"]) for r in results)
    print("| %-*s | %-8s | %10s | %18s | %18s |" % (w, "engine", "device", "prompt tok", "prompt tok/s", "gen tok/s"))
    print("| %s | %s | %s | %s | %s |" % ("-" * w, "-" * 8, "-" * 9 + ":", "-" * 17 + ":", "-" * 17 + ":"))
    for r in results:
        print("| %-*s | %-8s | %10d | %18s | %18s |" % (w, r["name"], r["device"], r["prompt_tokens"], fmt(r["pp"]), fmt(r["tg"])))

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"gguf": args.gguf, "n_predict": args.n_predict, "ctx": args.ctx, "results": results}, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
