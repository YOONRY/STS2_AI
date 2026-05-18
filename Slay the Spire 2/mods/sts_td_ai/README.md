# STS TD AI Mod

This is a Godot-side mod shell for a Temporal Difference learner.

When installed as an autoload, the mod is available at:

```gdscript
var ai = get_node("/root/StsTdAi")
```

The current extracted project does not include usable C# gameplay bodies, so the
mod exposes a small API that future hooks can call from combat, map, reward, and
event screens.

## Runtime Storage

The mod writes to:

```text
user://sts_td_ai/
```

Files:

- `model.json`: TD value weights.
- `run_steps.jsonl`: observed transitions from runs.
- `settings.json`: alpha, gamma, epsilon, and hash bucket settings.

## API

```gdscript
StsTdAi.observe_step(state, action, reward, next_state, done)
StsTdAi.rank_actions(state, actions)
StsTdAi.choose_action(state, actions)
StsTdAi.set_auto_play_enabled(true)
StsTdAi.train_from_log()
StsTdAi.save_model()
```

`actions` may include `predicted_state`. If present, ranking uses the estimated
value of that predicted state.

Example action:

```json
{
  "type": "pick_card",
  "id": "POMMEL_STRIKE",
  "predicted_state": {
    "hp": 66,
    "max_hp": 80,
    "floor": 5,
    "deck": ["Strike", "Strike", "Defend", "Pommel Strike"]
  }
}
```

## Next Hook Points

The first hook pass is installed in `sts_td_ai_scene_hook.gd`.

It scans visible scene-tree nodes and detects:

1. Combat room card/end-turn controls.
2. Card reward and generic card choice screens.
3. Reward screen claim/proceed controls.
4. Map screen map-point-like controls.
5. Game-over continue controls.

By default it only ranks choices and stores the latest decision context in
`StsTdAi.last_context`. To let it click the best-ranked visible action:

```gdscript
StsTdAi.set_auto_play_enabled(true)
```

TD updates are applied only after the AI has clicked an action itself. When
auto-play is off, the hook records recommendations but does not pretend that a
manual player chose the same action.

## In-Game Controls

The small `STS TD AI` overlay includes one `Turn AI ON` / `Turn AI OFF` button.
Press it to toggle auto-play.

The overlay also shows the agent state:

- `scanning`: Looking for a supported screen.
- `thinking`: Ranking visible actions.
- `acting`: Attempting to execute the best action.
- `clicked`: An action was sent.
- `cooldown`: Waiting briefly before retrying.
- `waiting`: A screen was found, but no clickable action was found.

This is intentionally conservative because the current extraction does not
include usable C# gameplay bodies. Once those are available, replace the
scene-tree scanner with direct game-state adapters and keep the same TD API.

## Validation

The mod scripts were smoke-tested with Godot 4.6.1 Mono in a minimal project:

```powershell
.\Godot_v4.6.1-stable_mono_win64\Godot_v4.6.1-stable_mono_win64_console.exe --headless --path .\godot_mod_smoke --quit-after 3
```

The full extracted STS2 project reaches `[StsTdAi] ready`, then fails on the
empty extracted C# game scripts such as `NGame.cs` and `NAssetLoader.cs`. That
failure is separate from this mod and means the current extraction is not a
runnable game project by itself.
