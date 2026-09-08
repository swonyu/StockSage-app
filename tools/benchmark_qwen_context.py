#!/usr/bin/env python3
"""Benchmark synthetic context against the existing loopback MLX server; never load weights.

Run with the Python environment already serving Qwen. Only the local tokenizer is loaded.
Reports measured token counts, latency, process RSS and macOS physical footprint.
"""
import argparse
import json
import subprocess
import threading
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--contexts", nargs="+", type=int, default=[4096, 16384, 32768])
    args = parser.parse_args()
    assert all(2048 < size <= 32768 for size in args.contexts)
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True, trust_remote_code=False)
    filler = tokenizer.encode("These synthetic notes describe ordinary office tasks, calendar reviews, and document filing. " * 6000,
                              add_special_tokens=False)
    for size in args.contexts:
        target = size - 2048  # Reserve the same response budget as the app.
        def messages(n):
            return [
                {"role": "system", "content": "Read the synthetic records. Return only the three checkpoint words in order."},
                {"role": "user", "content": f"Independent benchmark {size}. First checkpoint: CEDAR.\n"
                 + tokenizer.decode(filler[:n // 2]) + "\nMiddle checkpoint: MARBLE.\n"
                 + tokenizer.decode(filler[n // 2:n]) + "\nLast checkpoint: LANTERN.\nWhat are the three checkpoint words?"},
            ]
        n = target - 100
        for _ in range(8):
            request_messages = messages(n)
            rendered = tokenizer.apply_chat_template(request_messages, tokenize=False,
                                                     add_generation_prompt=True, enable_thinking=False)
            token_count = len(tokenizer.encode(rendered, add_special_tokens=False))
            if target - 4 <= token_count <= target:
                break
            n += target - token_count
        assert target - 4 <= token_count <= target, token_count
        body = json.dumps({"model": args.model, "messages": request_messages, "max_tokens": 2048,
                           "temperature": 0, "stream": True, "stream_options": {"include_usage": True},
                           "chat_template_kwargs": {"enable_thinking": False}}).encode()
        request = urllib.request.Request("http://127.0.0.1:8765/v1/chat/completions", data=body,
                                        headers={"Content-Type": "application/json"})
        done, peak_rss = threading.Event(), [0]
        def sample_rss():
            while not done.is_set():
                result = subprocess.run(["ps", "-p", str(args.pid), "-o", "rss="], capture_output=True, text=True)
                if result.returncode == 0 and result.stdout.strip():
                    peak_rss[0] = max(peak_rss[0], int(result.stdout.strip()) * 1024)
                done.wait(0.5)
        monitor = threading.Thread(target=sample_rss, daemon=True)
        monitor.start()
        started = time.monotonic()
        first, output, usage, finish = None, "", None, None
        print(json.dumps({"event": "start", "context_budget": size, "input_tokens": token_count}), flush=True)
        try:
            with urllib.request.urlopen(request, timeout=240) as response:
                for raw in response:
                    if time.monotonic() - started > 300:
                        raise TimeoutError("Benchmark exceeded five minutes")
                    if not raw.startswith(b"data: "):
                        continue
                    if raw.strip() == b"data: [DONE]":
                        break
                    event = json.loads(raw[6:])
                    usage = event.get("usage") or usage
                    for choice in event.get("choices", []):
                        content = choice.get("delta", {}).get("content") or ""
                        if content and first is None:
                            first = time.monotonic() - started
                        output += content
                        finish = choice.get("finish_reason") or finish
        finally:
            done.set()
            monitor.join()
        elapsed = time.monotonic() - started
        footprint = subprocess.run(["vmmap", "-summary", str(args.pid)], capture_output=True, text=True, timeout=20)
        report = {"context_budget": size, "input_tokens": token_count, "usage": usage,
                  "first_token_seconds": first, "elapsed_seconds": elapsed, "peak_rss_bytes": peak_rss[0],
                  "physical_footprint": [line.strip() for line in footprint.stdout.splitlines() if "Physical footprint" in line],
                  "finish_reason": finish, "response": output}
        print(json.dumps(report), flush=True)
        assert usage and usage["prompt_tokens"] == token_count, report
        assert usage["total_tokens"] <= size and finish == "stop", report
        words = [word for word in ["CEDAR", "MARBLE", "LANTERN"] if word in output]
        assert len(words) == 3 and output.index(words[0]) < output.index(words[1]) < output.index(words[2]), report


if __name__ == "__main__":
    main()
