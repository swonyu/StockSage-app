# Official CUDA 13 server, resolved on 2026-09-22. Build only linux/amd64 for RunPod.
FROM ghcr.io/ggml-org/llama.cpp@sha256:a2f0d414ecca5b41e9d71e06e2df6dfa5260cc4e85c1b45fbf62c58e5ec28332
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server ca-certificates \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /workspace/models /opt/stocksage
COPY start.sh /opt/stocksage/start.sh
RUN chmod 755 /opt/stocksage/start.sh && bash -n /opt/stocksage/start.sh
LABEL org.opencontainers.image.title="StockSage Gemma 4 31B RunPod" \
      org.opencontainers.image.source="https://github.com/swonyu/StockSage-app" \
      org.opencontainers.image.description="Pinned Gemma QAT weights; private SSH-only inference; no bundled credentials or weights"
ENV STOCKSAGE_MODEL_FILE=/workspace/models/gemma.gguf
EXPOSE 22
HEALTHCHECK --interval=30s --timeout=5s --start-period=30m --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health >/dev/null || exit 1
ENTRYPOINT ["/opt/stocksage/start.sh"]
