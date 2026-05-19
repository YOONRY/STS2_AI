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
const CARD_ACTION_TYPES := [
	"pick_card",
	"choose_card",
	"select_deck_card",
	"remove_card",
	"upgrade_card",
	"transform_card",
	"enchant_card"
]
const SceneHook := preload("res://mods/sts_td_ai/sts_td_ai_scene_hook.gd")

var alpha := DEFAULT_ALPHA
var gamma := DEFAULT_GAMMA
var epsilon := DEFAULT_EPSILON
var hash_buckets := DEFAULT_HASH_BUCKETS
var auto_play_enabled := false
var weights := {}
var action_weights := {}
var total_observed_steps := 0
var last_context := {}
var last_ranked_actions := []
var agent_status := {
	"phase": "starting",
	"detail": "loading",
	"updated_at": ""
}
var _scene_hook: Node
var _hud_layer: CanvasLayer
var _hud_label: Label
var _hud_status_light: ColorRect
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
	var state_error: float = update_value(state, reward, next_state, done)
	var action_error: float = update_action_value(state, action, reward, next_state, done)
	var error: float = (state_error + action_error) * 0.5
	total_observed_steps += 1
	step_observed.emit(step)
	model_updated.emit(1, absf(error))
	if done:
		save_model()
	return error


func action_value(state: Dictionary, action: Dictionary) -> float:
	return _learned_action_value(state, action) + card_action_heuristic(state, action)


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


func update_action_value(state: Dictionary, action: Dictionary, reward: float, next_state: Dictionary, done: bool) -> float:
	if action.is_empty():
		return 0.0
	var features := extract_action_features(state, action)
	if features.is_empty():
		return 0.0

	var current: float = value(state) + _learned_action_value(state, action)
	var bootstrap: float = 0.0 if done else value(next_state)
	var target: float = reward + gamma * bootstrap
	var error: float = target - current

	for feature_name in features.keys():
		action_weights[feature_name] = float(action_weights.get(feature_name, 0.0)) + alpha * error * float(features[feature_name])

	return error


func rank_actions(state: Dictionary, actions: Array) -> Array:
	var ranked := []
	for action in actions:
		if !(action is Dictionary):
			continue
		var predicted_state = action.get("predicted_state", state)
		var score: float = value(predicted_state) if predicted_state is Dictionary else value(state)
		score += action_value(state, action)
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


func note_agent_status(status: Dictionary) -> void:
	for key in status.keys():
		agent_status[key] = status[key]
	agent_status["updated_at"] = Time.get_datetime_string_from_system()
	_refresh_hud()


func set_auto_play_enabled(enabled: bool) -> void:
	auto_play_enabled = enabled
	note_agent_status({
		"phase": "watching" if enabled else "off",
		"detail": "auto enabled" if enabled else "auto disabled"
	})
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
		var state_error: float = update_value(
			parsed["state"],
			float(parsed.get("reward", 0.0)),
			parsed["next_state"],
			bool(parsed.get("done", false))
		)
		var action_error := 0.0
		var action = parsed.get("action", {})
		if action is Dictionary:
			action_error = update_action_value(
				parsed["state"],
				action,
				float(parsed.get("reward", 0.0)),
				parsed["next_state"],
				bool(parsed.get("done", false))
			)
		steps += 1
		abs_error += absf((state_error + action_error) * 0.5)

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
		"action_weights": action_weights,
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


func extract_action_features(state: Dictionary, action: Dictionary) -> Dictionary:
	var action_type := String(action.get("type", "unknown")).to_lower()
	var card_name := _card_name_from_action(action)
	var card_type := String(action.get("card_type", "")).to_lower()
	var card_cost := float(action.get("card_cost", -1.0))

	var features := {"action_bias": 1.0}
	features["action_type:%s" % action_type] = 1.0
	if _is_card_action_type(action_type):
		var deck = state.get("deck", [])
		var deck_size := float(deck.size()) if deck is Array else 0.0
		var deck_count := _deck_count_for_card(state, card_name)
		var base_score := _card_base_score(card_name, card_type, card_cost)
		var deck_flags := _deck_size_flags(deck_size)
		features["card_action_bias"] = 1.0
		features["deck_size_norm"] = minf(deck_size / 40.0, 1.0)
		features["deck_copies_norm"] = minf(float(deck_count) / 5.0, 1.0)
		features["card_base_score"] = base_score
		features["card_is_basic"] = 1.0 if _is_basic_card(card_name) else 0.0
		features["card_is_curse_or_status"] = 1.0 if _is_curse_or_status(card_name, card_type) else 0.0
		for band in deck_flags.keys():
			var active := float(deck_flags[band])
			features["deck_%s" % band] = active
			features["action_type_deck:%s:%s" % [action_type, band]] = active
			features["card_base_score_deck_%s" % band] = base_score * active
		if card_cost >= 0.0:
			features["card_cost_norm"] = minf(card_cost / 4.0, 1.0)
		if card_type != "":
			features["card_type:%s" % card_type] = 1.0
			for band in deck_flags.keys():
				if float(deck_flags[band]) > 0.0:
					features["card_type_deck:%s:%s" % [card_type, band]] = 1.0
		if card_name != "":
			var bucket := _stable_bucket("card:%s" % card_name)
			features["card_bucket_%d" % bucket] = 1.0
			features["action_card_bucket:%s:%d" % [action_type, bucket]] = 1.0
			for band in deck_flags.keys():
				if float(deck_flags[band]) > 0.0:
					features["card_deck:%d:%s" % [bucket, band]] = 1.0
					features["action_card_deck:%s:%d:%s" % [action_type, bucket, band]] = 1.0
	return features


func card_action_heuristic(state: Dictionary, action: Dictionary) -> float:
	var action_type := String(action.get("type", "unknown")).to_lower()
	if !_is_card_action_type(action_type):
		return 0.0
	var card_name := _card_name_from_action(action)
	var card_type := String(action.get("card_type", "")).to_lower()
	var card_cost := float(action.get("card_cost", -1.0))
	var base_score := _card_base_score(card_name, card_type, card_cost)
	var deck = state.get("deck", [])
	var deck_size := float(deck.size()) if deck is Array else 0.0
	var deck_bloat_penalty := maxf(deck_size - 20.0, 0.0) * 0.006
	var duplicate_penalty := maxf(float(_deck_count_for_card(state, card_name)) - 1.0, 0.0) * 0.025

	match action_type:
		"remove_card":
			var cleanup_bonus := 0.0
			if _is_basic_card(card_name):
				cleanup_bonus += 0.35
			if _is_curse_or_status(card_name, card_type):
				cleanup_bonus += 1.0
			return clampf((-base_score * 0.55) + cleanup_bonus + deck_bloat_penalty, -0.4, 1.4)
		"transform_card":
			return clampf((0.35 - base_score * 0.45) + (0.25 if _is_basic_card(card_name) else 0.0), -0.35, 0.9)
		"upgrade_card", "enchant_card":
			if _is_curse_or_status(card_name, card_type):
				return -0.6
			var upgrade_bonus := maxf(base_score, 0.0) * 0.35
			if _is_basic_strike(card_name):
				upgrade_bonus -= 0.18
			return clampf(upgrade_bonus, -0.25, 0.75)
		"pick_card", "choose_card", "select_deck_card":
			return clampf(base_score - deck_bloat_penalty - duplicate_penalty, -1.0, 1.0)
	return 0.0


func _deck_size_flags(deck_size: float) -> Dictionary:
	return {
		"thin": 1.0 if deck_size <= 20.0 else 0.0,
		"medium": 1.0 if deck_size >= 20.0 and deck_size <= 30.0 else 0.0,
		"thick": 1.0 if deck_size >= 30.0 else 0.0
	}


func _learned_action_value(state: Dictionary, action: Dictionary) -> float:
	var features := extract_action_features(state, action)
	var result := 0.0
	for feature_name in features.keys():
		result += float(action_weights.get(feature_name, 0.0)) * float(features[feature_name])
	return result


func _is_card_action_type(action_type: String) -> bool:
	return CARD_ACTION_TYPES.has(action_type)


func _card_name_from_action(action: Dictionary) -> String:
	for key in ["card_name", "label", "id", "node_name"]:
		var text := _normalize_card_text(String(action.get(key, "")))
		if text != "":
			return text
	return ""


func _normalize_card_text(text: String) -> String:
	var normalized := text.strip_edges()
	if normalized == "":
		return ""
	normalized = normalized.replace("[center]", "")
	normalized = normalized.replace("[/center]", "")
	normalized = normalized.replace("[b]", "")
	normalized = normalized.replace("[/b]", "")
	normalized = normalized.replace("[i]", "")
	normalized = normalized.replace("[/i]", "")
	normalized = normalized.replace("\n", " ")
	normalized = normalized.replace("\t", " ")
	while normalized.contains("  "):
		normalized = normalized.replace("  ", " ")
	if normalized.length() > 64:
		normalized = normalized.left(64)
	return normalized.strip_edges()


func _deck_count_for_card(state: Dictionary, card_name: String) -> int:
	if card_name == "":
		return 0
	var deck = state.get("deck", [])
	if !(deck is Array):
		return 0
	var normalized := card_name.to_lower()
	var count := 0
	for card in deck:
		if _normalize_card_text(str(card)).to_lower() == normalized:
			count += 1
	return count


func _card_base_score(card_name: String, card_type: String, card_cost: float) -> float:
	if card_name == "":
		return 0.0
	var lower := card_name.to_lower()
	if _is_curse_or_status(card_name, card_type):
		return -1.2
	if _is_basic_strike(card_name):
		return -0.35
	if _is_basic_defend(card_name):
		return -0.20

	var score := 0.12
	if card_type.contains("attack"):
		score += 0.08
	elif card_type.contains("skill"):
		score += 0.12
	elif card_type.contains("power"):
		score += 0.22
	if card_cost >= 0.0 and card_cost <= 1.0:
		score += 0.08
	elif card_cost >= 3.0:
		score -= 0.05
	if lower.contains("+"):
		score += 0.15
	return clampf(score, -1.2, 1.0)


func _is_basic_card(card_name: String) -> bool:
	return _is_basic_strike(card_name) or _is_basic_defend(card_name)


func _is_basic_strike(card_name: String) -> bool:
	var lower := card_name.to_lower()
	return lower == "strike" or lower.contains("strike") or lower.contains("타격")


func _is_basic_defend(card_name: String) -> bool:
	var lower := card_name.to_lower()
	return lower == "defend" or lower.contains("defend") or lower.contains("수비") or lower.contains("방어")


func _is_curse_or_status(card_name: String, card_type: String) -> bool:
	var lower := card_name.to_lower()
	var lower_type := card_type.to_lower()
	if lower_type.contains("curse") or lower_type.contains("status") or lower_type.contains("저주") or lower_type.contains("상태"):
		return true
	var needles := [
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
		"점액"
	]
	for needle in needles:
		if lower.contains(needle):
			return true
	return false


func reset_learning(delete_log := false) -> void:
	weights.clear()
	action_weights.clear()
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
	action_weights = model.get("action_weights", {})
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

	_hud_status_light = ColorRect.new()
	_hud_status_light.name = "StatusLight"
	_hud_status_light.custom_minimum_size = Vector2(260.0, 8.0)
	_hud_status_light.mouse_filter = Control.MOUSE_FILTER_IGNORE
	contents.add_child(_hud_status_light)

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
	var phase := String(agent_status.get("phase", "idle"))
	var detail := String(agent_status.get("detail", ""))
	var spinner := _status_spinner()
	_hud_label.text = "STS TD AI %s %s\nstate=%s %s\nscreen=%s actions=%d steps=%d\nbest=%s %s %.3f" % [
		"ON" if auto_play_enabled else "OFF",
		spinner if auto_play_enabled else "",
		phase,
		detail,
		screen if screen != "" else "unknown",
		last_ranked_actions.size(),
		total_observed_steps,
		best_type,
		best_label,
		best_value
	]
	_refresh_status_light(phase)
	if _auto_play_button != null:
		_auto_play_button.text = "Turn AI OFF" if auto_play_enabled else "Turn AI ON"


func _status_spinner() -> String:
	var frames := ["|", "/", "-", "\\"]
	var index := int(Time.get_ticks_msec() / 250) % frames.size()
	return frames[index]


func _refresh_status_light(phase: String) -> void:
	if _hud_status_light == null:
		return
	var pulse := 0.55 + 0.35 * absf(sin(float(Time.get_ticks_msec()) / 220.0))
	match phase:
		"thinking":
			_hud_status_light.color = Color(1.0, 0.86, 0.20, pulse)
		"acting":
			_hud_status_light.color = Color(1.0, 0.48, 0.12, pulse)
		"clicked":
			_hud_status_light.color = Color(0.35, 1.0, 0.45, 0.85)
		"failed":
			_hud_status_light.color = Color(1.0, 0.2, 0.2, 0.85)
		"cooldown":
			_hud_status_light.color = Color(0.25, 0.65, 1.0, pulse)
		"waiting", "scanning", "watching":
			_hud_status_light.color = Color(0.50, 0.78, 1.0, 0.75)
		_:
			_hud_status_light.color = Color(0.45, 0.45, 0.45, 0.65)
