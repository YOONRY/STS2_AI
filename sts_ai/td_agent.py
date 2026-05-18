from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


JsonObject = dict[str, Any]


def stable_bucket(value: str, buckets: int) -> int:
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % buckets


@dataclass
class FeatureExtractor:
    hash_buckets: int = 256

    def extract(self, state: JsonObject) -> dict[str, float]:
        max_hp = max(float(state.get("max_hp", 1) or 1), 1.0)
        hp = float(state.get("hp", 0) or 0)
        floor = float(state.get("floor", 0) or 0)
        gold = float(state.get("gold", 0) or 0)
        block = float(state.get("block", 0) or 0)
        energy = float(state.get("energy", 0) or 0)

        features = {
            "bias": 1.0,
            "hp_ratio": hp / max_hp,
            "missing_hp_ratio": (max_hp - hp) / max_hp,
            "floor_norm": floor / 60.0,
            "gold_norm": math.log1p(max(gold, 0.0)) / 8.0,
            "block_norm": min(block / 50.0, 1.0),
            "energy_norm": min(energy / 5.0, 1.0),
        }

        self._add_collection(features, "deck", state.get("deck", []), 0.05)
        self._add_collection(features, "relic", state.get("relics", []), 0.1)
        self._add_collection(features, "potion", state.get("potions", []), 0.05)
        self._add_collection(features, "hand", state.get("hand", []), 0.08)

        enemies = state.get("enemies", [])
        if isinstance(enemies, list):
            features["enemy_count"] = min(len(enemies) / 5.0, 1.0)
            total_enemy_hp = sum(float(enemy.get("hp", 0) or 0) for enemy in enemies if isinstance(enemy, dict))
            incoming = sum(float(enemy.get("intent_damage", 0) or 0) for enemy in enemies if isinstance(enemy, dict))
            features["enemy_hp_norm"] = min(total_enemy_hp / 300.0, 1.0)
            features["incoming_norm"] = min(incoming / 80.0, 1.0)

        return features

    def _add_collection(
        self,
        features: dict[str, float],
        prefix: str,
        values: Any,
        scale: float,
    ) -> None:
        if not isinstance(values, list):
            return
        for raw_value in values:
            value = str(raw_value)
            bucket = stable_bucket(f"{prefix}:{value}", self.hash_buckets)
            key = f"{prefix}_bucket_{bucket}"
            features[key] = features.get(key, 0.0) + scale


@dataclass
class LinearTDValue:
    alpha: float = 0.05
    gamma: float = 0.98
    weights: dict[str, float] = field(default_factory=dict)
    extractor: FeatureExtractor = field(default_factory=FeatureExtractor)

    def value(self, state: JsonObject) -> float:
        return sum(self.weights.get(name, 0.0) * amount for name, amount in self.extractor.extract(state).items())

    def update(self, state: JsonObject, reward: float, next_state: JsonObject, done: bool) -> float:
        features = self.extractor.extract(state)
        current = sum(self.weights.get(name, 0.0) * amount for name, amount in features.items())
        bootstrap = 0.0 if done else self.value(next_state)
        target = reward + self.gamma * bootstrap
        error = target - current
        for name, amount in features.items():
            self.weights[name] = self.weights.get(name, 0.0) + self.alpha * error * amount
        return error

    def to_json(self) -> JsonObject:
        return {
            "alpha": self.alpha,
            "gamma": self.gamma,
            "hash_buckets": self.extractor.hash_buckets,
            "weights": self.weights,
        }

    @classmethod
    def from_json(cls, payload: JsonObject) -> "LinearTDValue":
        return cls(
            alpha=float(payload.get("alpha", 0.05)),
            gamma=float(payload.get("gamma", 0.98)),
            weights={str(k): float(v) for k, v in payload.get("weights", {}).items()},
            extractor=FeatureExtractor(hash_buckets=int(payload.get("hash_buckets", 256))),
        )


def read_jsonl(path: Path) -> Iterable[JsonObject]:
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                yield json.loads(text)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSONL") from exc


def load_model(path: Path | None, alpha: float, gamma: float) -> LinearTDValue:
    if path is not None and path.exists():
        with path.open("r", encoding="utf-8") as handle:
            return LinearTDValue.from_json(json.load(handle))
    return LinearTDValue(alpha=alpha, gamma=gamma)


def save_model(path: Path, model: LinearTDValue) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(model.to_json(), handle, indent=2, sort_keys=True)


def train(args: argparse.Namespace) -> None:
    model = load_model(args.model, args.alpha, args.gamma)
    steps = 0
    abs_error = 0.0
    for step in read_jsonl(args.run_log):
        error = model.update(
            state=step["state"],
            reward=float(step["reward"]),
            next_state=step["next_state"],
            done=bool(step["done"]),
        )
        steps += 1
        abs_error += abs(error)

    save_model(args.model, model)
    mean_error = abs_error / max(steps, 1)
    print(f"trained {steps} steps, mean_abs_td_error={mean_error:.4f}, weights={len(model.weights)}")


def rank(args: argparse.Namespace) -> None:
    model = load_model(args.model, args.alpha, args.gamma)
    with args.state.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    actions = payload.get("actions", [])
    ranked = []
    for action in actions:
        predicted_state = action.get("predicted_state", payload.get("state", {}))
        ranked.append({"action": action, "value": model.value(predicted_state)})

    ranked.sort(key=lambda item: item["value"], reverse=True)
    print(json.dumps(ranked, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Small TD(0) value learner for STS2 runs.")
    subparsers = parser.add_subparsers(required=True)

    train_parser = subparsers.add_parser("train")
    train_parser.add_argument("--run-log", type=Path, required=True)
    train_parser.add_argument("--model", type=Path, required=True)
    train_parser.add_argument("--alpha", type=float, default=0.05)
    train_parser.add_argument("--gamma", type=float, default=0.98)
    train_parser.set_defaults(func=train)

    rank_parser = subparsers.add_parser("rank")
    rank_parser.add_argument("--state", type=Path, required=True)
    rank_parser.add_argument("--model", type=Path, required=True)
    rank_parser.add_argument("--alpha", type=float, default=0.05)
    rank_parser.add_argument("--gamma", type=float, default=0.98)
    rank_parser.set_defaults(func=rank)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
