#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
module_cache="/private/tmp/owe-scene-tests-module-cache"
test_binary="/private/tmp/owe-scene-runtime-tests"
src="$repo_root/Open Wallpaper Engine/Services"

mkdir -p "$module_cache"

# The scene sources the behaviours bind to, as Tools/scenecheck compiles them.
xcrun swiftc \
    -swift-version 5 \
    -module-cache-path "$module_cache" \
    "$src/SceneParsers/SceneModels.swift" \
    "$src/SceneParsers/SceneAnimation.swift" \
    "$src/SceneParsers/SceneEvaluator.swift" \
    "$src/SceneParsers/WallpaperSKScene.swift" \
    "$src/SceneParsers/WEShaderTranslator.swift" \
    "$src/SceneParsers/SceneEffectBuilder.swift" \
    "$src/SceneParsers/SceneTextLayer.swift" \
    "$src/SceneParsers/SceneScriptRuntime.swift" \
    "$src/SceneParsers/SceneBackdropBlend.swift" \
    "$src/SceneParsers/PKGParser.swift" \
    "$src/SceneParsers/TEXParser.swift" \
    "$src/SceneWallpaperViewModel.swift" \
    "$src/WEProject.swift" \
    "$src/WallpaperDirectory.swift" \
    "$src/SceneRuntime/MobBehavior.swift" \
    "$src/SceneRuntime/MotionItemBehavior.swift" \
    "$src/SceneRuntime/ScriptedOriginMotionBehavior.swift" \
    "$repo_root/Tests/SceneRuntimeTests/Stubs.swift" \
    "$repo_root/Tests/SceneRuntimeTests/main.swift" \
    -o "$test_binary"

"$test_binary"
