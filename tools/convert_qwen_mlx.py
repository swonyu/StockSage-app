#!/usr/bin/env python3
"""Convert the owner's local text-only Qwen checkpoint; never download or overwrite.

Run with the existing training venv. --check validates the saved index/schema
without evaluating the full model; a real generation is still required afterward.
"""
import argparse
from functools import partial
import json
import os
from pathlib import Path
import resource

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"


def check(path):
    import mlx.core as mx

    config = json.loads((path / "config.json").read_text())
    assert config["model_type"] == "qwen3_5"
    assert config["quantization"]["bits"] == 4
    assert config["quantization"]["group_size"] == 64
    index = json.loads((path / "model.safetensors.index.json").read_text())
    expected = index["weight_map"]
    actual = {}
    byte_count = 0
    for filename in sorted(set(expected.values())):
        assert Path(filename).name == filename
        weights = mx.load(str(path / filename))  # lazy metadata read, no evaluation
        assert not (actual.keys() & weights.keys())
        actual.update({name: filename for name in weights})
        byte_count += sum(weight.nbytes for weight in weights.values())
    assert actual == expected and byte_count == index["metadata"]["total_size"]
    assert any(name.endswith(".scales") for name in actual)
    print(f"CHECK OK: {len(actual)} tensors, {len(set(actual.values()))} shards, "
          f"{byte_count / 1e9:.2f} GB tensor data", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        check(args.output)
        return
    if args.source is None or not args.source.is_dir() or args.output.exists():
        parser.error("source must exist locally and output must not already exist")
    config = json.loads((args.source / "config.json").read_text())
    if config.get("model_type") != "qwen3_5_text" or config.get("quantization"):
        parser.error("expected an unquantized qwen3_5_text checkpoint")

    import mlx.core as mx
    from mlx_lm import utils

    mx.set_default_device(mx.cpu)
    mx.set_cache_limit(256 << 20)
    # A scheduling guideline, not an OS hard cap; monitor process RSS as well.
    mx.set_memory_limit(12 << 30)
    # Existing loader already handles text-only config, prefixes and norm/conv
    # conversion. Override its dispatch label in memory, never the original file.
    print("Loading local checkpoint lazily (original remains unchanged)", flush=True)
    model, tokenizer, config = utils.load(
        str(args.source), lazy=True, return_config=True,
        model_config={"model_type": "qwen3_5"},
        tokenizer_config={"trust_remote_code": False},
    )
    model, config = utils.quantize_model(model, config, group_size=64, bits=4)
    # ponytail: process-local override of the installed writer's 5-GiB default;
    # remove when the upstream save API accepts a shard-size argument directly.
    utils.make_shards = partial(utils.make_shards, max_file_size_gb=1)
    print("Writing 1-GiB shards", flush=True)
    utils.save(args.output, args.source, model, tokenizer, config)
    check(args.output)
    print(f"Peak RSS: {resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9:.2f} GB",
          flush=True)


if __name__ == "__main__":
    main()
