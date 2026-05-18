extends Node

const SCAN_INTERVAL := 0.35
const DECISION_COOLDOWN := 0.9
const MAX_LABEL_TEXT := 80
const MAX_ACTIONS_PER_SCAN := 24

var ai: Node
var scan_accumulator := 0.0
var decision_cooldown := 0.0
var last_signature := ""
var last_state := {}
var last_action := {}
var last_action_was_executed := false


func setup(owner_ai: Node) -> void:
	ai = owner_ai
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)


func _process(delta: float) -> void:
	if ai == null:
		return
	scan_accumulator += delta
	decision_cooldown = maxf(0.0, decision_cooldown - delta)
	if scan_accumulator < SCAN_INTERVAL:
		return
	scan_accumulator = 0.0
	_scan_current_screen()


func _on_node_added(node: Node) -> void:
	if ai == null:
		return
	var node_name := String(node.name)
	if node_name.ends_with("Screen") or node_name.ends_with("Room") or node_name == "CombatUi":
		call_deferred("_scan_current_screen")


func _scan_current_screen() -> void:
	var root := get_tree().root
	var context := _detect_context(root)
	if context["screen"] == "":
		return

	var state := _extract_state(root, context)
	var actions := _collect_actions(root, context)
	if actions.is_empty():
		return

	var signature := _make_signature(context, actions)
	if signature == last_signature and decision_cooldown > 0.0:
		return

	if signature != last_signature and last_action_was_executed and !last_action.is_empty() and !last_state.is_empty():
		var reward: float = _estimate_transition_reward(last_state, state, context)
		var done: bool = String(context.get("screen", "")) == "GameOverScreen"
		ai.observe_step(last_state, last_action, reward, state, done)
		last_action_was_executed = false

	var ranked: Array = ai.rank_actions(state, actions)
	_apply_action_priors(ranked, context)
	ranked.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))
	ai.note_decision_context(context, state, ranked)

	last_signature = signature
	last_state = state
	last_action = ranked[0]["action"] if !ranked.is_empty() else {}
	last_action_was_executed = false

	if bool(ai.auto_play_enabled) and decision_cooldown <= 0.0 and !ranked.is_empty():
		if _execute_action(ranked[0]["action"]):
			last_action_was_executed = true
			decision_cooldown = DECISION_COOLDOWN


func execute_best_ranked_action() -> Dictionary:
	if ai == null:
		return {}
	if ai.last_ranked_actions.is_empty():
		_scan_current_screen()
	if ai.last_ranked_actions.is_empty():
		return {}

	var ranked_item = ai.last_ranked_actions[0]
	if !(ranked_item is Dictionary):
		return {}
	var action = ranked_item.get("action", {})
	if !(action is Dictionary):
		return {}
	if !_execute_action(action):
		return {}

	var state = ai.last_context.get("state", {}) if ai.last_context is Dictionary else {}
	last_state = state if state is Dictionary else last_state
	last_action = action
	last_action_was_executed = true
	decision_cooldown = DECISION_COOLDOWN
	return action


func _estimate_transition_reward(previous_state: Dictionary, next_state: Dictionary, context: Dictionary) -> float:
	var reward: float = 0.0
	var previous_hp: float = float(previous_state.get("hp", 0.0))
	var next_hp: float = float(next_state.get("hp", 0.0))
	if previous_hp > 0.0 and next_hp > 0.0:
		reward += (next_hp - previous_hp) * 0.02

	var previous_floor: float = float(previous_state.get("floor", 0.0))
	var next_floor: float = float(next_state.get("floor", 0.0))
	if next_floor > previous_floor:
		reward += minf((next_floor - previous_floor) * 0.1, 0.5)

	match String(context.get("screen", "")):
		"RewardsScreen":
			reward += 0.15
		"CardRewardSelectionScreen", "ChooseACardSelectionScreen", "ChooseABundleSelectionScreen":
			reward += 0.05
		"MapScreen":
			reward += 0.03
		"GameOverScreen":
			reward -= 1.0
	return reward


func _detect_context(root: Node) -> Dictionary:
	var candidates := [
		"CardRewardSelectionScreen",
		"ChooseACardSelectionScreen",
		"ChooseABundleSelectionScreen",
		"ChooseARelicSelectionScreen",
		"RewardsScreen",
		"MapScreen",
		"EventRoom",
		"RestSiteRoom",
		"TreasureRoom",
		"MerchantRoom",
		"CombatRoom",
		"GameOverScreen"
	]
	for name in candidates:
		var node := _find_visible_node_by_name(root, name)
		if node != null:
			return {
				"screen": name,
				"path": str(node.get_path())
			}
	return {
		"screen": "",
		"path": ""
	}


func _extract_state(root: Node, context: Dictionary) -> Dictionary:
	var labels := _collect_visible_labels(root, 96)
	var state := {
		"screen": context["screen"],
		"screen_path": context["path"],
		"labels": labels,
		"hp": _extract_number_after(labels, ["HP", "Health"]),
		"gold": _extract_number_after(labels, ["Gold"]),
		"floor": _extract_number_after(labels, ["Floor"]),
		"deck": _collect_card_names(root),
		"relics": [],
		"potions": [],
		"hand": _collect_hand_card_names(root),
		"enemies": _collect_enemy_summaries(root)
	}
	if float(state["hp"]) > 0.0:
		state["max_hp"] = maxf(float(state["hp"]), _extract_slash_denominator(labels))
	return state


func _collect_actions(root: Node, context: Dictionary) -> Array:
	var screen := String(context["screen"])
	var actions := []
	match screen:
		"CombatRoom":
			actions.append_array(_collect_combat_actions(root))
		"CardRewardSelectionScreen", "ChooseACardSelectionScreen", "ChooseABundleSelectionScreen":
			actions.append_array(_collect_card_choice_actions(root, screen))
		"RewardsScreen":
			actions.append_array(_collect_reward_actions(root))
		"MapScreen":
			actions.append_array(_collect_map_actions(root))
		"GameOverScreen":
			actions.append_array(_collect_named_control_actions(root, ["ContinueButton", "MainMenuButton"], "game_over"))
		_:
			actions.append_array(_collect_generic_choice_actions(root, screen))
	return actions


func _collect_combat_actions(root: Node) -> Array:
	var actions := []
	var hand := _find_visible_node_by_name(root, "Hand")
	if hand != null:
		for node in _collect_clickable_controls(hand):
			actions.append(_make_node_action("play_card", node))
	actions.append_array(_collect_named_control_actions(root, ["EndTurnButton"], "end_turn"))
	return actions


func _collect_card_choice_actions(root: Node, screen: String) -> Array:
	var actions := []
	var card_row := _find_visible_node_by_name(root, "CardRow")
	if card_row != null:
		for node in _collect_clickable_controls(card_row, false, true):
			actions.append(_make_node_action("pick_card", node))
	var alternatives := _find_visible_node_by_name(root, "RewardAlternatives")
	if alternatives != null:
		for node in _collect_clickable_controls(alternatives, true, true):
			actions.append(_make_node_action("reward_alternative", node))
	if actions.is_empty():
		actions.append_array(_collect_generic_choice_actions(root, screen))
	return actions


func _collect_reward_actions(root: Node) -> Array:
	var container := _find_visible_node_by_name(root, "RewardsContainer")
	var actions := []
	if container != null:
		for node in _collect_clickable_controls(container, true, true):
			actions.append(_make_node_action("claim_reward", node))
	if actions.is_empty():
		for node in _collect_controls_by_name_fragment(root, "RewardButton"):
			actions.append(_make_node_action("claim_reward", node))
	actions.append_array(_collect_named_control_actions(root, ["ProceedButton"], "proceed"))
	return _dedupe_actions(actions)


func _collect_map_actions(root: Node) -> Array:
	var actions := []
	for node in _collect_clickable_controls(root):
		var node_name := String(node.name).to_lower()
		if node_name.contains("mappoint") or node_name.contains("map_point") or node_name.contains("mapdot"):
			actions.append(_make_node_action("choose_map_node", node))
	return actions


func _collect_generic_choice_actions(root: Node, screen: String) -> Array:
	var actions := []
	var context_root := _find_visible_node_by_name(root, screen)
	if context_root == null:
		context_root = root
	for node in _collect_clickable_controls(context_root, true, true):
		var node_name := String(node.name)
		var lower := node_name.to_lower()
		if _looks_like_action_control(node):
			actions.append(_make_node_action(_screen_to_action_type(screen), node))
	return _dedupe_actions(actions)


func _collect_named_control_actions(root: Node, names: Array, action_type: String) -> Array:
	var actions := []
	for name in names:
		var node := _find_visible_node_by_name(root, name)
		if node != null and node is Control:
			actions.append(_make_node_action(action_type, node))
	return actions


func _make_node_action(action_type: String, node: Control) -> Dictionary:
	var label := _best_label_for_node(node)
	return {
		"type": action_type,
		"id": label if label != "" else String(node.name),
		"node_path": str(node.get_path()),
		"node_name": String(node.name),
		"label": label
	}


func _execute_action(action: Dictionary) -> bool:
	var path_text: String = String(action.get("node_path", ""))
	if path_text == "":
		return false
	var path := NodePath(path_text)
	var node := get_node_or_null(path)
	if node == null or !(node is Control) or !node.is_visible_in_tree():
		return false
	print("[StsTdAi] execute type=%s label=%s node=%s" % [
		String(action.get("type", "")),
		String(action.get("label", "")),
		path_text
	])
	if _invoke_sts_control(node):
		return true
	if node is BaseButton:
		node.pressed.emit()
		return true
	if node.has_signal("pressed"):
		node.emit_signal("pressed")
		return true
	return _click_control(node)


func _invoke_sts_control(node: Control) -> bool:
	var node_name := String(node.name).to_lower()
	var should_try := (
		node_name.contains("rewardbutton") or
		node_name.contains("eventoptionbutton") or
		node_name.contains("cardrewardalternativebutton") or
		node_name.contains("proceedbutton") or
		node_name.contains("skipbutton")
	)
	if !should_try:
		return false

	var called := false
	if node.has_method("OnPress"):
		node.call("OnPress")
		called = true
	if node.has_method("OnRelease"):
		node.call("OnRelease")
		called = true
	return called


func _click_control(node: Control) -> bool:
	var rect := node.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return false
	var position := rect.position + rect.size * 0.5
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = position
	press.global_position = position
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = position
	release.global_position = position
	get_viewport().warp_mouse(position)
	get_viewport().push_input(motion, true)
	get_viewport().push_input(press, true)
	get_viewport().push_input(release, true)
	return true


func _apply_action_priors(ranked: Array, context: Dictionary) -> void:
	for item in ranked:
		var action: Dictionary = item["action"]
		var score: float = float(item["value"])
		match String(action.get("type", "")):
			"pick_card":
				score += 0.02
			"claim_reward":
				score += 0.03
			"proceed":
				score -= 0.05
			"end_turn":
				score -= 0.01
			"choose_map_node":
				score += 0.01
		if String(context.get("screen", "")) == "GameOverScreen":
			score += 1.0
		item["value"] = score


func _collect_clickable_controls(root: Node, include_mouse_ignore := false, permissive := false) -> Array:
	var results := []
	_collect_clickable_controls_recursive(root, results, include_mouse_ignore, permissive)
	return results


func _collect_clickable_controls_recursive(node: Node, results: Array, include_mouse_ignore: bool, permissive: bool) -> void:
	if node is Control and node.is_visible_in_tree():
		var control := node as Control
		if !_is_our_hud_node(control):
			var accepts_mouse := control.mouse_filter != Control.MOUSE_FILTER_IGNORE
			if accepts_mouse or include_mouse_ignore:
				if _is_clickable_control(control, permissive):
					results.append(control)
	for child in node.get_children():
		_collect_clickable_controls_recursive(child, results, include_mouse_ignore, permissive)


func _is_clickable_control(control: Control, permissive: bool) -> bool:
	var rect := control.get_global_rect()
	if rect.size.x < 24.0 or rect.size.y < 24.0:
		return false
	if rect.size.x > 1600.0 or rect.size.y > 950.0:
		return false
	if control is Label or control is RichTextLabel:
		return false
	if control is BaseButton or control.has_signal("pressed"):
		return true
	if _looks_like_action_control(control):
		return true
	if permissive and _best_label_for_node(control) != "":
		return true
	return false


func _looks_like_action_control(node: Node) -> bool:
	var lower := String(node.name).to_lower()
	return (
		lower.contains("button") or
		lower.contains("choice") or
		lower.contains("option") or
		lower.contains("reward") or
		lower.contains("proceed") or
		lower.contains("skip")
	)


func _collect_controls_by_name_fragment(root: Node, fragment: String) -> Array:
	var results := []
	_collect_controls_by_name_fragment_recursive(root, fragment.to_lower(), results)
	return results


func _collect_controls_by_name_fragment_recursive(node: Node, fragment: String, results: Array) -> void:
	if node is Control and node.is_visible_in_tree():
		if String(node.name).to_lower().contains(fragment) and !_is_our_hud_node(node):
			results.append(node)
	for child in node.get_children():
		_collect_controls_by_name_fragment_recursive(child, fragment, results)


func _dedupe_actions(actions: Array) -> Array:
	var seen := {}
	var deduped := []
	for action in actions:
		if !(action is Dictionary):
			continue
		var path := String(action.get("node_path", ""))
		if path == "" or seen.has(path):
			continue
		seen[path] = true
		deduped.append(action)
		if deduped.size() >= MAX_ACTIONS_PER_SCAN:
			break
	return deduped


func _is_our_hud_node(node: Node) -> bool:
	var current := node
	while current != null:
		if String(current.name) == "StsTdAiHud":
			return true
		current = current.get_parent()
	return false


func _collect_visible_labels(root: Node, limit: int) -> Array:
	var labels := []
	_collect_visible_labels_recursive(root, labels, limit)
	return labels


func _collect_visible_labels_recursive(node: Node, labels: Array, limit: int) -> void:
	if labels.size() >= limit:
		return
	if node is Label or node is RichTextLabel:
		if node.is_visible_in_tree():
			var text := String(node.text).strip_edges()
			if text != "":
				labels.append(text.left(MAX_LABEL_TEXT))
	for child in node.get_children():
		_collect_visible_labels_recursive(child, labels, limit)


func _collect_card_names(root: Node) -> Array:
	var names := []
	for label in _collect_visible_labels(root, 160):
		var text := String(label)
		if text.length() > 1 and text.length() < 40 and !_looks_like_ui_text(text):
			names.append(text)
	return names


func _collect_hand_card_names(root: Node) -> Array:
	var hand := _find_visible_node_by_name(root, "Hand")
	if hand == null:
		return []
	var names := []
	for label in _collect_visible_labels(hand, 40):
		var text := String(label)
		if text.length() > 1 and text.length() < 40:
			names.append(text)
	return names


func _collect_enemy_summaries(root: Node) -> Array:
	var enemy_container := _find_visible_node_by_name(root, "EnemyContainer")
	if enemy_container == null:
		return []
	var enemies := []
	for child in enemy_container.get_children():
		if child is Control and child.is_visible_in_tree():
			enemies.append({
				"name": String(child.name),
				"hp": 0,
				"intent_damage": 0
			})
	return enemies


func _find_visible_node_by_name(root: Node, target_name: String) -> Node:
	if String(root.name) == target_name and (!(root is CanvasItem) or root.is_visible_in_tree()):
		return root
	for child in root.get_children():
		var found := _find_visible_node_by_name(child, target_name)
		if found != null:
			return found
	return null


func _best_label_for_node(node: Node) -> String:
	var labels := _collect_visible_labels(node, 8)
	if !labels.is_empty():
		return String(labels[0])
	return String(node.name)


func _extract_number_after(labels: Array, keys: Array) -> float:
	for label in labels:
		var text := String(label)
		for key in keys:
			if text.to_lower().contains(String(key).to_lower()):
				var value := _first_number(text)
				if value >= 0.0:
					return value
	return 0.0


func _extract_slash_denominator(labels: Array) -> float:
	for label in labels:
		var text := String(label)
		var slash := text.find("/")
		if slash > 0:
			var rhs := text.substr(slash + 1)
			var value := _first_number(rhs)
			if value >= 0.0:
				return value
	return 1.0


func _first_number(text: String) -> float:
	var digits := ""
	var started := false
	for i in range(text.length()):
		var c := text.substr(i, 1)
		if (c >= "0" and c <= "9") or c == ".":
			digits += c
			started = true
		elif started:
			break
	if digits == "":
		return -1.0
	return float(digits)


func _looks_like_ui_text(text: String) -> bool:
	var lower := text.to_lower()
	return lower in [
		"loot!",
		"to inspect",
		"waiting for other players...",
		"continue",
		"skip",
		"proceed"
	]


func _screen_to_action_type(screen: String) -> String:
	if screen.contains("Event"):
		return "event_option"
	if screen.contains("Rest"):
		return "rest_site_choice"
	if screen.contains("Treasure"):
		return "treasure_choice"
	if screen.contains("Merchant"):
		return "shop_choice"
	return "generic_choice"


func _make_signature(context: Dictionary, actions: Array) -> String:
	var parts := [String(context.get("screen", "")), String(context.get("path", "")), str(actions.size())]
	for action in actions:
		parts.append(String(action.get("node_path", "")))
	return "|".join(parts)
