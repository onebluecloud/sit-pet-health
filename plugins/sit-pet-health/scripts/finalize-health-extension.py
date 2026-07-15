#!/usr/bin/env python3
"""Validate generated health rows and atomically activate a private RousePet extension."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw

CELL_WIDTH = 192
CELL_HEIGHT = 208
ATLAS_WIDTH = 1536
FRAME_COUNT = 6


def load_json(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise SystemExit(f"file not found: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"expected JSON object: {path}")
    return value


def write_json_atomic(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def resolve_run_file(run_dir: Path, value: object, label: str) -> Path:
    relative = Path(str(value or ""))
    if not str(value or "").strip() or relative.is_absolute():
        raise SystemExit(f"{label} must be a relative path inside the extension run")
    resolved = (run_dir / relative).resolve()
    if not is_relative_to(resolved, run_dir):
        raise SystemExit(f"{label} escapes the extension run directory")
    return resolved


def validate_job_sources(run_dir: Path, jobs: list[dict[str, object]], allow_synthetic: bool) -> None:
    generated_root = Path(os.environ.get("CODEX_HOME") or "~/.codex").expanduser().resolve() / "generated_images"
    for job in jobs:
        job_id = str(job.get("id") or "")
        if job.get("status") != "complete":
            raise SystemExit(f"image-generation job is not complete: {job_id}")
        source = Path(str(job.get("source_path") or "")).expanduser().resolve()
        output = resolve_run_file(run_dir, job.get("output_path"), f"{job_id} output_path")
        if not source.is_file() or not output.is_file():
            raise SystemExit(f"recorded image is missing for {job_id}")
        if file_sha256(source) != job.get("source_sha256") or file_sha256(output) != job.get("output_sha256"):
            raise SystemExit(f"recorded image hash changed for {job_id}")
        if allow_synthetic:
            continue
        if job.get("source_provenance") != "built-in-imagegen" or not is_relative_to(source, generated_root) or not source.name.startswith("ig_"):
            raise SystemExit(f"{job_id} is not a recorded built-in $imagegen output")


def chroma_distance(pixel: tuple[int, int, int], key: tuple[int, int, int]) -> float:
    return math.sqrt(sum((pixel[index] - key[index]) ** 2 for index in range(3)))


def remove_chroma(image: Image.Image, key: tuple[int, int, int], threshold: float = 84.0) -> Image.Image:
    rgba = image.convert("RGBA")
    pixels = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            red, green, blue, alpha = pixels[x, y]
            if chroma_distance((red, green, blue), key) <= threshold:
                pixels[x, y] = (red, green, blue, 0)
    return rgba


def fit_to_cell(image: Image.Image) -> Image.Image:
    bbox = image.getbbox()
    target = Image.new("RGBA", (CELL_WIDTH, CELL_HEIGHT), (0, 0, 0, 0))
    if bbox is None:
        return target
    sprite = image.crop(bbox)
    scale = min((CELL_WIDTH - 12) / sprite.width, (CELL_HEIGHT - 12) / sprite.height, 1.0)
    if scale < 1.0:
        sprite = sprite.resize((max(1, round(sprite.width * scale)), max(1, round(sprite.height * scale))), Image.Resampling.LANCZOS)
    target.alpha_composite(sprite, ((CELL_WIDTH - sprite.width) // 2, (CELL_HEIGHT - sprite.height) // 2))
    return target


def extract_frames(strip: Image.Image) -> list[Image.Image]:
    slot_width = strip.width / FRAME_COUNT
    frames = []
    for index in range(FRAME_COUNT):
        left = round(index * slot_width)
        right = round((index + 1) * slot_width)
        frames.append(fit_to_cell(strip.crop((left, 0, right, strip.height))))
    return frames


def frame_metrics(frame: Image.Image) -> dict[str, object]:
    alpha = frame.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        return {"nonEmpty": False, "bbox": None, "coverage": 0.0, "edgeTouch": False}
    nonzero = sum(1 for value in alpha.getdata() if value > 16)
    return {
        "nonEmpty": True,
        "bbox": list(bbox),
        "coverage": round(nonzero / (CELL_WIDTH * CELL_HEIGHT), 4),
        "edgeTouch": bbox[0] < 4 or bbox[1] < 4 or bbox[2] > CELL_WIDTH - 4 or bbox[3] > CELL_HEIGHT - 4,
    }


def build_strip(frames: list[Image.Image]) -> Image.Image:
    atlas = Image.new("RGBA", (ATLAS_WIDTH, CELL_HEIGHT), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        atlas.alpha_composite(frame, (index * CELL_WIDTH, 0))
    return atlas


def contact_sheet(canonical_path: Path, strips: dict[str, Image.Image], output: Path) -> None:
    width = 1240
    row_height = 236
    image = Image.new("RGB", (width, 250 + row_height * len(strips)), "#FFF9F2")
    draw = ImageDraw.Draw(image)
    with Image.open(canonical_path) as opened:
        canonical = opened.convert("RGBA")
    canonical.thumbnail((180, 196), Image.Resampling.NEAREST)
    image.paste(canonical, (32, 28), canonical)
    draw.text((238, 80), "RousePet private health extension", fill="#403936")
    draw.text((238, 118), "Verify identity, progression, clean background, and reversible rest.", fill="#756A64")
    for row, (action, strip) in enumerate(strips.items()):
        top = 250 + row * row_height
        preview = strip.crop((0, 0, CELL_WIDTH * FRAME_COUNT, CELL_HEIGHT))
        preview.thumbnail((1000, 208), Image.Resampling.NEAREST)
        image.paste(preview, (210, top), preview)
        draw.text((34, top + 88), action, fill="#403936")
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--approve-visual-identity", action="store_true")
    parser.add_argument("--review-note", default="")
    parser.add_argument("--allow-synthetic-test-sources", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).expanduser().resolve()
    request = load_json(run_dir / "pet_request.json")
    manifest = load_json(run_dir / "imagegen-jobs.json")
    jobs = [job for job in manifest.get("jobs", []) if isinstance(job, dict)]
    expected_actions = request.get("actions")
    if not isinstance(expected_actions, list) or not expected_actions:
        raise SystemExit("extension request contains no health actions")
    expected_actions = [str(action) for action in expected_actions]
    if len(set(expected_actions)) != len(expected_actions) or any(action not in {"tired", "sick", "rest"} for action in expected_actions):
        raise SystemExit("extension request contains invalid or duplicate health actions")
    job_ids = [str(job.get("id") or "") for job in jobs]
    if len(jobs) != len(expected_actions) or set(job_ids) != set(expected_actions):
        raise SystemExit("image-generation jobs do not exactly match the requested health actions")
    validate_job_sources(run_dir, jobs, args.allow_synthetic_test_sources)

    clone_dir = Path(str(request.get("clone_dir") or "")).expanduser().resolve()
    profile_path = clone_dir / "health-profile.json"
    profile = load_json(profile_path)
    source_hash = str(request.get("source_sprite_sha256") or "")
    if profile.get("sourceSpriteSha256") != source_hash:
        raise SystemExit("the active private clone no longer matches this extension run")
    source_copy = next(iter(sorted(clone_dir.glob("source-spritesheet.*"))), None)
    if source_copy is None or file_sha256(source_copy) != source_hash:
        raise SystemExit("private source spritesheet copy changed during extension generation")

    key_values = request.get("chroma_key", {}).get("rgb") if isinstance(request.get("chroma_key"), dict) else None
    if not isinstance(key_values, list) or len(key_values) != 3:
        raise SystemExit("extension request has no valid chroma key")
    key = tuple(int(value) for value in key_values)

    strips: dict[str, Image.Image] = {}
    review_rows = []
    for job in jobs:
        action = str(job.get("id") or "")
        with Image.open(resolve_run_file(run_dir, job.get("output_path"), f"{action} output_path")) as opened:
            transparent = remove_chroma(opened, key)
        frames = extract_frames(transparent)
        metrics = [frame_metrics(frame) for frame in frames]
        errors = []
        if any(not metric["nonEmpty"] for metric in metrics):
            errors.append("one or more requested frames are empty")
        if any(metric["edgeTouch"] for metric in metrics):
            errors.append("one or more frames touch the safe cell edge")
        if any(float(metric["coverage"]) < 0.015 for metric in metrics):
            errors.append("one or more frames contain too little visible sprite content")
        review_rows.append({"action": action, "frames": metrics, "errors": errors})
        strips[action] = build_strip(frames)

    review_path = run_dir / "qa" / "review.json"
    contact_path = run_dir / "qa" / "contact-sheet.png"
    contact_sheet(run_dir / "references" / "canonical-pet.png", strips, contact_path)
    errors = [f"{row['action']}: {error}" for row in review_rows for error in row["errors"]]
    write_json_atomic(review_path, {"ok": not errors, "errors": errors, "rows": review_rows, "visualReviewNote": args.review_note.strip()})
    if errors:
        raise SystemExit("health extension failed deterministic QA: " + "; ".join(errors))
    if not args.approve_visual_identity or len(args.review_note.strip()) < 12:
        raise SystemExit(f"contact sheet is ready at {contact_path}; inspect it, then pass --approve-visual-identity and a specific --review-note")

    extension_id = "health-v1-" + hashlib.sha256(
        "".join(file_sha256(resolve_run_file(run_dir, job.get("output_path"), f"{job.get('id')} output_path")) for job in jobs).encode()
    ).hexdigest()[:12]
    staging = clone_dir / "extensions" / f".{extension_id}.staging-{os.getpid()}"
    target = clone_dir / "extensions" / extension_id
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True, exist_ok=True)
    action_records = []
    for action, strip in strips.items():
        output = staging / f"{action}.png"
        strip.save(output)
        action_records.append({"semantic": action, "file": f"extensions/{extension_id}/{action}.png", "sha256": file_sha256(output), "frames": FRAME_COUNT})
    shutil.copy2(contact_path, staging / "contact-sheet.png")
    write_json_atomic(staging / "extension.json", {"version": 1, "id": extension_id, "sourceSpriteSha256": source_hash, "actions": action_records, "visualReviewNote": args.review_note.strip(), "completedAtUtc": datetime.now(timezone.utc).isoformat()})
    if target.exists():
        shutil.rmtree(staging)
    else:
        staging.replace(target)

    stages = profile.get("stages")
    if not isinstance(stages, dict):
        raise SystemExit("health profile stages are invalid")
    stage_by_action = {"tired": "2", "sick": "3", "rest": "4"}
    for record in action_records:
        stage = stage_by_action[record["semantic"]]
        stages[stage] = {
            "file": record["file"],
            "semanticAction": f"generated-{record['semantic']}",
            "frames": FRAME_COUNT,
            "durationMs": {"tired": 4200, "sick": 5000, "rest": 6200}[record["semantic"]],
        }
    profile["version"] = max(3, int(profile.get("version", 0)))
    profile["stages"] = stages
    profile["healthExtension"] = {
        "version": 1,
        "status": "complete",
        "id": extension_id,
        "actions": action_records,
        "runDirectory": str(run_dir),
        "visualReviewNote": args.review_note.strip(),
        "completedAtUtc": datetime.now(timezone.utc).isoformat(),
    }
    write_json_atomic(profile_path, profile)

    plugin_data = clone_dir.parent.parent
    if clone_dir.parent.name == "pets":
        write_json_atomic(plugin_data / "restart.request.json", {"version": 1, "reason": "health-extension-complete", "requestedAtUtc": datetime.now(timezone.utc).isoformat()})

    print(json.dumps({"ok": True, "clone_dir": str(clone_dir), "extension_id": extension_id, "actions": action_records, "contact_sheet": str(contact_path), "profile": str(profile_path)}, indent=2))


if __name__ == "__main__":
    main()
