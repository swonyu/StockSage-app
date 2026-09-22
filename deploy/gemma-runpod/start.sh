#!/usr/bin/env bash
set -euo pipefail
umask 077

# RunPod injects only the public SSH key; no provider credential belongs in this image.
if [[ -z "${PUBLIC_KEY:-}" ]]; then
  echo 'StockSage: PUBLIC_KEY is required for the private SSH connection.' >&2
  exit 64
fi
if ! command -v nvidia-smi >/dev/null || ! nvidia-smi -L >/dev/null 2>&1; then
  echo 'StockSage: an NVIDIA GPU runtime is required; no model was downloaded.' >&2
  exit 69
fi

readonly expected='6f63619c9e33826a2a8ab195a344c79ecae7c82341d5567e28fd8863df056a7b'
readonly model_url='https://huggingface.co/lmstudio-community/gemma-4-31B-it-QAT-GGUF/resolve/12e5eae7a583b0a8bac91919fa99ae1fb27e6de4/gemma-4-31B-it-QAT-Q4_0.gguf'
model="${STOCKSAGE_MODEL_FILE:-/workspace/models/gemma.gguf}"
mkdir -p "$(dirname "$model")"
if [[ ! -f "$model" ]]; then
  available_kb=$(df -Pk "$(dirname "$model")" | awk 'END {print $4}')
  if (( available_kb < 22 * 1024 * 1024 )); then
    echo 'StockSage: at least 22 GiB free is required on the model volume.' >&2
    exit 73
  fi
  echo 'StockSage: downloading the pinned Gemma artifact to the mounted volume.'
  curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 30 --max-time 1800 --retry 3 \
    --output "$model.partial" "$model_url"
  printf '%s  %s\n' "$expected" "$model.partial" | sha256sum --check --status
  mv "$model.partial" "$model"
fi
if ! printf '%s  %s\n' "$expected" "$model" | sha256sum --check --status; then
  echo 'StockSage: model checksum mismatch; inference was not started.' >&2
  exit 65
fi

mkdir -p /root/.ssh /run/sshd
printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -l -f /root/.ssh/authorized_keys >/dev/null
ssh-keygen -A >/dev/null
unset PUBLIC_KEY

children=()
cleanup() {
  trap - EXIT TERM INT
  if (( ${#children[@]} )); then
    kill -TERM "${children[@]}" 2>/dev/null || true
    wait "${children[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

/usr/sbin/sshd -D -e -p 22 \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
  -o PermitRootLogin=prohibit-password -o AllowTcpForwarding=local \
  -o GatewayPorts=no -o PermitOpen=127.0.0.1:8080 -o PermitTunnel=no &
children+=("$!")

# The verified GGUF embeds the recorded chat template. The app owns temperature,
# schema and output budgets. Do not pin top_p/seed or replace the Gemma template here.
/app/llama-server --model "$model" --alias google/gemma-4-31b-qat \
  --host 127.0.0.1 --port 8080 --no-webui --jinja \
  --chat-template-kwargs '{"enable_thinking":false}' \
  --ctx-size 98304 --parallel 4 --no-kv-unified \
  --batch-size 8192 --ubatch-size 8192 --threads 16 \
  --cache-type-k f16 --cache-type-v f16 --flash-attn auto \
  --ctx-checkpoints 8 --cache-ram 0 --n-gpu-layers 999 --metrics &
children+=("$!")
echo 'StockSage: starting Gemma on private loopback; four slots, 24K context per slot.'
wait -n "${children[@]}"
