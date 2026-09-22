# StockSage Gemma RunPod image

Build target: `linux/amd64`, NVIDIA CUDA 13. No model weights, private keys,
provider credentials, broker connection, training or adapters are included.

## Reproducible identities

| Component | Pinned identity |
| --- | --- |
| Base | `ghcr.io/ggml-org/llama.cpp@sha256:a2f0d414ecca5b41e9d71e06e2df6dfa5260cc4e85c1b45fbf62c58e5ec28332` |
| Server | `0.4.1-dev`, build `11096`, commit `c550d2f60`; Linux x86_64 |
| Model | `lmstudio-community/gemma-4-31B-it-QAT-GGUF`, revision `12e5eae7a583b0a8bac91919fa99ae1fb27e6de4` |
| File | `gemma-4-31B-it-QAT-Q4_0.gguf`, 17,651,001,280 bytes |
| Weight SHA-256 | `6f63619c9e33826a2a8ab195a344c79ecae7c82341d5567e28fd8863df056a7b` |
| Embedded template SHA-256 | `6a1015c47ccfcfa67c3b772385bccee357a4d37c3cda37bd202e9047f391ab82` |
| App alias | `google/gemma-4-31b-qat` |

A bounded read of the pinned GGUF metadata verified the `gemma4` architecture,
833 tensors, 262,144 metadata context and the 18,682-byte embedded template hash.
The complete weight checksum is enforced on the pod before every server start;
the build does not download the entire model. The metadata context is not the
serving context: this launcher configures four slots of 24,576 tokens.

The latest base is **newer than the historical measured llama.cpp `8172e657`**.
The template hash matches that recorded in the living guide, but earlier B300
latencies and GPU-memory measurements do not validate this new binary. CUDA
inference, app readiness and throughput require a separately authorized GPU run.

## Build and save

From the repository root:

```sh
docker build --platform linux/amd64 -t stocksage-gemma:20260922 deploy/gemma-runpod
docker save stocksage-gemma:20260922 | gzip > stocksage-gemma-20260922.tar.gz
```

The build context includes only the Dockerfile and launcher. RunPod needs a
registry image reference; a local archive is not a deployed pod. Publish to an
authorized registry and record its immutable digest before creating a pod.

## RunPod configuration

- Choose an NVIDIA GPU with capacity for the model plus four 24K F16 KV slots.
  The old B300 profile used about 56 GiB; this image has not been GPU-measured.
- Mount persistent storage at `/workspace`; allow at least 22 GiB free before
  the first weight download. A 40 GiB or larger model volume leaves headroom.
- Set RunPod's `PUBLIC_KEY` to the owner's SSH public key. No private key goes
  in the image or environment. The launcher refuses missing keys or no GPU.
- Expose **22/tcp only**. Inference listens on `127.0.0.1:8080` inside the pod.
  Do not publish port 8080 through an HTTP proxy or public TCP mapping.
- Start/stop a paid pod only under a current explicit owner request and budget.
  An app quit or SSH disconnect does not stop RunPod billing.

With the actual mapped SSH host/port and owner key, establish:

```sh
ssh -N -L 127.0.0.1:18080:127.0.0.1:8080 \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 -i OWNER_PRIVATE_KEY -p POD_SSH_PORT root@POD_HOST
```

Verify the SSH host key through the trusted RunPod deployment; do not disable
host-key checking. Set StockSage to `http://127.0.0.1:18080`, canonical alias
above. Read `/health`, `/v1/models` and `/props` before declaring ready. The app
requires exact model identity, awake verified context and supported worker count.
No completion request, research scan or trade is implied by a metadata check.

The launcher retains the embedded Jinja template with thinking off, F16 caches,
separate KV, 8,192 batch/microbatch, eight checkpoints and no RAM prompt cache.
The app still owns temperature, schema and output budgets. No `top_p` or seed
override is added. SSH and the model server stop together when either exits.

References: [official llama.cpp Docker images](https://github.com/ggml-org/llama.cpp/blob/master/docs/docker.md),
[RunPod SSH setup](https://docs.runpod.io/pods/configuration/use-ssh).
