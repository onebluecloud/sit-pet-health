#!/usr/bin/env python3
"""Prepare grounded image-generation jobs for missing RousePet health actions."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw

CELL_WIDTH = 192
CELL_HEIGHT = 208
FRAME_COUNT = 6
HEALTH_ACTIONS = {
    "tired": {
        "stage": 2,
        "direction": "Show the pet becoming gently low-energy: heavier eyelids, smaller movement, and a slightly lowered posture. Keep it alert and recognizable; no crying or detached effects.",
    },
    "sick": {
        "stage": 3,
        "direction": "Show the pet clearly worn out and needing a break through posture, breathing, and expression. Keep the reaction empathetic and restrained; no medical symbols, dramatic tears, or detached effects.",
    },
    "rest": {
        "stage": 4,
        "direction": "Show the pet settling into a calm reversible rest pose and breathing loop. It must read as resting, never dead, unconscious, injured, or abandoned; no mushrooms, graves, text, or detached effects.",
    },
}
CHROMA_KEYS = [
    ("magenta", "#FF00FF"),
    ("cyan", "#00FFFF"),
    ("yellow", "#FFFF00"),
    ("blue", "#0000FF"),
    ("orange", "#FF7F00"),
    ("green", "#00FF00"),
]


def load_json(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise SystemExit(f"file not found: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"expected JSON object: {path}")
    return value


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.{hashlib.sha256(str(path).encode()).hexdigest()[:8]}.tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_hex(value: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
        raise SystemExit(f"invalid chroma key: {value}")
    return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))


def color_distance(left: tuple[int, int, int], right: tuple[int, int, int]) -> float:
    return math.sqrt(sum((left[index] - right[index]) ** 2 for index in range(3)))


def choose_chroma_key(reference: Image.Image) -> dict[str, object]:
    sampled = reference.convert("RGBA")
    sampled.thumbnail((128, 128), Image.Resampling.NEAREST)
    pixels = [(r, g, b) for r, g, b, a in sampled.getdata() if a > 16]
    if not pixels:
        pixels = [(0, 0, 0)]
    scored = []
    for preference, (name, value) in enumerate(CHROMA_KEYS):
        rgb = parse_hex(value)
        distances = sorted(color_distance(rgb, pixel) for pixel in pixels)
        percentile = distances[max(0, min(len(distances) - 1, int(len(distances) * 0.01)))]
        scored.append((percentile, -preference, name, value, rgb))
    score, _preference, name, value, rgb = max(scored)
    return {"name": name, "hex": value, "rgb": list(rgb), "score": round(score, 2)}


def canonical_reference(sheet_path: Path, output: Path) -> Image.Image:
    with Image.open(sheet_path) as opened:
        sheet = opened.convert("RGBA")
    if sheet.width < CELL_WIDTH * 6 or sheet.height < CELL_HEIGHT:
        raise SystemExit(f"unsupported source spritesheet size: {sheet.width}x{sheet.height}")

    candidates = []
    for column in range(6):
        frame = sheet.crop((column * CELL_WIDTH, 0, (column + 1) * CELL_WIDTH, CELL_HEIGHT))
        bbox = frame.getbbox()
        if bbox:
            candidates.append((bbox[2] * bbox[3], frame.crop(bbox)))
    if not candidates:
        raise SystemExit("the source pet idle row contains no visible frame")
    sprite = max(candidates, key=lambda item: item[0])[1]
    scale = min(4, max(1, 720 // max(sprite.width, sprite.height)))
    sprite = sprite.resize((sprite.width * scale, sprite.height * scale), Image.Resampling.NEAREST)
    canvas = Image.new("RGBA", (768, 832), (0, 0, 0, 0))
    canvas.alpha_composite(sprite, ((canvas.width - sprite.width) // 2, (canvas.height - sprite.height) // 2))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)
    return canvas


def layout_guide(path: Path) -> None:
    width = FRAME_COUNT * CELL_WIDTH
    image = Image.new("RGB", (width, CELL_HEIGHT), "#F7F7F7")
    draw = ImageDraw.Draw(image)
    for index in range(FRAME_COUNT):
        left = index * CELL_WIDTH
        draw.rectangle((left, 0, left + CELL_WIDTH - 1, CELL_HEIGHT - 1), outline="#151515", width=2)
        draw.rectangle((left + 18, 16, left + CELL_WIDTH - 19, CELL_HEIGHT - 17), outline="#2F80ED", width=2)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def action_prompt(action: str, display_name: str, chroma: dict[str, object]) -> str:
    direction = str(HEALTH_ACTIONS[action]["direction"])
    return f"""Create one horizontal six-frame animation strip for the existing Codex pet named {display_name}.

Identity lock:
- Treat the attached canonical pet image as authoritative. Preserve the exact species, head shape, face, eyes, markings, palette, proportions, outline weight, accessories, and silhouette.
- Do not redesign, age, recolor, simplify into a different character, or add accessories.

Health action: {action}
- {direction}
- Make a subtle six-pose loop with clear progression and a smooth return to the first pose.
- Use expression, posture, eyelids, head angle, limbs, and breathing only. No speech bubbles, labels, punctuation, UI, shadows, scenery, floor patches, glows, motion lines, detached tears, detached sweat, floating stars, or loose particles.
- Keep every pose fully inside its slot with generous transparent-safe padding. Do not overlap poses or cross slot boundaries.

Output rules:
- Exactly six complete full-body poses in one left-to-right horizontal strip.
- Follow the attached layout guide for count, spacing, centering, and safe padding, but do not reproduce its boxes, lines, colors, or marks.
- Use a perfectly flat pure {chroma['name']} {chroma['hex']} background across the entire image.
- Do not use {chroma['hex']} or nearby colors in the pet, highlights, shadows, or effects.
- Codex digital-pet sprite style: compact chibi proportions, chunky readable silhouette, stepped pixel-art-adjacent edges, thick dark outline, limited palette, and flat cel shading suitable for a 192x208 cell.
"""


def requested_actions(profile: dict[str, object]) -> list[str]:
    extension = profile.get("healthExtension")
    if not isinstance(extension, dict):
        raise SystemExit("health-profile.json does not contain a healthExtension request")
    if extension.get("status") == "complete":
        return []
    raw = extension.get("actions")
    if not isinstance(raw, list):
        raise SystemExit("healthExtension.actions must be a list")
    actions = []
    for item in raw:
        action = item.get("semantic") if isinstance(item, dict) else None
        if isinstance(action, str) and action in HEALTH_ACTIONS and action not in actions:
            actions.append(action)
    return actions


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clone-dir", required=True)
    parser.add_argument("--run-dir", default="")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    clone_dir = Path(args.clone_dir).expanduser().resolve()
    profile_path = clone_dir / "health-profile.json"
    profile = load_json(profile_path)
    actions = requested_actions(profile)
    if not actions:
        print(json.dumps({"ok": True, "required": False, "clone_dir": str(clone_dir)}, indent=2))
        return

    source_hash = str(profile.get("sourceSpriteSha256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", source_hash):
        raise SystemExit("health profile has an invalid sourceSpriteSha256")
    source_copy = next(iter(sorted(clone_dir.glob("source-spritesheet.*"))), None)
    if source_copy is None or not source_copy.is_file() or file_sha256(source_copy) != source_hash:
        raise SystemExit("private source spritesheet copy does not match the recorded source hash")

    run_dir = (
        Path(args.run_dir).expanduser().resolve()
        if args.run_dir
        else clone_dir / "extension-runs" / f"health-{source_hash[:12]}"
    )
    manifest_path = run_dir / "imagegen-jobs.json"
    if manifest_path.exists() and not args.force:
        manifest = load_json(manifest_path)
        print(json.dumps({"ok": True, "required": True, "reused": True, "run_dir": str(run_dir), "jobs": manifest.get("jobs", [])}, indent=2))
        return

    if run_dir.exists() and args.force:
        import shutil

        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)

    canonical_path = run_dir / "references" / "canonical-pet.png"
    canonical = canonical_reference(clone_dir / "spritesheet.png", canonical_path)
    chroma = choose_chroma_key(canonical)
    display_name = str(profile.get("sourceDisplayName") or profile.get("sourceSlug") or "Codex pet")

    jobs = []
    for action in actions:
        guide = run_dir / "references" / "layout-guides" / f"{action}.png"
        layout_guide(guide)
        prompt = run_dir / "prompts" / f"{action}.md"
        prompt.parent.mkdir(parents=True, exist_ok=True)
        prompt.write_text(action_prompt(action, display_name, chroma).rstrip() + "\n", encoding="utf-8")
        jobs.append(
            {
                "id": action,
                "kind": "health-row-strip",
                "status": "pending",
                "prompt_file": str(prompt.relative_to(run_dir)),
                "output_path": f"decoded/{action}.png",
                "depends_on": [],
                "input_images": [
                    {"path": str(canonical_path.relative_to(run_dir)), "role": "canonical pet identity reference"},
                    {"path": str(guide.relative_to(run_dir)), "role": "layout-only six-frame guide"},
                ],
                "generation_skill": "$imagegen",
                "requires_grounded_generation": True,
                "allow_prompt_only_generation": False,
                "recording_owner": "parent",
            }
        )

    request = {
        "version": 1,
        "kind": "rousepet-health-extension",
        "clone_dir": str(clone_dir),
        "source_sprite_sha256": source_hash,
        "source_manifest_sha256": profile.get("sourceManifestSha256"),
        "display_name": display_name,
        "actions": actions,
        "frame_count": FRAME_COUNT,
        "chroma_key": chroma,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    write_json(run_dir / "pet_request.json", request)
    write_json(manifest_path, {"version": 1, "kind": request["kind"], "jobs": jobs})

    extension = dict(profile["healthExtension"])
    extension["status"] = "generating"
    extension["runDirectory"] = str(run_dir)
    extension["updatedAtUtc"] = datetime.now(timezone.utc).isoformat()
    profile["healthExtension"] = extension
    write_json(profile_path, profile)

    print(json.dumps({"ok": True, "required": True, "reused": False, "run_dir": str(run_dir), "actions": actions, "jobs": jobs}, indent=2))


if __name__ == "__main__":
    main()
