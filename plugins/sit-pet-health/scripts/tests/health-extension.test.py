#!/usr/bin/env python3
"""End-to-end deterministic test for private RousePet health extensions."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


PLUGIN_ROOT = Path(__file__).resolve().parents[2]
PREPARE = PLUGIN_ROOT / "scripts" / "prepare-health-extension.py"
FINALIZE = PLUGIN_ROOT / "scripts" / "finalize-health-extension.py"
RECORD = PLUGIN_ROOT / "vendor" / "hatch-pet" / "scripts" / "record_imagegen_result.py"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args: object, expect_ok: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([sys.executable, *(str(item) for item in args)], text=True, capture_output=True)
    if expect_ok and result.returncode != 0:
        raise AssertionError(f"command failed: {result.stderr or result.stdout}")
    return result


def make_source_sheet(path: Path) -> None:
    sheet = Image.new("RGBA", (1536, 1872), (0, 0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    for column in range(6):
        left = column * 192
        draw.rounded_rectangle((left + 48, 34, left + 144, 184), radius=28, fill=(250, 190, 75, 255), outline=(55, 45, 40, 255), width=5)
        draw.ellipse((left + 72, 75, left + 84, 91), fill=(20, 95, 70, 255))
        draw.ellipse((left + 109, 75, left + 121, 91), fill=(20, 95, 70, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path)


def make_generated_strip(path: Path, key: tuple[int, int, int], action_index: int) -> None:
    strip = Image.new("RGB", (1152, 208), key)
    draw = ImageDraw.Draw(strip)
    for frame in range(6):
        left = frame * 192
        top = 40 + action_index * 8 + (frame % 2) * 3
        draw.rounded_rectangle((left + 50, top, left + 142, 184), radius=25, fill=(250, 190 - action_index * 18, 75, 255), outline=(55, 45, 40, 255), width=5)
        draw.ellipse((left + 74, top + 42, left + 86, top + 56), fill=(20, 95, 70, 255))
        draw.ellipse((left + 108, top + 42, left + 120, top + 56), fill=(20, 95, 70, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    strip.save(path)


def main() -> None:
    root = Path(tempfile.mkdtemp(prefix="rousepet-health-extension-"))
    try:
        plugin_data = root / "plugin-data"
        clone = plugin_data / "pets" / "fixture-health-12345678"
        source = clone / "source-spritesheet.png"
        make_source_sheet(source)
        shutil.copy2(source, clone / "spritesheet.png")
        source_hash = sha256(source)
        write_json(clone / "source-pet.json", {"id": "fixture", "displayName": "Fixture"})
        write_json(
            clone / "health-profile.json",
            {
                "version": 3,
                "actionLayoutId": "fixture",
                "sourceSlug": "fixture",
                "sourceDisplayName": "Fixture",
                "sourceSpriteSha256": source_hash,
                "sourceManifestSha256": sha256(clone / "source-pet.json"),
                "stages": {str(level): {"file": f"atlases/stage-{level}.png", "semanticAction": "idle", "frames": 1, "durationMs": 1000} for level in range(5)},
                "healthExtension": {"version": 1, "status": "required", "actions": [{"semantic": action, "stage": stage} for action, stage in [("tired", 2), ("sick", 3), ("rest", 4)]]},
            },
        )

        prepared = json.loads(run(PREPARE, "--clone-dir", clone).stdout)
        assert prepared["required"] and prepared["actions"] == ["tired", "sick", "rest"]
        run_dir = Path(prepared["run_dir"])
        request = json.loads((run_dir / "pet_request.json").read_text(encoding="utf-8"))
        key = tuple(request["chroma_key"]["rgb"])

        manifest_path = run_dir / "imagegen-jobs.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        write_json(manifest_path, {**manifest, "jobs": manifest["jobs"][:-1]})
        mismatched = run(FINALIZE, "--run-dir", run_dir, "--allow-synthetic-test-sources", expect_ok=False)
        assert mismatched.returncode != 0 and "do not exactly match" in mismatched.stderr
        write_json(manifest_path, manifest)

        sources = root / "synthetic-imagegen"
        for index, action in enumerate(request["actions"]):
            generated = sources / f"ig_{action}.png"
            make_generated_strip(generated, key, index)
            run(RECORD, "--run-dir", run_dir, "--job-id", action, "--source", generated, "--allow-synthetic-test-source")

        first_finalize = run(FINALIZE, "--run-dir", run_dir, "--allow-synthetic-test-sources", expect_ok=False)
        assert first_finalize.returncode != 0 and "contact sheet is ready" in first_finalize.stderr
        assert (run_dir / "qa" / "contact-sheet.png").is_file()

        finalized = json.loads(
            run(
                FINALIZE,
                "--run-dir",
                run_dir,
                "--allow-synthetic-test-sources",
                "--approve-visual-identity",
                "--review-note",
                "Fixture identity and all six frames were visually checked for progressive reversible rest.",
            ).stdout
        )
        profile = json.loads((clone / "health-profile.json").read_text(encoding="utf-8"))
        assert finalized["ok"] and profile["healthExtension"]["status"] == "complete"
        assert [profile["stages"][str(stage)]["semanticAction"] for stage in (2, 3, 4)] == ["generated-tired", "generated-sick", "generated-rest"]
        assert sha256(source) == source_hash
        assert (plugin_data / "restart.request.json").is_file()
        assert json.loads(run(PREPARE, "--clone-dir", clone).stdout)["required"] is False
        print("health-extension: ok")
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
