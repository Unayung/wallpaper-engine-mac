//
//  WESpriteScene.swift
//  Open Wallpaper Engine
//
//  SpriteKit scene that advances native Wallpaper Engine layer adapters.
//

import SpriteKit

struct WEScrollConfiguration: Equatable {
    let speedX: Double
    let speedY: Double
    let repeatX: Double
    let repeatY: Double
}

final class WESpriteScene: SKScene {
    private final class MobBinding {
        weak var node: SKSpriteNode?
        let textures: [SKTexture]
        let controller: MobController
        let baseScale: CGFloat

        init(
            node: SKSpriteNode,
            textures: [SKTexture],
            controller: MobController,
            baseScale: CGFloat
        ) {
            self.node = node
            self.textures = textures
            self.controller = controller
            self.baseScale = baseScale
        }
    }

    private final class TimedAnimationBinding {
        weak var node: SKSpriteNode?
        let textures: [SKTexture]
        let durations: [TimeInterval]
        var frameIndex = 0
        var elapsed = 0.0

        init(node: SKSpriteNode, textures: [SKTexture], durations: [TimeInterval]) {
            self.node = node
            self.textures = textures
            self.durations = durations
        }
    }

    private final class MotionItemBinding {
        weak var node: SKSpriteNode?
        let controller: MotionItemController

        init(node: SKSpriteNode, controller: MotionItemController) {
            self.node = node
            self.controller = controller
        }
    }

    private final class ScriptedOriginMotionBinding {
        weak var node: SKSpriteNode?
        let controller: ScriptedOriginMotionController

        init(node: SKSpriteNode, controller: ScriptedOriginMotionController) {
            self.node = node
            self.controller = controller
        }
    }

    private var mobBindings: [MobBinding] = []
    private var motionItemBindings: [MotionItemBinding] = []
    private var scriptedOriginMotionBindings: [ScriptedOriginMotionBinding] = []
    private var timedAnimations: [TimedAnimationBinding] = []
    private var lastUpdateTime: TimeInterval?

    static func zPosition(forObjectIndex index: Int) -> CGFloat {
        CGFloat(index)
    }

    static func horizontalScale(baseScale: CGFloat, direction: Int) -> CGFloat {
        abs(baseScale) * (direction < 0 ? -1 : 1)
    }

    static func scrollConfiguration(for effects: [WEEffect]?) -> WEScrollConfiguration? {
        guard let effect = effects?.first(where: {
            $0.visible != false &&
            $0.file?.lowercased().contains("effects/scroll/") == true
        }),
        let shaderValues = effect.passes?.first?.constantShaderValues
        else {
            return nil
        }

        let (repeatX, repeatY) = (shaderValues.repeatValue ?? "1 1").parseVector2()
        return WEScrollConfiguration(
            speedX: wallpaperEngineScrollSpeed(shaderValues.speedX ?? 0),
            speedY: wallpaperEngineScrollSpeed(shaderValues.speedY ?? 0),
            repeatX: repeatX,
            repeatY: repeatY
        )
    }

    private static func wallpaperEngineScrollSpeed(_ speed: Double) -> Double {
        speed.sign == .minus ? -(speed * speed) : speed * speed
    }

    static func makeScrollShader(configuration: WEScrollConfiguration) -> SKShader {
        let source =
            """
            void main() {
                vec2 repeatedUV = v_tex_coord * u_scrollRepeat;
                vec2 scrolledUV = fract(repeatedUV + (u_scrollSpeed * u_time));
                gl_FragColor = texture2D(u_texture, scrolledUV) * v_color_mix;
            }
            """
        let shader = SKShader(source: source)
        shader.uniforms = [
            SKUniform(
                name: "u_scrollSpeed",
                vectorFloat2: vector_float2(
                    Float(configuration.speedX),
                    Float(configuration.speedY)
                )
            ),
            SKUniform(
                name: "u_scrollRepeat",
                vectorFloat2: vector_float2(
                    Float(configuration.repeatX),
                    Float(configuration.repeatY)
                )
            )
        ]
        return shader
    }

    func bindMob(
        node: SKSpriteNode,
        textures: [SKTexture],
        controller: MobController,
        baseScale: CGFloat
    ) {
        let binding = MobBinding(
            node: node,
            textures: textures,
            controller: controller,
            baseScale: baseScale
        )
        mobBindings.append(binding)
        apply(controller.state, to: binding)
    }

    func bindTimedAnimation(
        node: SKSpriteNode,
        textures: [SKTexture],
        durations: [TimeInterval]
    ) {
        guard textures.count > 1 else { return }
        let normalizedDurations = textures.indices.map { index -> TimeInterval in
            guard durations.indices.contains(index), durations[index] > 0 else {
                return 1.0 / 30.0
            }
            return durations[index]
        }
        timedAnimations.append(
            TimedAnimationBinding(
                node: node,
                textures: textures,
                durations: normalizedDurations
            )
        )
        node.texture = textures[0]
    }

    func bindMotionItem(node: SKSpriteNode, controller: MotionItemController) {
        let binding = MotionItemBinding(node: node, controller: controller)
        motionItemBindings.append(binding)
        apply(controller.position, to: binding)
    }

    func bindScriptedOriginMotion(
        node: SKSpriteNode,
        controller: ScriptedOriginMotionController
    ) {
        let binding = ScriptedOriginMotionBinding(node: node, controller: controller)
        scriptedOriginMotionBindings.append(binding)
        apply(controller.position, to: binding)
    }

    func attach(nodes: [SKNode], records: [SceneHierarchyRecord]) {
        let attachments = SceneHierarchyResolver.resolve(records)

        for index in nodes.indices {
            guard attachments.indices.contains(index) else {
                nodes[index].zPosition = CGFloat(index)
                addChild(nodes[index])
                NSLog("[WESpriteScene] Missing hierarchy record for renderable node %d", index)
                continue
            }

            switch attachments[index] {
            case .root(let localZ, let reason):
                nodes[index].zPosition = CGFloat(localZ)
                addChild(nodes[index])
                if let reason {
                    NSLog(
                        "[WESpriteScene] Hierarchy fallback for source index %d: %@",
                        records[index].sourceIndex,
                        Self.fallbackDescription(reason)
                    )
                }

            case .parent(let parentRecordIndex, let localZ):
                guard nodes.indices.contains(parentRecordIndex) else {
                    nodes[index].zPosition = CGFloat(records[index].sourceIndex)
                    addChild(nodes[index])
                    NSLog(
                        "[WESpriteScene] Invalid parent record index %d for source index %d",
                        parentRecordIndex,
                        records[index].sourceIndex
                    )
                    continue
                }
                nodes[index].zPosition = CGFloat(localZ)
                nodes[parentRecordIndex].addChild(nodes[index])
            }
        }
    }

    override func update(_ currentTime: TimeInterval) {
        defer { lastUpdateTime = currentTime }
        guard let lastUpdateTime else { return }

        let deltaTime = max(0, min(currentTime - lastUpdateTime, 0.25))
        guard deltaTime > 0 else { return }

        mobBindings.removeAll { binding in
            guard binding.node != nil else { return true }
            let state = binding.controller.update(deltaTime: deltaTime)
            apply(state, to: binding)
            return false
        }

        motionItemBindings.removeAll { binding in
            guard binding.node != nil else { return true }
            let position = binding.controller.update(deltaTime: deltaTime)
            apply(position, to: binding)
            return false
        }

        scriptedOriginMotionBindings.removeAll { binding in
            guard binding.node != nil else { return true }
            let position = binding.controller.update(deltaTime: deltaTime)
            apply(position, to: binding)
            return false
        }

        timedAnimations.removeAll { binding in
            guard let node = binding.node else { return true }
            binding.elapsed += deltaTime

            while binding.elapsed >= binding.durations[binding.frameIndex] {
                binding.elapsed -= binding.durations[binding.frameIndex]
                binding.frameIndex = (binding.frameIndex + 1) % binding.textures.count
            }
            node.texture = binding.textures[binding.frameIndex]
            return false
        }
    }

    private func apply(_ state: MobControllerState, to binding: MobBinding) {
        guard let node = binding.node else { return }
        node.position.x = state.x
        node.xScale = Self.horizontalScale(
            baseScale: binding.baseScale,
            direction: state.direction
        )

        guard !binding.textures.isEmpty else { return }
        let frameIndex = min(max(state.frame, 0), binding.textures.count - 1)
        node.texture = binding.textures[frameIndex]
    }

    private func apply(_ position: MotionItemPosition, to binding: MotionItemBinding) {
        binding.node?.position = CGPoint(x: position.x, y: position.y)
    }

    private func apply(
        _ position: MotionItemPosition,
        to binding: ScriptedOriginMotionBinding
    ) {
        binding.node?.position = CGPoint(x: position.x, y: position.y)
    }

    private static func fallbackDescription(
        _ reason: SceneHierarchyFallbackReason
    ) -> String {
        switch reason {
        case .missingParent(let id):
            return "missing parent \(id)"
        case .duplicateID(let id):
            return "duplicate object ID \(id)"
        case .cycle:
            return "parent cycle"
        }
    }
}
