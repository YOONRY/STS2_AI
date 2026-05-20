# STS2 TD Agent Prototype

Slay the Spire 2 extracted files in this workspace expose useful data such as
card, relic, and monster names/descriptions, but most C# gameplay files are
empty stubs. This prototype therefore starts as an external learner:

1. Read catalog data from `Slay the Spire 2/localization/eng`.
2. Record one run as JSONL decision steps.
3. Update a TD(lambda) value function after each observed transition.
4. Use the learned state and action estimates to rank legal actions.

The core idea is deliberately small: learn `V(state)` during a run, then score
each choice as `V(predicted_state) + A(state, action)`. Card actions get a
small heuristic seed and learned action weights, so remove, transform, upgrade,
and pick decisions can treat weak basics, curses, duplicates, and upgraded cards
differently before enough run data has accumulated.
Deck-size interaction features use `thin <= 20`, `medium 20..30`, and
`thick >= 30`, with boundary values allowed to activate both adjacent signals.

Online updates use eligibility traces:

```text
delta = r + gamma * V(s') - V(s)
e_i = gamma * lambda * e_i + feature_i(s)
w_i = w_i + alpha * delta * e_i
```

Training also supports replay. The first pass keeps chronological traces; later
passes prioritize terminal states, high reward, HP loss, and floor progress.

## Files

- `schemas/step.schema.json`: event format for one observed decision.
- `tools/extract_catalog.py`: builds a compact catalog from extracted JSON.
- `td_agent.py`: TD learner, feature extractor, action ranker, and CLI.
- `examples/sample_run.jsonl`: tiny sample log for smoke testing.

## Quick Start

```powershell
python sts_ai/tools/extract_catalog.py --game-dir "Slay the Spire 2" --out sts_ai/catalog.json
python sts_ai/td_agent.py train --run-log sts_ai/examples/sample_run.jsonl --model sts_ai/model.json --trace-lambda 0.75 --replay-passes 2
python sts_ai/td_agent.py rank --model sts_ai/model.json --state sts_ai/examples/state.json
```

## JSONL Step Format

Each line is a transition:

```json
{
  "state": {"hp": 70, "max_hp": 80, "gold": 99, "floor": 3, "deck": ["Strike", "Defend"]},
  "action": {"type": "pick_card", "id": "BASH"},
  "reward": 0.2,
  "next_state": {"hp": 70, "max_hp": 80, "gold": 99, "floor": 4, "deck": ["Strike", "Defend", "Bash"]},
  "done": false
}
```

Rewards can be sparse at first. A simple starting rule is:

- `+1.0` for winning a fight.
- `-1.0` for death.
- Small negative reward for HP lost, for example `-0.02 * hp_lost`.
- Small positive reward for floor progress.

Later, replace this with better run outcome shaping.
