# STS2 TD AI

Slay the Spire 2 mod prototype for a Temporal Difference learner that can rank visible run decisions and optionally automate them from an in-game overlay.

## Contents

- `Slay the Spire 2/mods/sts_td_ai/`: Godot mod scripts, manifest, and PCK pack script.
- `sts_td_ai_mod_dll/`: C# bootstrap DLL source using STS2's mod initializer.
- `sts_ai/`: External Python TD learner prototype, catalog extraction, schemas, and examples.
- `tools/MetadataDump/`: Small assembly metadata inspection utility used to inspect STS2 mod entry points.
- `godot_mod_smoke/`: Minimal Godot smoke-test project for the GDScript side.
- `build/sts_td_ai.zip`: Installable mod package generated during development.

## Install

Copy the contents of `build/sts_td_ai.zip` or the `build/sts_td_ai/` folder into:

```text
<Steam>/steamapps/common/Slay the Spire 2/mods/sts_td_ai/
```

The installed folder should contain:

```text
manifest.json
sts_td_ai.dll
sts_td_ai.pck
```

## Runtime

When the mod loads, it creates `/root/StsTdAi` and writes runtime learning data under:

```text
user://sts_td_ai/
```

The in-game overlay includes an `AI OFF` / `AI ON` button to toggle auto-play.
