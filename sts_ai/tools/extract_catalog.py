from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def collect_titles(data: dict[str, Any], suffix: str) -> dict[str, str]:
    titles: dict[str, str] = {}
    for key, value in data.items():
        if key.endswith(suffix) and isinstance(value, str):
            item_id = key[: -len(suffix)]
            titles[item_id] = value
    return titles


def build_catalog(game_dir: Path) -> dict[str, Any]:
    loc = game_dir / "localization" / "eng"
    cards = load_json(loc / "cards.json")
    relics = load_json(loc / "relics.json")
    monsters = load_json(loc / "monsters.json")

    return {
        "cards": collect_titles(cards, ".title"),
        "relics": collect_titles(relics, ".title"),
        "monsters": collect_titles(monsters, ".name"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract compact STS2 catalog data.")
    parser.add_argument("--game-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    catalog = build_catalog(args.game_dir)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, sort_keys=True)

    print(
        f"wrote {args.out} "
        f"({len(catalog['cards'])} cards, "
        f"{len(catalog['relics'])} relics, "
        f"{len(catalog['monsters'])} monsters)"
    )


if __name__ == "__main__":
    main()
