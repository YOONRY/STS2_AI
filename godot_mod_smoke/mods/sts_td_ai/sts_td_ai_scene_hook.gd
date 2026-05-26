extends Node

const SCAN_INTERVAL := 0.35
const DECISION_COOLDOWN := 0.9
const MAX_LABEL_TEXT := 80
const MAX_ACTIONS_PER_SCAN := 24
const CARD_DRAG_STEPS := 12
const CARD_DRAG_STEP_INTERVAL := 0.025
const CARD_DROP_DELAY := 0.05

var ai: Node
var scan_accumulator := 0.0
var decision_cooldown := 0.0
var last_signature := ""
var last_state := {}
var last_action := {}
var last_action_was_executed := false
var pending_pointer_drag := {}


func setup(owner_ai: Node) -> void:
	ai = owner_ai
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)


func _process(delta: float) -> void:
	if ai == null:
		return
	if !pending_pointer_drag.is_empty():
		var detail := String(pending_pointer_drag.get("label", "card"))
		_advance_pending_pointer_drag(delta)
		ai.note_agent_status({
			"phase": "dragging",
			"detail": detail
		})
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
		ai.note_agent_status({
			"phase": "scanning",
			"detail": "no active run screen"
		})
		return

	ai.note_agent_status({
		"phase": "scanning",
		"detail": String(context["screen"])
	})
	var state := _extract_state(root, context)
	var actions := _collect_actions(root, context, state)
	_update_combat_state_from_actions(state, actions, context)
	if actions.is_empty():
		ai.note_agent_status({
			"phase": "waiting",
			"detail": "no actions on %s" % String(context["screen"])
		})
		return

	var signature := _make_signature(context, actions, state)
	if signature == last_signature and decision_cooldown > 0.0:
		ai.note_agent_status({
			"phase": "cooldown",
			"detail": "%.1fs before retry" % decision_cooldown
		})
		return

	if signature != last_signature and last_action_was_executed and !last_action.is_empty() and !last_state.is_empty():
		var reward: float = _estimate_transition_reward(last_state, state, context)
		var done: bool = String(context.get("screen", "")) == "GameOverScreen"
		ai.observe_step(last_state, last_action, reward, state, done)
		last_action_was_executed = false

	var ranked: Array = ai.rank_actions(state, actions)
	_apply_action_priors(ranked, context, state)
	ranked.sort_custom(func(a, b): return float(a["value"]) > float(b["value"]))
	ai.note_decision_context(context, state, ranked)
	ai.note_agent_status({
		"phase": "thinking",
		"detail": "%d actions ranked" % ranked.size()
	})

	last_signature = signature
	last_state = state
	last_action = ranked[0]["action"] if !ranked.is_empty() else {}
	last_action_was_executed = false

	if bool(ai.auto_play_enabled) and decision_cooldown <= 0.0 and !ranked.is_empty():
		var auto_action: Dictionary = ranked[0]["action"]
		ai.note_agent_status({
			"phase": "acting",
			"detail": _describe_action(auto_action)
		})
		if _execute_action(auto_action):
			last_action_was_executed = true
			decision_cooldown = DECISION_COOLDOWN
			ai.note_agent_status({
				"phase": "clicked",
				"detail": _describe_action(auto_action)
			})
		else:
			ai.note_agent_status({
				"phase": "failed",
				"detail": _describe_action(auto_action)
			})
	elif !bool(ai.auto_play_enabled):
		ai.note_agent_status({
			"phase": "watching",
			"detail": "auto is off"
		})


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
	ai.note_agent_status({
		"phase": "acting",
		"detail": _describe_action(action)
	})
	if !_execute_action(action):
		ai.note_agent_status({
			"phase": "failed",
			"detail": _describe_action(action)
		})
		return {}

	var state = ai.last_context.get("state", {}) if ai.last_context is Dictionary else {}
	last_state = state if state is Dictionary else last_state
	last_action = action
	last_action_was_executed = true
	decision_cooldown = DECISION_COOLDOWN
	ai.note_agent_status({
		"phase": "clicked",
		"detail": _describe_action(action)
	})
	return action


func _update_combat_state_from_actions(state: Dictionary, actions: Array, context: Dictionary) -> void:
	if String(context.get("screen", "")) != "CombatRoom":
		return
	var playable_count := 0
	var unplayable_count := 0
	var known_cost_count := 0
	var lowest_playable_cost := 999.0
	for action in actions:
		if !(action is Dictionary) or String(action.get("type", "")) != "play_card":
			continue
		if float(action.get("card_cost", -1.0)) >= 0.0:
			known_cost_count += 1
		if bool(action.get("playable", true)):
			playable_count += 1
			var cost := float(action.get("card_cost", -1.0))
			if cost >= 0.0:
				lowest_playable_cost = minf(lowest_playable_cost, cost)
		else:
			unplayable_count += 1
	state["playable_card_count"] = playable_count
	state["unplayable_card_count"] = unplayable_count
	state["known_card_cost_count"] = known_cost_count
	if lowest_playable_cost < 999.0:
		state["lowest_playable_card_cost"] = lowest_playable_cost


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
		"ChooseARelicSelection",
		"ChooseARelicSelectionScreen",
		"DeckCardSelectScreen",
		"TransformSelectScreen",
		"DeckUpgradeSelectScreen",
		"DeckEnchantSelectScreen",
		"SimpleCardSelectScreen",
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
	var energy_info := _extract_energy_info(root, labels)
	var state := {
		"screen": context["screen"],
		"screen_path": context["path"],
		"labels": labels,
		"hp": _extract_number_after(labels, ["HP", "Health"]),
		"gold": _extract_number_after(labels, ["Gold"]),
		"floor": _extract_number_after(labels, ["Floor"]),
		"energy": float(energy_info.get("energy", -1.0)),
		"energy_known": bool(energy_info.get("known", false)),
		"deck": _collect_card_names(root),
		"relics": [],
		"potions": [],
		"hand": _collect_hand_card_names(root),
		"enemies": _collect_enemy_summaries(root),
		"playable_card_count": 0,
		"unplayable_card_count": 0
	}
	if float(state["hp"]) > 0.0:
		state["max_hp"] = maxf(float(state["hp"]), _extract_slash_denominator(labels))
	return state


func _collect_actions(root: Node, context: Dictionary, state := {}) -> Array:
	var screen := String(context["screen"])
	var embedded_deck_actions := _collect_embedded_deck_card_selection_actions(root, screen)
	if !embedded_deck_actions.is_empty():
		return embedded_deck_actions

	var actions := []
	match screen:
		"CombatRoom":
			actions.append_array(_collect_combat_actions(root, state))
		"CardRewardSelectionScreen", "ChooseACardSelectionScreen", "ChooseABundleSelectionScreen":
			actions.append_array(_collect_card_choice_actions(root, screen))
		"ChooseARelicSelection", "ChooseARelicSelectionScreen":
			actions.append_array(_collect_relic_choice_actions(root, screen))
		"DeckCardSelectScreen", "TransformSelectScreen", "DeckUpgradeSelectScreen", "DeckEnchantSelectScreen", "SimpleCardSelectScreen":
			actions.append_array(_collect_deck_card_selection_actions(root, screen))
		"RewardsScreen":
			actions.append_array(_collect_reward_actions(root))
		"MapScreen":
			actions.append_array(_collect_map_actions(root))
		"GameOverScreen":
			actions.append_array(_collect_named_control_actions(root, ["ContinueButton", "MainMenuButton"], "game_over"))
		_:
			actions.append_array(_collect_generic_choice_actions(root, screen))
	return actions


func _collect_embedded_deck_card_selection_actions(root: Node, screen: String) -> Array:
	if !["EventRoom", "MerchantRoom", "RestSiteRoom", "TreasureRoom"].has(screen):
		return []
	var actions := _collect_deck_card_selection_actions(root, screen, true)
	var deck_actions := []
	for action in actions:
		if !(action is Dictionary):
			continue
		var action_type := String(action.get("type", ""))
		if action_type == "confirm_card_selection" or _is_deck_card_action_type(action_type):
			deck_actions.append(action)
	return _dedupe_actions(deck_actions)


func _is_deck_card_action_type(action_type: String) -> bool:
	return [
		"select_deck_card",
		"remove_card",
		"transform_card",
		"upgrade_card",
		"enchant_card"
	].has(action_type)


func _collect_combat_actions(root: Node, state: Dictionary) -> Array:
	var actions := []
	var energy := float(state.get("energy", -1.0))
	var energy_known := bool(state.get("energy_known", false))
	var hand := _find_visible_node_by_name(root, "Hand")
	if hand != null:
		for node in _collect_clickable_controls(hand):
			var action := _make_node_action("play_card", node)
			_annotate_playable_card_action(action, energy, energy_known)
			actions.append(action)
	actions.append_array(_collect_end_turn_actions(root))
	return actions


func _annotate_playable_card_action(action: Dictionary, energy: float, energy_known: bool) -> void:
	var card_cost := float(action.get("card_cost", -1.0))
	var playable := true
	var shortfall := 0.0
	if energy_known and card_cost >= 0.0:
		shortfall = maxf(card_cost - energy, 0.0)
		playable = shortfall <= 0.0
	action["playable"] = playable
	action["energy"] = energy
	action["energy_known"] = energy_known
	action["energy_shortfall"] = shortfall
	if energy_known and card_cost >= 0.0:
		action["energy_remaining_after"] = energy - card_cost


func _collect_end_turn_actions(root: Node) -> Array:
	var actions := _collect_named_control_actions(root, ["EndTurnButton", "EndTurn"], "end_turn")
	for node in _collect_controls_by_name_fragments(root, ["EndTurn", "end_turn", "TurnEnd", "turn_end"]):
		if node is Control and node.is_visible_in_tree():
			actions.append(_make_node_action("end_turn", node))
	if actions.is_empty():
		for node in _collect_clickable_controls(root, true, false):
			var lower := String(node.name).to_lower()
			var label := _best_label_for_node(node).to_lower()
			if lower.contains("endturn") or lower.contains("turnend") or label.contains("end turn") or label.contains("턴 종료"):
				actions.append(_make_node_action("end_turn", node))
	return _dedupe_actions(actions)


func _collect_card_choice_actions(root: Node, screen: String) -> Array:
	var screen_node := _find_visible_node_by_name(root, screen)
	if screen_node == null:
		screen_node = root

	var confirm_actions := _collect_visible_confirm_actions(screen_node)
	if !confirm_actions.is_empty():
		return confirm_actions

	var actions := []
	var card_row := _find_visible_node_by_name(screen_node, "CardRow")
	if card_row != null:
		actions.append_array(_collect_card_holder_actions(card_row, "choose_card"))
		actions.append_array(_collect_reward_card_choice_actions(card_row, "choose_card"))
		for node in _collect_clickable_controls(card_row, false, true):
			actions.append(_make_node_action("pick_card", node))
	actions.append_array(_collect_reward_card_choice_actions(screen_node, "choose_card"))
	var alternatives := _find_visible_node_by_name(screen_node, "RewardAlternatives")
	if alternatives != null:
		for node in _collect_clickable_controls(alternatives, true, true):
			actions.append(_make_node_action("reward_alternative", node))
	for node in _collect_controls_by_name_fragments(screen_node, ["SkipButton", "SkipRewardButton", "ProceedButton"]):
		if node is Control and node.is_visible_in_tree():
			actions.append(_make_node_action("skip_card_reward", node))
	if actions.is_empty():
		actions.append_array(_collect_generic_choice_actions(screen_node, screen))
	return _dedupe_actions(actions)


func _collect_relic_choice_actions(root: Node, screen: String) -> Array:
	var screen_node := _find_visible_node_by_name(root, screen)
	if screen_node == null:
		screen_node = _find_visible_node_by_name(root, "ChooseARelicSelection")
	if screen_node == null:
		screen_node = root

	var actions := []
	var relic_row := _find_visible_node_by_name(screen_node, "RelicRow")
	if relic_row != null:
		actions.append_array(_collect_relic_holder_actions(relic_row, "choose_relic"))
	if actions.is_empty():
		actions.append_array(_collect_relic_holder_actions(screen_node, "choose_relic"))
	for node in _collect_controls_by_name_fragment(screen_node, "SkipButton"):
		actions.append(_make_node_action("skip_relic", node))
	return _dedupe_actions(actions)


func _collect_relic_holder_actions(root: Node, action_type: String) -> Array:
	var actions := []
	_collect_relic_holder_actions_recursive(root, action_type, actions)
	return _dedupe_actions(actions)


func _collect_relic_holder_actions_recursive(node: Node, action_type: String, actions: Array) -> void:
	if node is Control and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var lower := String(node.name).to_lower()
		if lower == "hitbox" and _has_ancestor_name_fragment(node, "relic"):
			actions.append(_make_node_action(action_type, node))
		elif lower.contains("relicbasicholder") or lower.contains("treasurerelicholder") or lower.contains("relicinventoryholder"):
			actions.append(_make_node_action(action_type, node))
	for child in node.get_children():
		_collect_relic_holder_actions_recursive(child, action_type, actions)


func _collect_deck_card_selection_actions(root: Node, screen: String, search_global_overlay := false) -> Array:
	var screen_node := root if search_global_overlay else _find_visible_node_by_name(root, screen)
	if screen_node == null:
		screen_node = root

	var confirm_actions := _collect_visible_confirm_actions(screen_node)
	if !confirm_actions.is_empty():
		return confirm_actions

	var action_type := _deck_card_action_type(screen_node, screen)
	var actions := []
	for grid in _collect_controls_by_name_fragment(screen_node, "CardGrid"):
		actions.append_array(_collect_card_holder_actions(grid, action_type))
	if actions.is_empty():
		actions.append_array(_collect_card_holder_actions(screen_node, action_type))
	if actions.is_empty():
		for node in _collect_clickable_controls(screen_node, true, true):
			if _has_ancestor_name_fragment(node, "cardgrid") or String(node.name).to_lower().contains("card"):
				actions.append(_make_node_action(action_type, node))
	return _dedupe_actions(actions)


func _collect_visible_confirm_actions(root: Node) -> Array:
	var actions := []
	var preview_container := _find_visible_preview_container(root)
	if preview_container == null:
		return actions
	for node in _collect_controls_by_name_fragment(preview_container, "PreviewConfirm"):
		if node is Control and node.is_visible_in_tree():
			actions.append(_make_node_action("confirm_card_selection", node))
	if !actions.is_empty():
		return _dedupe_actions(actions)
	for node in _collect_controls_by_name_fragment(preview_container, "Confirm"):
		if node is Control and node.is_visible_in_tree():
			actions.append(_make_node_action("confirm_card_selection", node))
	return _dedupe_actions(actions)


func _deck_card_action_type(root: Node, screen: String) -> String:
	var text := " ".join(_collect_visible_labels(root, 80)).to_lower()
	if text.contains("remove") or text.contains("제거") or text.contains("삭제"):
		return "remove_card"
	if text.contains("transform") or text.contains("변화") or text.contains("변형"):
		return "transform_card"
	if text.contains("upgrade") or text.contains("강화"):
		return "upgrade_card"
	if text.contains("enchant") or text.contains("부여") or text.contains("인챈트"):
		return "enchant_card"
	match screen:
		"TransformSelectScreen":
			return "transform_card"
		"DeckUpgradeSelectScreen":
			return "upgrade_card"
		"DeckEnchantSelectScreen":
			return "enchant_card"
		"DeckCardSelectScreen":
			return "remove_card"
	return "select_deck_card"


func _collect_card_holder_actions(root: Node, action_type: String) -> Array:
	var actions := []
	_collect_card_holder_actions_recursive(root, action_type, actions)
	return _dedupe_actions(actions)


func _collect_card_holder_actions_recursive(node: Node, action_type: String, actions: Array) -> void:
	if node is Control and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var lower := String(node.name).to_lower()
		if lower == "hitbox" and _has_ancestor_name_fragment(node, "cardholder"):
			actions.append(_make_node_action(action_type, node))
		elif lower.contains("gridcardholder") or lower.contains("cardholder"):
			var hitbox := _find_visible_node_by_name(node, "Hitbox")
			if hitbox != null and hitbox is Control:
				actions.append(_make_node_action(action_type, hitbox))
	for child in node.get_children():
		_collect_card_holder_actions_recursive(child, action_type, actions)


func _collect_reward_card_choice_actions(root: Node, action_type: String) -> Array:
	var actions := []
	_collect_reward_card_choice_actions_recursive(root, action_type, actions)
	return _dedupe_actions(actions)


func _collect_reward_card_choice_actions_recursive(node: Node, action_type: String, actions: Array) -> void:
	if node is Control and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var control := node as Control
		if _looks_like_reward_card_control(control):
			var target := _card_choice_click_target(control)
			if target != null:
				actions.append(_make_node_action(action_type, target))
	for child in node.get_children():
		_collect_reward_card_choice_actions_recursive(child, action_type, actions)


func _looks_like_reward_card_control(control: Control) -> bool:
	var rect := control.get_global_rect()
	if rect.size.x < 40.0 or rect.size.y < 60.0:
		return false
	if rect.size.x > 520.0 or rect.size.y > 720.0:
		return false
	var lower := String(control.name).to_lower()
	if lower.contains("screen") or lower.contains("container") or lower.contains("row") or lower.contains("grid"):
		return false
	if lower == "hitbox":
		return (
			_has_ancestor_name_fragment(control, "cardholder") or
			_has_ancestor_name_fragment(control, "cardreward") or
			_has_ancestor_name_fragment(control, "rewardcard") or
			_has_ancestor_name_fragment(control, "cardchoice") or
			_has_ancestor_name_fragment(control, "cardoption")
		)
	if lower.contains("cardholder") or lower.contains("cardreward") or lower.contains("rewardcard") or lower.contains("cardchoice") or lower.contains("cardoption"):
		return true
	return _best_named_label_for_node(control, "TitleLabel") != ""


func _card_choice_click_target(control: Control) -> Control:
	if String(control.name).to_lower() == "hitbox":
		return control
	var hitbox := _find_visible_node_by_name(control, "Hitbox")
	if hitbox != null and hitbox is Control:
		return hitbox
	return control


func _collect_reward_actions(root: Node) -> Array:
	var card_selection_actions := _collect_rewards_screen_card_selection_actions(root)
	if !card_selection_actions.is_empty():
		return card_selection_actions

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


func _collect_rewards_screen_card_selection_actions(root: Node) -> Array:
	if !_looks_like_card_reward_selection_overlay(root):
		return []
	var actions := []
	var confirm_actions := _collect_visible_confirm_actions(root)
	if !confirm_actions.is_empty():
		return confirm_actions

	var card_row := _find_visible_node_by_name(root, "CardRow")
	if card_row != null:
		actions.append_array(_collect_card_holder_actions(card_row, "choose_card"))
		actions.append_array(_collect_reward_card_choice_actions(card_row, "choose_card"))
	actions.append_array(_collect_reward_card_choice_actions(root, "choose_card"))

	for node in _collect_controls_by_name_fragments(root, ["SkipButton", "SkipRewardButton", "ProceedButton"]):
		if node is Control and node.is_visible_in_tree():
			actions.append(_make_node_action("skip_card_reward", node))
	return _dedupe_actions(actions)


func _looks_like_card_reward_selection_overlay(root: Node) -> bool:
	var text := " ".join(_collect_visible_labels(root, 120)).to_lower()
	return (
		text.contains("select a card") or
		text.contains("choose a card") or
		text.contains("add a card") or
		text.contains("카드를 선택") or
		text.contains("카드 선택") or
		text.contains("덱에 추가")
	)


func _collect_map_actions(root: Node) -> Array:
	var map_screen := _find_visible_node_by_name(root, "MapScreen")
	if map_screen == null:
		map_screen = root
	var actions := []
	_collect_map_point_actions_recursive(map_screen, actions)
	return _dedupe_actions(actions)


func _collect_map_point_actions_recursive(node: Node, actions: Array) -> void:
	if node is Control and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var lower := String(node.name).to_lower()
		if lower.contains("mappoint") or lower.contains("map_point") or lower.contains("mapdot"):
			var rect := (node as Control).get_global_rect()
			if rect.size.x >= 24.0 and rect.size.y >= 24.0 and rect.size.x <= 260.0 and rect.size.y <= 260.0:
				actions.append(_make_node_action("choose_map_node", node))
	for child in node.get_children():
		_collect_map_point_actions_recursive(child, actions)


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
	var card_name := _best_card_name_for_node(node)
	var card_type := _best_named_label_for_node(node, "TypeLabel")
	var card_cost := _first_number(_best_named_label_for_node(node, "EnergyLabel"))
	var card_text := " ".join(_collect_nearby_card_labels(node, 16))
	return {
		"type": action_type,
		"id": card_name if card_name != "" else (label if label != "" else String(node.name)),
		"node_path": str(node.get_path()),
		"node_name": String(node.name),
		"label": card_name if card_name != "" else label,
		"card_name": card_name,
		"card_type": card_type,
		"card_cost": card_cost,
		"card_text": card_text
	}


func _describe_action(action: Dictionary) -> String:
	var label := String(action.get("label", action.get("id", ""))).strip_edges()
	var action_type := String(action.get("type", "action"))
	var node_name := String(action.get("node_name", ""))
	if label != "":
		return "%s %s" % [action_type, label.left(32)]
	if node_name != "":
		return "%s %s" % [action_type, node_name]
	return action_type


func _execute_action(action: Dictionary) -> bool:
	var path_text: String = String(action.get("node_path", ""))
	if path_text == "":
		return false
	var path := NodePath(path_text)
	var node := get_node_or_null(path)
	if node == null or !(node is Control) or !node.is_visible_in_tree():
		return false
	var action_type := String(action.get("type", ""))
	print("[StsTdAi] execute type=%s label=%s node=%s" % [
		action_type,
		String(action.get("label", "")),
		path_text
	])
	if action_type == "play_card":
		if action.has("playable") and !bool(action.get("playable", true)):
			print("[StsTdAi] skip unplayable card label=%s cost=%.1f energy=%.1f" % [
				String(action.get("label", "")),
				float(action.get("card_cost", -1.0)),
				float(action.get("energy", -1.0))
			])
			return false
		return _play_combat_card(node, action)
	if _is_card_choice_execution_action(action_type):
		return _activate_choice_control(node)
	if _prefers_pointer_click(action_type):
		return _click_control(node)
	if _invoke_sts_control(node):
		_click_control(node)
		return true
	if node is BaseButton:
		node.pressed.emit()
		return true
	if node.has_signal("pressed"):
		node.emit_signal("pressed")
		return true
	return _click_control(node)


func _prefers_pointer_click(action_type: String) -> bool:
	return [
		"pick_card",
		"choose_card",
		"select_deck_card",
		"remove_card",
		"transform_card",
		"upgrade_card",
		"enchant_card",
		"choose_relic",
		"choose_map_node",
		"end_turn",
		"skip_card_reward"
	].has(action_type)


func _is_card_choice_execution_action(action_type: String) -> bool:
	return [
		"pick_card",
		"choose_card",
		"reward_alternative",
		"confirm_card_selection",
		"skip_card_reward",
		"claim_reward"
	].has(action_type)


func _activate_choice_control(node: Control) -> bool:
	var target := _card_choice_click_target(node)
	if target != null and _invoke_sts_control(target):
		return true
	if target != node and _invoke_sts_control(node):
		return true
	if target != null:
		return _click_control(target)
	return _click_control(node)


func _play_combat_card(node: Control, action: Dictionary) -> bool:
	var from := _control_center(node)
	if from.x < 0.0:
		return false
	var target := _combat_card_target_position(action, from)
	return _drag_pointer(from, target, _describe_action(action))


func _combat_card_target_position(action: Dictionary, from: Vector2) -> Vector2:
	var wants_enemy := _action_wants_enemy_target(action)
	var enemy_target := _first_enemy_target_position()
	if wants_enemy:
		if enemy_target.x < 0.0:
			enemy_target = _fallback_enemy_target_position()
		print("[StsTdAi] combat target enemy label=%s type=%s text=%s to=%s" % [
			String(action.get("label", "")),
			String(action.get("card_type", "")),
			String(action.get("card_text", "")).left(80),
			str(enemy_target)
		])
		return enemy_target

	var viewport_size := get_viewport().get_visible_rect().size
	var upward := Vector2(
		viewport_size.x * 0.5,
		clampf(from.y - 520.0, viewport_size.y * 0.25, viewport_size.y * 0.42)
	)
	print("[StsTdAi] combat target playzone label=%s type=%s to=%s" % [
		String(action.get("label", "")),
		String(action.get("card_type", "")),
		str(upward)
	])
	return upward


func _action_wants_enemy_target(action: Dictionary) -> bool:
	var card_type := String(action.get("card_type", "")).to_lower()
	var label := String(action.get("label", "")).to_lower()
	var card_text := String(action.get("card_text", "")).to_lower()
	var combined := "%s %s %s" % [card_type, label, card_text]
	var explicitly_non_target := (
		card_type.contains("skill") or
		card_type.contains("스킬") or
		card_type.contains("power") or
		card_type.contains("파워")
	)
	if card_type.contains("attack") or card_type.contains("공격"):
		return true
	for keyword in ["strike", "bash", "타격", "강타"]:
		if combined.contains(keyword):
			return true
	if explicitly_non_target:
		return false
	for keyword in ["damage", "deal", "vulnerable", "weak", "poison", "피해", "취약", "약화", "독"]:
		if combined.contains(keyword):
			return true
	return false


func _first_enemy_target_position() -> Vector2:
	var enemy_container := _find_visible_node_by_name(get_tree().root, "EnemyContainer")
	if enemy_container == null:
		return Vector2(-1.0, -1.0)
	var hitbox_target := _best_visible_control_center_by_name_fragment(enemy_container, "Hitbox")
	if hitbox_target.x >= 0.0:
		return hitbox_target
	for child in enemy_container.get_children():
		if child is Control and child.is_visible_in_tree():
			var center := _control_center(child)
			if center.x >= 0.0:
				return center
	if enemy_container is Control:
		var center := _control_center(enemy_container)
		if center.x >= 0.0:
			return center
	return Vector2(-1.0, -1.0)


func _fallback_enemy_target_position() -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	return Vector2(viewport_size.x * 0.68, viewport_size.y * 0.45)


func _invoke_sts_control(node: Control) -> bool:
	var node_name := String(node.name).to_lower()
	var should_try := (
		node_name.contains("rewardbutton") or
		node_name.contains("eventoptionbutton") or
		node_name.contains("cardrewardalternativebutton") or
		node_name.contains("proceedbutton") or
		node_name.contains("skipbutton") or
		node_name.contains("endturn") or
		node_name.contains("turnend") or
		node_name.contains("confirm") or
		node_name.contains("relic") or
		node_name.contains("hitbox") or
		node_name.contains("mappoint") or
		node_name.contains("map_point")
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
	var position := _control_center(node)
	if position.x < 0.0:
		return false
	return _click_pointer(position)


func _control_center(node: Control) -> Vector2:
	var rect := node.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return Vector2(-1.0, -1.0)
	return rect.position + rect.size * 0.5


func _click_pointer(position: Vector2) -> bool:
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


func _drag_pointer(from: Vector2, to: Vector2, label := "card") -> bool:
	if from.x < 0.0 or to.x < 0.0:
		return false
	if !pending_pointer_drag.is_empty():
		return false
	pending_pointer_drag = {
		"phase": "press",
		"from": from,
		"to": to,
		"last": from,
		"index": 0,
		"elapsed": 0.0,
		"label": label
	}
	return true


func _advance_pending_pointer_drag(delta: float) -> void:
	if pending_pointer_drag.is_empty():
		return
	var phase := String(pending_pointer_drag.get("phase", "press"))
	var from: Vector2 = pending_pointer_drag.get("from", Vector2.ZERO)
	var to: Vector2 = pending_pointer_drag.get("to", Vector2.ZERO)
	var last: Vector2 = pending_pointer_drag.get("last", from)
	var elapsed := float(pending_pointer_drag.get("elapsed", 0.0)) + delta
	pending_pointer_drag["elapsed"] = elapsed

	match phase:
		"press":
			get_viewport().warp_mouse(from)
			_send_mouse_motion(from, Vector2.ZERO, false)
			_send_mouse_button(from, true)
			pending_pointer_drag["phase"] = "move"
			pending_pointer_drag["elapsed"] = 0.0
		"move":
			if elapsed < CARD_DRAG_STEP_INTERVAL:
				return
			var index := int(pending_pointer_drag.get("index", 0)) + 1
			var t := minf(float(index) / float(CARD_DRAG_STEPS), 1.0)
			var position := from.lerp(to, t)
			get_viewport().warp_mouse(position)
			_send_mouse_motion(position, position - last, true)
			pending_pointer_drag["last"] = position
			pending_pointer_drag["index"] = index
			pending_pointer_drag["elapsed"] = 0.0
			if index >= CARD_DRAG_STEPS:
				pending_pointer_drag["phase"] = "release"
		"release":
			if elapsed < CARD_DROP_DELAY:
				return
			get_viewport().warp_mouse(to)
			_send_mouse_motion(to, to - last, true)
			_send_mouse_button(to, false)
			pending_pointer_drag.clear()
		_:
			pending_pointer_drag.clear()


func _send_mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_viewport().push_input(event, true)


func _send_mouse_motion(position: Vector2, relative: Vector2, button_down: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if button_down else 0
	get_viewport().push_input(event, true)


func _apply_action_priors(ranked: Array, context: Dictionary, state := {}) -> void:
	var screen := String(context.get("screen", ""))
	var energy_known := bool(state.get("energy_known", false))
	var energy := float(state.get("energy", -1.0))
	var playable_count := int(state.get("playable_card_count", 0))
	for item in ranked:
		var action: Dictionary = item["action"]
		var score: float = float(item["value"])
		match String(action.get("type", "")):
			"play_card":
				if action.has("playable") and !bool(action.get("playable", true)):
					score -= 4.0 + float(action.get("energy_shortfall", 0.0)) * 0.75
				elif screen == "CombatRoom":
					score += 0.08
			"pick_card":
				score += 0.02
			"choose_card":
				score += 0.06
			"select_deck_card":
				score += 0.025
			"confirm_card_selection":
				score += 0.85
			"claim_reward":
				score += 0.03
			"proceed":
				score -= 0.05
			"reward_alternative":
				score -= 0.12
			"skip_card_reward":
				score -= 0.35
			"end_turn":
				score += 0.02
				if screen == "CombatRoom":
					if playable_count <= 0:
						score += 3.0
					elif energy_known and energy <= 0.0:
						score += 2.4
					else:
						score -= 0.18
			"choose_map_node":
				score += 0.01
		if screen == "GameOverScreen":
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
	if _looks_like_passive_container(control):
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
		lower.contains("option") or
		lower.contains("hitbox") or
		lower.contains("proceed") or
		lower.contains("skip")
	)


func _looks_like_passive_container(node: Node) -> bool:
	var lower := String(node.name).to_lower()
	return (
		lower.contains("container") or
		lower.contains("screen") or
		lower.contains("panel") or
		lower.contains("background") or
		lower.contains("mask") or
		lower.contains("banner") or
		lower.contains("header") or
		lower.contains("description") or
		lower.contains("row") or
		lower.contains("grid")
	)


func _collect_controls_by_name_fragment(root: Node, fragment: String) -> Array:
	var results := []
	_collect_controls_by_name_fragment_recursive(root, fragment.to_lower(), results)
	return results


func _collect_controls_by_name_fragments(root: Node, fragments: Array) -> Array:
	var results := []
	var seen := {}
	for fragment in fragments:
		for node in _collect_controls_by_name_fragment(root, String(fragment)):
			if !(node is Control):
				continue
			var path := str(node.get_path())
			if seen.has(path):
				continue
			seen[path] = true
			results.append(node)
	return results


func _collect_controls_by_name_fragment_recursive(node: Node, fragment: String, results: Array) -> void:
	if node is Control and node.is_visible_in_tree():
		if String(node.name).to_lower().contains(fragment) and !_is_our_hud_node(node):
			results.append(node)
	for child in node.get_children():
		_collect_controls_by_name_fragment_recursive(child, fragment, results)


func _has_ancestor_name_fragment(node: Node, fragment: String) -> bool:
	var current := node
	var lower_fragment := fragment.to_lower()
	while current != null:
		if String(current.name).to_lower().contains(lower_fragment):
			return true
		current = current.get_parent()
	return false


func _find_visible_preview_container(root: Node) -> Node:
	if String(root.name).to_lower().contains("previewcontainer"):
		if !(root is CanvasItem) or root.is_visible_in_tree():
			return root
	for child in root.get_children():
		var found := _find_visible_preview_container(child)
		if found != null:
			return found
	return null


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


func _extract_energy_info(root: Node, labels: Array) -> Dictionary:
	var labeled_value := _extract_labeled_energy_value(labels)
	if labeled_value >= 0.0:
		return {
			"energy": labeled_value,
			"known": true
		}

	var energy_nodes := _collect_controls_by_name_fragments(root, [
		"Energy",
		"energy",
		"Mana",
		"mana"
	])
	for node in energy_nodes:
		if !(node is Control) or _is_our_hud_node(node):
			continue
		var value := _extract_energy_from_node_scope(node)
		if value >= 0.0:
			return {
				"energy": value,
				"known": true
			}
		value = _extract_nearest_energy_label(root, node)
		if value >= 0.0:
			return {
				"energy": value,
				"known": true
			}

	return {
		"energy": -1.0,
		"known": false
	}


func _extract_labeled_energy_value(labels: Array) -> float:
	for label in labels:
		var text := String(label)
		var lower := text.to_lower()
		var looks_like_energy_label := (
			text.length() <= 24 and (
				lower.begins_with("energy") or
				lower.begins_with("mana") or
				text.begins_with("에너지")
			)
		)
		if looks_like_energy_label:
			var value := _first_number(text)
			if _is_reasonable_energy_value(value):
				return value
	return -1.0


func _extract_energy_from_node_scope(node: Node) -> float:
	var current := node
	var depth := 0
	while current != null and depth < 3:
		var labels := _collect_visible_labels(current, 12)
		var value := _extract_labeled_energy_value(labels)
		if value >= 0.0:
			return value
		value = _first_reasonable_energy_value(labels)
		if value >= 0.0:
			return value
		current = current.get_parent()
		depth += 1
	return -1.0


func _extract_nearest_energy_label(root: Node, node: Control) -> float:
	var center := _control_center(node)
	if center.x < 0.0:
		return -1.0
	var labels := []
	_collect_visible_label_infos(root, labels, 220)
	var best_value := -1.0
	var best_distance := 999999.0
	for info in labels:
		if !(info is Dictionary):
			continue
		var value := _first_number(String(info.get("text", "")))
		if !_is_reasonable_energy_value(value):
			continue
		var distance := center.distance_to(info.get("center", center))
		if distance < best_distance and distance <= 220.0:
			best_distance = distance
			best_value = value
	return best_value


func _collect_visible_label_infos(node: Node, labels: Array, limit: int) -> void:
	if labels.size() >= limit:
		return
	if (node is Label or node is RichTextLabel) and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var text := String(node.text).strip_edges()
		if text != "":
			var rect := (node as Control).get_global_rect()
			if rect.size.x > 0.0 and rect.size.y > 0.0:
				labels.append({
					"text": text.left(MAX_LABEL_TEXT),
					"center": rect.position + rect.size * 0.5
				})
	for child in node.get_children():
		_collect_visible_label_infos(child, labels, limit)


func _first_reasonable_energy_value(labels: Array) -> float:
	for label in labels:
		var text := String(label).strip_edges()
		if text == "":
			continue
		var value := _first_number(text)
		if _is_reasonable_energy_value(value):
			return value
	return -1.0


func _is_reasonable_energy_value(value: float) -> bool:
	return value >= 0.0 and value <= 10.0


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


func _find_first_visible_control_by_name_fragment(root: Node, fragment: String) -> Control:
	var lower_fragment := fragment.to_lower()
	if root is Control and root.is_visible_in_tree() and String(root.name).to_lower().contains(lower_fragment):
		return root
	for child in root.get_children():
		var found := _find_first_visible_control_by_name_fragment(child, fragment)
		if found != null:
			return found
	return null


func _best_visible_control_center_by_name_fragment(root: Node, fragment: String) -> Vector2:
	var candidates := []
	_collect_visible_control_centers_by_name_fragment(root, fragment.to_lower(), candidates)
	var best := Vector2(-1.0, -1.0)
	var best_area := -1.0
	for candidate in candidates:
		if !(candidate is Dictionary):
			continue
		var area := float(candidate.get("area", 0.0))
		if area > best_area:
			best_area = area
			best = candidate.get("center", best)
	return best


func _collect_visible_control_centers_by_name_fragment(node: Node, fragment: String, candidates: Array) -> void:
	if node is Control and node.is_visible_in_tree() and !_is_our_hud_node(node):
		var lower := String(node.name).to_lower()
		if lower.contains(fragment):
			var rect := (node as Control).get_global_rect()
			if rect.size.x >= 16.0 and rect.size.y >= 16.0 and rect.size.x <= 900.0 and rect.size.y <= 700.0:
				candidates.append({
					"center": rect.position + rect.size * 0.5,
					"area": rect.size.x * rect.size.y
				})
	for child in node.get_children():
		_collect_visible_control_centers_by_name_fragment(child, fragment, candidates)


func _best_label_for_node(node: Node) -> String:
	var labels := _collect_visible_labels(node, 8)
	if !labels.is_empty():
		return String(labels[0])
	var parent := node.get_parent()
	if parent != null:
		labels = _collect_visible_labels(parent, 8)
		if !labels.is_empty():
			return String(labels[0])
	return String(node.name)


func _best_card_name_for_node(node: Node) -> String:
	var scope := _nearest_card_scope(node)
	var title := _best_named_label_for_node(scope, "TitleLabel")
	if title != "":
		return title
	var parent := node.get_parent()
	var depth := 0
	while parent != null and depth < 6:
		if _is_card_lookup_boundary(parent):
			break
		title = _best_named_label_for_node(parent, "TitleLabel")
		if title != "":
			return title
		parent = parent.get_parent()
		depth += 1
	return ""


func _best_named_label_for_node(node: Node, target_name: String) -> String:
	var current := node
	var depth := 0
	while current != null and depth < 7:
		if depth > 0 and _is_card_lookup_boundary(current):
			break
		var found := _find_visible_node_by_name(current, target_name)
		var text := _text_from_label_node(found)
		if text != "":
			return text.left(MAX_LABEL_TEXT)
		current = current.get_parent()
		depth += 1
	return ""


func _collect_nearby_card_labels(node: Node, limit: int) -> Array:
	var scope := _nearest_card_scope(node)
	var labels := _collect_visible_labels(scope, limit)
	if labels.is_empty() and node != scope:
		labels = _collect_visible_labels(node, limit)
	return labels


func _nearest_card_scope(node: Node) -> Node:
	var current := node
	var depth := 0
	while current != null and depth < 7:
		if depth > 0 and _is_card_lookup_boundary(current):
			break
		var title := _find_visible_node_by_name(current, "TitleLabel")
		if _text_from_label_node(title) != "":
			return current
		current = current.get_parent()
		depth += 1
	return node


func _is_card_lookup_boundary(node: Node) -> bool:
	var lower := String(node.name).to_lower()
	return lower == "hand" or lower == "cardrow" or lower == "cardgrid" or lower.contains("enemycontainer")


func _text_from_label_node(node: Node) -> String:
	if node != null and (node is Label or node is RichTextLabel):
		return String(node.text).strip_edges()
	return ""


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


func _make_signature(context: Dictionary, actions: Array, state := {}) -> String:
	var parts := [
		String(context.get("screen", "")),
		String(context.get("path", "")),
		str(actions.size()),
		str(state.get("energy", "")),
		str(state.get("playable_card_count", ""))
	]
	for action in actions:
		parts.append("%s:%s:%s" % [
			String(action.get("node_path", "")),
			str(action.get("playable", "")),
			str(action.get("card_cost", ""))
		])
	return "|".join(parts)
