#!/usr/bin/env python3
"""Import explicitly supplied WhatsApp exports as private, unverified retrieval leads.

No network, model training, archive extraction, sender identifiers or repository data.
Dates in these exports lack an offset; --timezone is an explicit interpretation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from datetime import datetime, timezone
from zipfile import ZipFile
from zoneinfo import ZoneInfo

HEADER = re.compile(r"^\[(\d{1,2}/\d{1,2}/\d{2}, \d{1,2}:\d{2}:\d{2} [AP]M)\] (.*)$")
SECRET = re.compile(r"\b(?:sk-[\w-]{12,}|hf_[\w]{16,}|gh[oprsu]_[\w]{16,}|Bearer\s+\S+)|-----BEGIN .*PRIVATE KEY", re.I)


def scrub(text):
    if SECRET.search(text):
        return "[Message omitted: credential-like content]"
    text = re.sub(r"https?://\S+|www\.\S+", "[link omitted]", text)
    text = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[email omitted]", text)
    text = re.sub(r"\+\d[\d ()-]{7,}\d", "[phone omitted]", text)
    text = " ".join(text.replace("\u200e", "").split())
    if len(text) > 2400:
        text = text[:2400].rsplit(" ", 1)[0] + " [excerpt truncated]"
    return text


def parse_export(text, source, tz):
    messages, current = [], None

    def finish():
        if current:
            body = scrub("\n".join(current[1]))
            if body and body != "<image omitted>":
                date = current[0].astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
                ident = hashlib.sha256((source + date + body).encode()).hexdigest()
                messages.append({"id": ident, "date": date, "source": source, "text": body})

    for line in text.splitlines():
        match = HEADER.match(line.lstrip("\ufeff\u200e"))
        if match:
            finish()
            current = None
            rest = match[2]
            # System notifications are not research, and senders are deliberately discarded.
            if rest.startswith("- ") or ": " not in rest:
                continue
            date = datetime.strptime(match[1], "%m/%d/%y, %I:%M:%S %p").replace(tzinfo=tz)
            current = (date, [rest.split(": ", 1)[1]])
        elif current:
            current[1].append(line)
    finish()
    return messages


def selfcheck():
    sample = "[9/3/26, 10:00:00 PM] +12345678901: QCOM above $168\nSecond line.\n[9/3/26, 10:01:00 PM] - group changed\n[9/3/26, 10:02:00 PM] Person: AMZN contact a@b.com https://example.com +12345678901"
    rows = parse_export(sample, "fixture", ZoneInfo("Asia/Riyadh"))
    assert len(rows) == 2 and rows[0]["date"] == "2026-09-03T19:00:00Z"
    assert "Second line" in rows[0]["text"] and "$168" in rows[0]["text"]
    assert not any(s in json.dumps(rows) for s in ["12345678901", "a@b.com", "https://", "Person"])
    assert "omitted" in scrub("Bearer fixture-not-a-real-key")
    assert "truncated" in scrub("word " * 1000)
    print("WhatsApp import self-check ok")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", nargs="*", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--timezone", default="Asia/Riyadh")
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--demo", action="store_true")
    args = parser.parse_args()
    if args.demo:
        selfcheck()
        return
    if not args.archives or not args.output:
        parser.error("provide explicit archive paths and --output")
    if args.output.exists() and not args.replace:
        parser.error("output exists; use --replace only for an intentional refresh")
    tz, messages, sources = ZoneInfo(args.timezone), [], []
    for archive in args.archives:
        with ZipFile(archive) as bundle:
            entries = [e for e in bundle.infolist() if e.filename == "chat.txt"]
            if len(entries) != 1 or entries[0].file_size > 5_000_000 or entries[0].flag_bits & 1:
                parser.error("requires one unencrypted chat.txt of at most 5 MB; no files extracted")
            raw = bundle.read(entries[0])
        rows = parse_export(raw.decode("utf-8-sig"), archive.stem, tz)
        if not rows:
            parser.error("no supported timestamped messages found")
        messages.extend(rows)
        sources.append({"name": archive.stem, "sha256": hashlib.sha256(raw).hexdigest(), "messages": len(rows)})
    if len(messages) > 10_000:
        parser.error("10,000-message import ceiling; split larger exports")
    document = {"schema": 1, "importedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
                "timezone": args.timezone + " (assumed export timezone)", "sources": sources, "messages": messages}
    payload = json.dumps(document, ensure_ascii=False).encode()
    if len(payload) > 5_000_000:
        parser.error("5 MB private index ceiling exceeded")
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".whatsapp-", dir=args.output.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        if args.replace:
            os.replace(temporary, args.output)
        else:
            try:
                # Same-directory hard link publishes the complete 0600 file without clobbering.
                os.link(temporary, args.output)
            except FileExistsError:
                parser.error("output appeared during import; preserved it (use --replace for an intentional refresh)")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Imported {len(messages)} messages from {len(sources)} exports; private snapshot only, no network/training.")


if __name__ == "__main__":
    main()
