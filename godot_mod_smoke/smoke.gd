extends Node

const StsTdAi := preload("res://mods/sts_td_ai/sts_td_ai.gd")


func _ready() -> void:
	var ai := StsTdAi.new()
	add_child(ai)
	var state := {
		"hp": 70,
		"max_hp": 80,
		"floor": 3,
		"gold": 99,
		"energy": 1,
		"energy_known": true,
		"playable_card_count": 1,
		"unplayable_card_count": 0,
		"deck": ["Strike", "Defend"],
		"hand": ["Strike"],
		"enemies": [{"name": "Test", "hp": 20, "intent_damage": 6}]
	}
	var actions := [
		{"type": "play_card", "id": "Strike", "card_cost": 1, "card_type": "Attack", "playable": true, "predicted_state": state},
		{"type": "end_turn", "id": "EndTurn", "predicted_state": state}
	]
	var ranked := ai.rank_actions(state, actions)
	if ranked.is_empty():
		push_error("[StsTdAiSmoke] no ranked actions")
		get_tree().quit(1)
		return
	var spent_state := state.duplicate(true)
	spent_state["energy"] = 0
	spent_state["playable_card_count"] = 0
	spent_state["unplayable_card_count"] = 1
	var spent_ranked := ai.rank_actions(spent_state, [
		{"type": "play_card", "id": "Bash", "card_cost": 2, "card_type": "Attack", "playable": false, "energy_shortfall": 2, "predicted_state": spent_state},
		{"type": "end_turn", "id": "EndTurn", "predicted_state": spent_state}
	])
	if spent_ranked.is_empty() or String(spent_ranked[0]["action"].get("type", "")) != "end_turn":
		push_error("[StsTdAiSmoke] end turn was not preferred with no playable cards")
		get_tree().quit(1)
		return
	print("[StsTdAiSmoke] ok ranked=%d" % ranked.size())
	get_tree().quit(0)
