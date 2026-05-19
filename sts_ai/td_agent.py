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


CARD_ACTION_TYPES = {
    "pick_card",
    "choose_card",
    "select_deck_card",
    "remove_card",
    "upgrade_card",
    "transform_card",
    "enchant_card",
}


def safe_float(value: Any, fallback: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def normalize_card_text(text: str) -> str:
    normalized = text.strip()
    for token in ("[center]", "[/center]", "[b]", "[/b]", "[i]", "[/i]"):
        normalized = normalized.replace(token, "")
    return " ".join(normalized.split())[:64]


def is_card_action(action_type: str) -> bool:
    return action_type in CARD_ACTION_TYPES


def deck_count_for_card(state: JsonObject, card_name: str) -> int:
    deck = state.get("deck", [])
    if not card_name or not isinstance(deck, list):
        return 0
    normalized = card_name.lower()
    return sum(1 for card in deck if normalize_card_text(str(card)).lower() == normalized)


def deck_size_flags(deck_size: int | float) -> dict[str, float]:
    return {
        "thin": float(deck_size <= 20),
        "medium": float(20 <= deck_size <= 30),
        "thick": float(deck_size >= 30),
    }


def is_basic_strike(card_name: str) -> bool:
    lower = card_name.lower()
    return lower == "strike" or "strike" in lower or "타격" in lower


def is_basic_defend(card_name: str) -> bool:
    lower = card_name.lower()
    return lower == "defend" or "defend" in lower or "수비" in lower or "방어" in lower


def is_basic_card(card_name: str) -> bool:
    return is_basic_strike(card_name) or is_basic_defend(card_name)


def is_curse_or_status(card_name: str, card_type: str) -> bool:
    lower = card_name.lower()
    lower_type = card_type.lower()
    if any(token in lower_type for token in ("curse", "status", "저주", "상태")):
        return True
    needles = (
        "curse",
        "status",
        "wound",
        "burn",
        "slimed",
        "dazed",
        "void",
        "regret",
        "injury",
        "shame",
        "pain",
        "doubt",
        "normality",
        "parasite",
        "저주",
        "상처",
        "화상",
        "점액",
    )
    return any(needle in lower for needle in needles)


def card_base_score(card_name: str, card_type: str = "", card_cost: float = -1.0) -> float:
    if not card_name:
        return 0.0
    if is_curse_or_status(card_name, card_type):
        return -1.2
    if is_basic_strike(card_name):
        return -0.35
    if is_basic_defend(card_name):
        return -0.20

    score = 0.12
    if "attack" in card_type:
        score += 0.08
    elif "skill" in card_type:
        score += 0.12
    elif "power" in card_type:
        score += 0.22
    if 0 <= card_cost <= 1:
        score += 0.08
    elif card_cost >= 3:
        score -= 0.05
    if "+" in card_name:
        score += 0.15
    return max(-1.2, min(score, 1.0))


def card_action_heuristic(state: JsonObject, action: JsonObject) -> float:
    action_type = str(action.get("type", "unknown")).lower()
    if not is_card_action(action_type):
        return 0.0
    card_name = normalize_card_text(str(action.get("card_name") or action.get("label") or action.get("id") or ""))
    card_type = str(action.get("card_type", "")).lower()
    card_cost = safe_float(action.get("card_cost"), -1.0)
    base_score = card_base_score(card_name, card_type, card_cost)
    deck = state.get("deck", [])
    deck_size = len(deck) if isinstance(deck, list) else 0
    deck_bloat_penalty = max(deck_size - 20, 0) * 0.006
    duplicate_penalty = max(deck_count_for_card(state, card_name) - 1, 0) * 0.025

    if action_type == "remove_card":
        cleanup_bonus = 0.35 if is_basic_card(card_name) else 0.0
        cleanup_bonus += 1.0 if is_curse_or_status(card_name, card_type) else 0.0
        return max(-0.4, min((-base_score * 0.55) + cleanup_bonus + deck_bloat_penalty, 1.4))
    if action_type == "transform_card":
        return max(-0.35, min((0.35 - base_score * 0.45) + (0.25 if is_basic_card(card_name) else 0.0), 0.9))
    if action_type in {"upgrade_card", "enchant_card"}:
        if is_curse_or_status(card_name, card_type):
            return -0.6
        upgrade_bonus = max(base_score, 0.0) * 0.35
        if is_basic_strike(card_name):
            upgrade_bonus -= 0.18
        return max(-0.25, min(upgrade_bonus, 0.75))
    if action_type in {"pick_card", "choose_card", "select_deck_card"}:
        return max(-1.0, min(base_score - deck_bloat_penalty - duplicate_penalty, 1.0))
    return 0.0


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

    def extract_action(self, state: JsonObject, action: JsonObject) -> dict[str, float]:
        action_type = str(action.get("type", "unknown")).lower()
        card_name = normalize_card_text(
            str(action.get("card_name") or action.get("label") or action.get("id") or "")
        )
        card_type = str(action.get("card_type", "")).lower()
        card_cost = safe_float(action.get("card_cost"), -1.0)

        features = {
            "action_bias": 1.0,
            f"action_type:{action_type}": 1.0,
        }
        if is_card_action(action_type):
            deck = state.get("deck", [])
            deck_size = len(deck) if isinstance(deck, list) else 0
            deck_count = deck_count_for_card(state, card_name)
            base_score = card_base_score(card_name, card_type, card_cost)
            deck_flags = deck_size_flags(deck_size)
            features.update(
                {
                    "card_action_bias": 1.0,
                    "deck_size_norm": min(deck_size / 40.0, 1.0),
                    "deck_copies_norm": min(deck_count / 5.0, 1.0),
                    "card_base_score": base_score,
                    "card_is_basic": float(is_basic_card(card_name)),
                    "card_is_curse_or_status": float(is_curse_or_status(card_name, card_type)),
                }
            )
            for band, active in deck_flags.items():
                features[f"deck_{band}"] = active
                features[f"action_type_deck:{action_type}:{band}"] = active
                features[f"card_base_score_deck_{band}"] = base_score * active
            if card_cost >= 0:
                features["card_cost_norm"] = min(card_cost / 4.0, 1.0)
            if card_type:
                features[f"card_type:{card_type}"] = 1.0
                for band, active in deck_flags.items():
                    if active:
                        features[f"card_type_deck:{card_type}:{band}"] = 1.0
            if card_name:
                bucket = stable_bucket(f"card:{card_name}", self.hash_buckets)
                features[f"card_bucket_{bucket}"] = 1.0
                features[f"action_card_bucket:{action_type}:{bucket}"] = 1.0
                for band, active in deck_flags.items():
                    if active:
                        features[f"card_deck:{bucket}:{band}"] = 1.0
                        features[f"action_card_deck:{action_type}:{bucket}:{band}"] = 1.0
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
    action_weights: dict[str, float] = field(default_factory=dict)
    extractor: FeatureExtractor = field(default_factory=FeatureExtractor)

    def value(self, state: JsonObject) -> float:
        return sum(self.weights.get(name, 0.0) * amount for name, amount in self.extractor.extract(state).items())

    def action_value(self, state: JsonObject, action: JsonObject) -> float:
        learned = sum(
            self.action_weights.get(name, 0.0) * amount
            for name, amount in self.extractor.extract_action(state, action).items()
        )
        return learned + card_action_heuristic(state, action)

    def update(self, state: JsonObject, reward: float, next_state: JsonObject, done: bool) -> float:
        features = self.extractor.extract(state)
        current = sum(self.weights.get(name, 0.0) * amount for name, amount in features.items())
        bootstrap = 0.0 if done else self.value(next_state)
        target = reward + self.gamma * bootstrap
        error = target - current
        for name, amount in features.items():
            self.weights[name] = self.weights.get(name, 0.0) + self.alpha * error * amount
        return error

    def update_action(
        self,
        state: JsonObject,
        action: JsonObject,
        reward: float,
        next_state: JsonObject,
        done: bool,
    ) -> float:
        features = self.extractor.extract_action(state, action)
        if not features:
            return 0.0
        current = self.value(state) + sum(self.action_weights.get(name, 0.0) * amount for name, amount in features.items())
        bootstrap = 0.0 if done else self.value(next_state)
        target = reward + self.gamma * bootstrap
        error = target - current
        for name, amount in features.items():
            self.action_weights[name] = self.action_weights.get(name, 0.0) + self.alpha * error * amount
        return error

    def to_json(self) -> JsonObject:
        return {
            "alpha": self.alpha,
            "gamma": self.gamma,
            "hash_buckets": self.extractor.hash_buckets,
            "weights": self.weights,
            "action_weights": self.action_weights,
        }

    @classmethod
    def from_json(cls, payload: JsonObject) -> "LinearTDValue":
        return cls(
            alpha=float(payload.get("alpha", 0.05)),
            gamma=float(payload.get("gamma", 0.98)),
            weights={str(k): float(v) for k, v in payload.get("weights", {}).items()},
            action_weights={str(k): float(v) for k, v in payload.get("action_weights", {}).items()},
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
        state_error = model.update(
            state=step["state"],
            reward=float(step["reward"]),
            next_state=step["next_state"],
            done=bool(step["done"]),
        )
        errors = [state_error]
        action = step.get("action")
        if isinstance(action, dict):
            errors.append(
                model.update_action(
                    state=step["state"],
                    action=action,
                    reward=float(step["reward"]),
                    next_state=step["next_state"],
                    done=bool(step["done"]),
                )
            )
        steps += 1
        abs_error += abs(sum(errors) / len(errors))

    save_model(args.model, model)
    mean_error = abs_error / max(steps, 1)
    print(
        f"trained {steps} steps, mean_abs_td_error={mean_error:.4f}, "
        f"weights={len(model.weights)}, action_weights={len(model.action_weights)}"
    )


def rank(args: argparse.Namespace) -> None:
    model = load_model(args.model, args.alpha, args.gamma)
    with args.state.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    state = payload.get("state", {})
    if not isinstance(state, dict):
        state = {}
    actions = payload.get("actions", [])
    ranked = []
    for action in actions:
        if not isinstance(action, dict):
            continue
        predicted_state = action.get("predicted_state", state)
        if not isinstance(predicted_state, dict):
            predicted_state = state
        score = model.value(predicted_state) + model.action_value(state, action)
        ranked.append({"action": action, "value": score})

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
