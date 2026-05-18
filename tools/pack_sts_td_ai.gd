extends SceneTree


func _init() -> void:
	var out_path := "res://build/sts_td_ai.pck"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var packer := PCKPacker.new()
	var err := packer.pck_start(out_path)
	if err != OK:
		push_error("pck_start failed: %s" % err)
		quit(1)
		return

	for path in [
		"res://mods/sts_td_ai/sts_td_ai.gd",
		"res://mods/sts_td_ai/sts_td_ai_scene_hook.gd",
		"res://mods/sts_td_ai/README.md"
	]:
		err = packer.add_file(path, path)
		if err != OK:
			push_error("add_file failed for %s: %s" % [path, err])
			quit(1)
			return

	err = packer.flush()
	if err != OK:
		push_error("flush failed: %s" % err)
		quit(1)
		return
	print("[StsTdAiPack] wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)
