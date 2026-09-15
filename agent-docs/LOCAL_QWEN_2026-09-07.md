# Local fine-tuned Qwen — installed and connected

> Historical snapshot (2026-09-07): this document describes the Saleh-host Qwen3.8 27B MLX conversion and serving snapshot. Present-tense configuration and hardware statements below are dated evidence, not the current host or runtime. The September 14 audit used Qwen3.5-9B MLX 6-bit on an Apple M5 Pro with 24 GB; local and remote loaded context must be verified separately. See current `HANDOFF.md` and the single colored audit report.

Owner explicitly approved conversion and server startup at01:41 +03. This is
the owner's existing fine-tune, not a newly downloaded base model. No cloud
service, public listener, credential change or automatic trade was enabled.

## Verified state

- Original: `/Users/saleh/models/salehman-qwen38-27b`, BF16, unchanged.
- Serving copy: `/Users/saleh/models/salehman-qwen38-27b-4bit`.
- Conversion: MLX affine4-bit/group64,4.501effective bits/weight including
  scales/non-quantized parameters;1847tensors,15shards,15.13GB tensor data.
- Converter reported peak RSS4.76GB. Sampled swap usage stayed9796.38MB before,
  during and after this work; these samples are not a full memory benchmark.
- Python: `/Users/saleh/Salehman-AI-wt/train/training/.venv/bin/python`;
  mlx0.32.2,mlx-lm0.31.3,transformers5.16.1. No packages installed/updated.
- Endpoint: `http://127.0.0.1:8765`, OpenAI-compatible.
- Exact model ID: `/Users/saleh/models/salehman-qwen38-27b-4bit`.
- Launch service: `com.swonyu.stocksage.qwen-local`, observed PID23631.
  Listener verified on127.0.0.1only. No login/reboot launch plist installed.
- Native StockSage Catalysts → Explanation model now uses Local server only,
  the URL/model above. Its real discovery probe reports the model present.

The installed MLX runtime lacks dispatch for `qwen3_5_text` (reproduced
ModuleNotFoundError/ValueError before loading weights). Its existing `qwen3_5`
implementation already accepts text-only configs, handles weight prefixes and
norm/conv transformations. The converter passes that dispatch override to
`load` in memory; it does NOT patch site-packages or the original config.
CPU lazy conversion uses the existing save pipeline with1GiB shards to bound
working memory. The12GiB conversion/20GiB serving MLX memory settings are
scheduling guidelines, NOT OS hard limits. No system memory limit was changed.

## Reproducible checks

From the coverage worktree:

```sh
/Users/saleh/Salehman-AI-wt/train/training/.venv/bin/python tools/convert_qwen_mlx.py --output /Users/saleh/models/salehman-qwen38-27b-4bit --check
```

Passed twice: all index/shard tensor names, byte totals and quantization config
agree. An attempted conversion to the existing output returned argparse exit2;
the subsequent check still passed. Original conversion exited0. Log:
`/private/tmp/stocksage-qwen-convert-20260907-0145.log` (suffix is an artifact ID;
conversion files were actually written around01:43).

At01:45 a bounded real HTTP smoke checked exact model discovery and generated
39tokens from65prompt tokens in16.57s. It correctly explained why a stale AAPL
quote needs refreshing, without thought tags. This is a plumbing check, not a
quality/financial-performance benchmark or a BF16-vs-quantized evaluation.

At01:47–01:49 the actual native Explain flow was exercised:

- PAA response was withheld by the existing foreign-number guard. Raw model
  response was not captured, so invented versus differently formatted numeric
  text was NOT diagnosed. No guard was weakened or retry-until-compliance added.
- SBLK response passed and rendered its63-day range, provided stop and cited
  Massive news source[1]. Backend was Local server only; server logs show the
  native discovery and completion requests. Actual data→prompt→Qwen→validation→UI
  succeeded. News/ratings/guidance/8-K observations also appeared in the native
  UI, but this does not certify every API route's full acceptance criteria.

One discovered UI follow-up: `StockSageCatalystNarrator.label(for:sourceCount:)`
omits the backend/model name when sources.count>0. Header configuration and the
selected local-only route were verified, but the cited paragraph footer itself
is generic. Do not claim a per-paragraph model label was fixed; it was not.

## Stop and restart

Stop the session-local server and release its model memory:

```sh
launchctl remove com.swonyu.stocksage.qwen-local
```

Restart only after checking the same job/port is not already in use:

```sh
launchctl submit -l com.swonyu.stocksage.qwen-local -o /private/tmp/stocksage-qwen-server-20260907-0145.log -e /private/tmp/stocksage-qwen-server-20260907-0145.err -- /usr/bin/env HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 /Users/saleh/Salehman-AI-wt/train/training/.venv/bin/python -u -c 'import mlx.core as mx; mx.set_cache_limit(512 << 20); mx.set_memory_limit(20 << 30); from mlx_lm.server import main; main()' --model /Users/saleh/models/salehman-qwen38-27b-4bit --host 127.0.0.1 --port 8765 --allowed-origins http://127.0.0.1:8765 --max-tokens 256 --temp 0 --chat-template-args '{"enable_thinking":false}' --decode-concurrency 1 --prompt-concurrency 1 --prefill-step-size 128 --prompt-cache-size 1 --prompt-cache-bytes 268435456
```

The first nohup attempt did not survive the command-session lifecycle (empty
log, no listener); native launchctl was used instead. This is a local developer
server: MLX explicitly warns it is not production-secure. Do not bind it to
0.0.0.0 or expose it over Tailscale/public internet without a separate secured
serving design. A phone's loopback is not this Mac; iPhone connectivity remains
pending. New native Chat/proactive Qwen briefing is also pending, not silently
supplied by the existing Catalysts connection. Deterministic price/fee/sizing/
gate logic remains separate from generated text.
