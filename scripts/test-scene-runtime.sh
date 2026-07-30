#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
module_cache="/private/tmp/owe-scene-tests-module-cache"
test_binary="/private/tmp/owe-scene-runtime-tests"

mkdir -p "$module_cache"

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcrun swiftc \
    -swift-version 5 \
    -module-cache-path "$module_cache" \
    "$repo_root/Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/MobBehavior.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/MotionItemBehavior.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/ScriptedOriginMotionBehavior.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/SceneHierarchyResolver.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/WESpriteScene.swift" \
    "$repo_root/Open Wallpaper Engine/Services/SceneRuntime/SceneAudioController.swift" \
    "$repo_root/Tests/SceneRuntimeTests/main.swift" \
    -o "$test_binary"

"$test_binary"
