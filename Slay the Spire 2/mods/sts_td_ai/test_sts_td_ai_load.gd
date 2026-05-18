extends SceneTree

const StsTdAi := preload("res://mods/sts_td_ai/sts_td_ai.gd")


func _init() -> void:
	var ai := StsTdAi.new()
	root.add_child(ai)
	var state := {
		"hp": 70,
		"max_hp": 80,
		"floor": 3,
		"gold": 99,
		"deck": ["Strike", "Defend"],
		"hand": ["Strike"],
		"enemies": [{"name": "Test", "hp": 20, "intent_damage": 6}]
	}
	var actions := [
		{"type": "play_card", "id": "Strike", "predicted_state": state},
		{"type": "end_turn", "id": "EndTurn", "predicted_state": state}
	]
	var ranked := ai.rank_actions(state, actions)
	if ranked.is_empty():
		push_error("[StsTdAiTest] no ranked actions")
		quit(1)
		return
	print("[StsTdAiTest] ok ranked=%d" % ranked.size())
	quit(0)
