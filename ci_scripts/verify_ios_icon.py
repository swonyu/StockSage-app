#!/usr/bin/env python3
"""Check the actual compiled primary iOS icon, including its 1024px rendition.

Run on a completed .xcarchive before delivery. The Assets.car Opaque field is
intentional: actool can encode an entirely opaque image as ARGB, so Encoding
alone does not tell us whether the archived icon contains transparency.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_catalog(catalog, icon_name, required_idioms):
    result = subprocess.run(
        ["xcrun", "assetutil", "--info", str(catalog)],
        capture_output=True, text=True, timeout=60, check=True,
    )
    rows = json.loads(result.stdout)
    require(isinstance(rows, list), "assetutil did not return an asset list")
    icons = [row for row in rows if isinstance(row, dict)
             and row.get("AssetType") == "Icon Image"
             and row.get("Name") == icon_name
             and row.get("Idiom") in {"phone", "pad", "universal"}]
    require(icons, "No compiled primary iOS icon was found")
    errors = []
    for row in icons:
        identity = f"{row.get('Idiom')} {row.get('PixelWidth')}x{row.get('PixelHeight')} {row.get('RenditionName')}"
        if row.get("Opaque") is not True:
            errors.append(identity + ": compiled icon is not marked opaque")
        if row.get("ColorModel") != "RGB":
            errors.append(identity + ": expected RGB colour model")
    large = [row for row in icons if row.get("PixelWidth") == 1024
             and row.get("PixelHeight") == 1024]
    for idiom in required_idioms:
        if not any(row.get("Idiom") in {idiom, "universal"} for row in large):
            errors.append("Missing 1024x1024 primary icon for " + idiom)
    return {
        "assets_sha256": hashlib.sha256(catalog.read_bytes()).hexdigest(),
        "icon_name": icon_name,
        "required_idioms": sorted(required_idioms),
        "compiled_icons": [{key: row.get(key) for key in (
            "Name", "Idiom", "RenditionName", "PixelWidth", "PixelHeight",
            "Opaque", "ColorModel", "Colorspace", "Encoding", "BitsPerComponent",
        )} for row in icons],
        "errors": errors,
        "status": "PASSED" if not errors else "FAILED",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--archive", type=Path)
    group.add_argument("--catalog", type=Path, help="Inspect an extracted actual Assets.car for a rejection regression")
    parser.add_argument("--expected-bundle-id")
    parser.add_argument("--icon-name", default="AppIcon")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        if args.archive:
            apps = sorted((args.archive / "Products" / "Applications").glob("*.app"))
            require(len(apps) == 1, "Expected exactly one main application in archive")
            app = apps[0]
            with (app / "Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "Archive is not an iPhoneOS application")
            identifier = info.get("CFBundleIdentifier")
            require(args.expected_bundle_id is not None, "Archive checks require --expected-bundle-id")
            require(identifier == args.expected_bundle_id, "Unexpected archived app identifier")
            families = set(info.get("UIDeviceFamily", []))
            require(families and families.issubset({1, 2}), "Unknown or missing iOS device family")
            names = []
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                name = info.get(key, {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
                if name:
                    names.append(name)
            require(names and len(set(names)) == 1, "Missing or inconsistent primary icon names")
            require(names[0] == args.icon_name, "Unexpected primary icon catalogue")
            report = validate_catalog(app / "Assets.car", names[0],
                                      {"phone" if family == 1 else "pad" for family in families})
            report.update({"archive": str(args.archive), "bundle_id": identifier,
                           "version": info.get("CFBundleShortVersionString"),
                           "build": info.get("CFBundleVersion")})
        else:
            report = validate_catalog(args.catalog, args.icon_name, {"phone", "pad"})
            report["catalog_only"] = True
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        report = {"status": "FAILED", "errors": [str(error)]}
    report["scope"] = "Compiled primary icon opacity only; no signing, processing, review or release certification"
    encoded = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(encoded)
    print(encoded, end="")
    return 0 if report["status"] == "PASSED" else 1


if __name__ == "__main__":
    sys.exit(main())
