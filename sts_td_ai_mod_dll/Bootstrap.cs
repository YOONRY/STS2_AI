using System;
using Godot;
using MegaCrit.Sts2.Core.Modding;

namespace StsTdAiMod;

[ModInitializer(nameof(Init))]
public static class Bootstrap
{
    private const string RootName = "StsTdAi";
    private const string ScriptPath = "res://mods/sts_td_ai/sts_td_ai.gd";

    public static void Init()
    {
        try
        {
            var tree = Engine.GetMainLoop() as SceneTree;
            if (tree?.Root == null)
            {
                GD.PushWarning("[StsTdAi] SceneTree is not available during mod init.");
                return;
            }

            if (tree.Root.GetNodeOrNull(RootName) != null)
            {
                GD.Print("[StsTdAi] root node already installed.");
                return;
            }

            var script = GD.Load<Script>(ScriptPath);
            if (script == null)
            {
                GD.PushError($"[StsTdAi] Failed to load script at {ScriptPath}.");
                return;
            }

            var node = new Node { Name = RootName };
            node.SetScript(script);
            tree.Root.CallDeferred(Node.MethodName.AddChild, node);
            GD.Print("[StsTdAi] bootstrap installed root node.");
        }
        catch (Exception ex)
        {
            GD.PushError("[StsTdAi] bootstrap failed: " + ex);
        }
    }
}
