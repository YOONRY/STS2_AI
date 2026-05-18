extends Node

signal model_updated(step_count, mean_abs_td_error)
signal step_observed(step)

const STORAGE_ROOT := "user://sts_td_ai"
const MODEL_PATH := STORAGE_ROOT + "/model.json"
const SETTINGS_PATH := STORAGE_ROOT + "/settings.json"
const RUN_LOG_PATH := STORAGE_ROOT + "/run_steps.jsonl"

const DEFAULT_ALPHA := 0.05
const DEFAULT_GAMMA := 0.98
const DEFAULT_EPSILON := 0.05
const DEFAULT_HASH_BUCKETS := 256
const HUD_UPDATE_INTERVAL := 0.4
const SceneHook := preload("res://mods/sts_td_ai/sts_td_ai_scene_hook.gd")

var alpha := DEFAULT_ALPHA
var gamma := DEFAULT_GAMMA
var epsilon := DEFAULT_EPSILON
var hash_buckets := DEFAULT_HASH_BUCKETS
var auto_play_enabled := false
var weights := {}
var total_observed_steps := 0
var last_context := {}
var last_ranked_actions := []
var _scene_hook: Node
var _hud_layer: CanvasLayer
var _hud_label: Label
var _auto_play_button: Button
var _hud_enabled := true
var _hud_update_accumulator := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_storage()
	_load_settings()
	_load_model()
	_scene_hook = SceneHook.new()
	add_child(_scene_hook)
	_scene_hook.setup(self)
	_create_hud()
	print("[StsTdAi] ready: weights=%d alpha=%.3f gamma=%.3f epsilon=%.3f" % [
		weights.size(),
		alpha,
		gamma,
		epsilon
	])


func _process(delta: float) -> void:
	_hud_update_accumulator += delta
	if _hud_update_accumulator < HUD_UPDATE_INTERVAL:
		return
	_hud_update_accumulator = 0.0
	_refresh_hud()


func observe_step(state: Dictionary, action: Dictionary, reward: float, next_state: Dictionary, done: bool) -> float:
	var step := {
		"state": state,
		"action": action,
		"reward": reward,
		"next_state": next_state,
		"done": done,
		"observed_at": Time.get_datetime_string_from_system()
	}
	_append_jsonl(RUN_LOG_PATH, step)
	var error: float = update_value(state, reward, next_state, done)
	total_observed_steps += 1
	step_observed.emit(step)
	model_updated.emit(1, absf(error))
	if done:
		save_model()
	return error


func value(state: Dictionary) -> float:
	var features := extract_features(state)
	var result := 0.0
	for feature_name in features.keys():
		result += float(weights.get(feature_name, 0.0)) * float(features[feature_name])
	return result


func update_value(state: Dictionary, reward: float, next_state: Dictionary, done: bool) -> float:
	var features := extract_features(state)
	var current := 0.0
	for feature_name in features.keys():
		current += float(weights.get(feature_name, 0.0)) * float(features[feature_name])

	var bootstrap: float = 0.0 if done else value(next_state)
	var target: float = reward + gamma * bootstrap
	var error: float = target - current

	for feature_name in features.keys():
		weights[feature_name] = float(weights.get(feature_name, 0.0)) + alpha * error * float(features[feature_name])

	return error


func rank_actions(state: Dictionary, actions: Array) -> Array:
	var ranked := []
	for action in actions:
		if !(action is Dictionary):
			continue
		var predicted_state = action.get("predicted_state", state)
		var score: float = value(predicted_state) if predicted_state is Dictionary else value(state)
		ranked.append({
			"action": action,
			"value": score
		})
	ranked.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))
	return ranked


func choose_action(state: Dictionary, actions: Array) -> Dictionary:
	if actions.is_empty():
		return {}
	if randf() < epsilon:
		var random_action = actions[randi() % actions.size()]
		return random_action if random_action is Dictionary else {}

	var ranked: Array = rank_actions(state, actions)
	if ranked.is_empty():
		return {}
	return ranked[0]["action"]


func note_decision_context(context: Dictionary, state: Dictionary, ranked_actions: Array) -> void:
	last_context = {
		"context": context,
		"state": state,
		"ranked_actions": ranked_actions,
		"seen_at": Time.get_datetime_string_from_system()
	}
	last_ranked_actions = ranked_actions


func set_auto_play_enabled(enabled: bool) -> void:
	auto_play_enabled = enabled
	save_settings()
	_refresh_hud()


func execute_best_ranked_action() -> Dictionary:
	if _scene_hook == null or !_scene_hook.has_method("execute_best_ranked_action"):
		return {}
	var action = _scene_hook.call("execute_best_ranked_action")
	return action if action is Dictionary else {}


func train_from_log(path := RUN_LOG_PATH) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {
			"steps": 0,
			"mean_abs_td_error": 0.0,
			"message": "No run log found."
		}

	var steps := 0
	var abs_error := 0.0
	while !file.eof_reached():
		var line := file.get_line().strip_edges()
		if line == "":
			continue
		var parsed = JSON.parse_string(line)
		if !(parsed is Dictionary):
			continue
		if !parsed.has("state") or !parsed.has("next_state"):
			continue
		var error: float = update_value(
			parsed["state"],
			float(parsed.get("reward", 0.0)),
			parsed["next_state"],
			bool(parsed.get("done", false))
		)
		steps += 1
		abs_error += absf(error)

	save_model()
	var mean_error: float = abs_error / float(max(steps, 1))
	model_updated.emit(steps, mean_error)
	return {
		"steps": steps,
		"mean_abs_td_error": mean_error,
		"message": "Training complete."
	}


func save_model() -> void:
	_write_json(MODEL_PATH, {
		"alpha": alpha,
		"gamma": gamma,
		"epsilon": epsilon,
		"hash_buckets": hash_buckets,
		"weights": weights,
		"total_observed_steps": total_observed_steps,
		"saved_at": Time.get_datetime_string_from_system()
	})


func save_settings() -> void:
	_write_json(SETTINGS_PATH, {
		"alpha": alpha,
		"gamma": gamma,
		"epsilon": epsilon,
		"hash_buckets": hash_buckets,
		"auto_play_enabled": auto_play_enabled,
		"hud_enabled": _hud_enabled
	})


func extract_features(state: Dictionary) -> Dictionary:
	var max_hp: float = maxf(float(state.get("max_hp", 1.0)), 1.0)
	var hp: float = float(state.get("hp", 0.0))
	var floor_value: float = float(state.get("floor", 0.0))
	var gold: float = float(state.get("gold", 0.0))
	var block: float = float(state.get("block", 0.0))
	var energy: float = float(state.get("energy", 0.0))

	var features := {
		"bias": 1.0,
		"hp_ratio": hp / max_hp,
		"missing_hp_ratio": (max_hp - hp) / max_hp,
		"floor_norm": floor_value / 60.0,
		"gold_norm": log(maxf(gold, 0.0) + 1.0) / 8.0,
		"block_norm": minf(block / 50.0, 1.0),
		"energy_norm": minf(energy / 5.0, 1.0)
	}

	_add_collection_features(features, "deck", state.get("deck", []), 0.05)
	_add_collection_features(features, "relic", state.get("relics", []), 0.1)
	_add_collection_features(features, "potion", state.get("potions", []), 0.05)
	_add_collection_features(features, "hand", state.get("hand", []), 0.08)

	var enemies = state.get("enemies", [])
	if enemies is Array:
		features["enemy_count"] = minf(float(enemies.size()) / 5.0, 1.0)
		var total_enemy_hp: float = 0.0
		var incoming: float = 0.0
		for enemy in enemies:
			if enemy is Dictionary:
				total_enemy_hp += float(enemy.get("hp", 0.0))
				incoming += float(enemy.get("intent_damage", 0.0))
		features["enemy_hp_norm"] = minf(total_enemy_hp / 300.0, 1.0)
		features["incoming_norm"] = minf(incoming / 80.0, 1.0)

	return features


func reset_learning(delete_log := false) -> void:
	weights.clear()
	total_observed_steps = 0
	save_model()
	if delete_log and FileAccess.file_exists(RUN_LOG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(RUN_LOG_PATH))


func _add_collection_features(features: Dictionary, prefix: String, values, scale: float) -> void:
	if !(values is Array):
		return
	for value in values:
		var key: String = "%s_bucket_%d" % [prefix, _stable_bucket("%s:%s" % [prefix, str(value)])]
		features[key] = float(features.get(key, 0.0)) + scale


func _stable_bucket(value: String) -> int:
	var hashed: int = value.hash()
	if hashed < 0:
		hashed = -hashed
	return hashed % max(hash_buckets, 1)


func _ensure_storage() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STORAGE_ROOT))


func _load_settings() -> void:
	var settings := _read_json(SETTINGS_PATH)
	if settings.is_empty():
		save_settings()
		return
	alpha = float(settings.get("alpha", DEFAULT_ALPHA))
	gamma = float(settings.get("gamma", DEFAULT_GAMMA))
	epsilon = float(settings.get("epsilon", DEFAULT_EPSILON))
	hash_buckets = int(settings.get("hash_buckets", DEFAULT_HASH_BUCKETS))
	auto_play_enabled = bool(settings.get("auto_play_enabled", false))
	_hud_enabled = bool(settings.get("hud_enabled", true))


func _load_model() -> void:
	var model := _read_json(MODEL_PATH)
	if model.is_empty():
		save_model()
		return
	weights = model.get("weights", {})
	total_observed_steps = int(model.get("total_observed_steps", 0))


func _read_json(path: String) -> Dictionary:
	if !FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[StsTdAi] Could not write %s" % path)
		return
	file.store_string(JSON.stringify(value, "\t", false))


func _append_jsonl(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("[StsTdAi] Could not append %s" % path)
		return
	file.seek_end()
	file.store_line(JSON.stringify(value))


func _create_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.name = "StsTdAiHud"
	_hud_layer.layer = 128
	_hud_layer.visible = _hud_enabled
	add_child(_hud_layer)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(16.0, 16.0)
	panel.custom_minimum_size = Vector2(260.0, 0.0)
	_hud_layer.add_child(panel)

	var contents := VBoxContainer.new()
	contents.name = "Contents"
	contents.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(contents)

	_hud_label = Label.new()
	_hud_label.name = "Status"
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	contents.add_child(_hud_label)

	_auto_play_button = Button.new()
	_auto_play_button.name = "AutoPlayButton"
	_auto_play_button.focus_mode = Control.FOCUS_NONE
	_auto_play_button.pressed.connect(_on_auto_play_button_pressed)
	contents.add_child(_auto_play_button)
	_refresh_hud()


func _on_auto_play_button_pressed() -> void:
	set_auto_play_enabled(!auto_play_enabled)
	print("[StsTdAi] auto_play_enabled=%s" % str(auto_play_enabled))


func _refresh_hud() -> void:
	if _hud_label == null:
		return
	var context: Dictionary = last_context.get("context", {}) if last_context is Dictionary else {}
	var screen := String(context.get("screen", ""))
	var best_label := ""
	var best_type := ""
	var best_value := 0.0
	if !last_ranked_actions.is_empty() and last_ranked_actions[0] is Dictionary:
		var top: Dictionary = last_ranked_actions[0]
		best_value = float(top.get("value", 0.0))
		var action: Dictionary = top.get("action", {}) if top.get("action", {}) is Dictionary else {}
		best_label = String(action.get("label", action.get("id", "")))
		best_type = String(action.get("type", ""))
	_hud_label.text = "STS TD AI %s\nscreen=%s actions=%d steps=%d\nbest=%s %s %.3f" % [
		"ON" if auto_play_enabled else "OFF",
		screen if screen != "" else "unknown",
		last_ranked_actions.size(),
		total_observed_steps,
		best_type,
		best_label,
		best_value
	]
	if _auto_play_button != null:
		_auto_play_button.text = "AI ON" if auto_play_enabled else "AI OFF"
