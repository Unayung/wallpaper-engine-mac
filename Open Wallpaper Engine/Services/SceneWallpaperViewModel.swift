import AVFoundation
import SpriteKit
import SwiftUI

class SceneWallpaperViewModel: ObservableObject {

    // MARK: - Public state

    var currentWallpaper: WEWallpaper {
        willSet { loadScene(from: newValue) }
    }

    @Published var skScene: SKScene?

    // MARK: - Private state

    private var pkgParser: PKGParser?

    // Retained video players (SKVideoNode holds a weak ref only)
    private var videoPlayers: [AVQueuePlayer] = []
    private var videoLoopers: [AVPlayerLooper] = []
    private var tempVideoFiles: [URL] = []

    // Background audio
    private var audioPlayers: [AVAudioPlayer] = []

    // MARK: - Init / deinit

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        registerObservers()
        loadScene(from: wallpaper)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        videoPlayers.forEach { $0.pause() }
        audioPlayers.forEach { $0.stop() }
        for url in tempVideoFiles { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Observers

    private func registerObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemWillSleep(_:)),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemDidWake(_:)),
                       name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceDidChange(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(spaceDidChange(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    // MARK: - Scene loading

    func loadScene(from wallpaper: WEWallpaper) {
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseURL = dir.appending(path: sceneFile)

        // Tear down previous media before loading new scene
        videoPlayers.forEach { $0.pause() }
        videoPlayers = []; videoLoopers = []
        for url in tempVideoFiles { try? FileManager.default.removeItem(at: url) }
        tempVideoFiles = []
        audioPlayers.forEach { $0.stop() }
        audioPlayers = []

        var scene: WEScene?
        if FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: pkgURL)
                pkgParser = parser
                scene = try parser.extractJSON(named: sceneFile, as: WEScene.self)
            } catch {
                WELogger.shared.error("[SceneVM] PKG parse failed: \(error)")
            }
        } else if FileManager.default.fileExists(atPath: looseURL.path(percentEncoded: false)) {
            pkgParser = nil
            scene = try? JSONDecoder().decode(WEScene.self, from: Data(contentsOf: looseURL))
        }

        guard let scene else {
            WELogger.shared.verbose("[SceneVM] No scene data found in \(sceneFile)")
            return
        }

        WELogger.shared.verbose("[SceneVM] \(scene.objects.count) objects in \(sceneFile)")
        let built = buildSKScene(from: scene, dir: dir)
        DispatchQueue.main.async { self.skScene = built }
    }

    // MARK: - SpriteKit scene builder

    private func buildSKScene(from scene: WEScene, dir: URL) -> SKScene {
        let proj = scene.general.orthogonalprojection ?? WEOrthogonalProjection(width: 1920, height: 1080)
        let size = CGSize(width: proj.width, height: proj.height)
        let sk = SKScene(size: size)
        sk.scaleMode = .aspectFill

        if let cc = scene.general.clearcolor {
            let c = cc.parseColor()
            sk.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        }

        var hasVisibleImage = false
        for obj in scene.objects {
            guard obj.visible != false else { continue }

            if let _ = obj.sound {
                loadSoundObject(obj, dir: dir)
            } else if obj.image != nil {
                if let node = buildImageNode(obj, sceneSize: size, dir: dir) {
                    sk.addChild(node)
                    if let sprite = node as? SKSpriteNode, sprite.blendMode != .add { hasVisibleImage = true }
                    if node is SKVideoNode { hasVisibleImage = true }
                }
            } else if obj.particle != nil {
                if let node = buildParticleNode(obj, dir: dir, sceneSize: size) {
                    sk.addChild(node)
                }
            }
        }

        if !hasVisibleImage, let preview = loadPreviewImage(dir: dir) {
            let node = SKSpriteNode(texture: SKTexture(image: preview))
            node.size = size
            node.position = CGPoint(x: size.width/2, y: size.height/2)
            sk.addChild(node)
        }

        return sk
    }

    // MARK: - Image objects

    private func buildImageNode(_ obj: WESceneObject, sceneSize: CGSize, dir: URL) -> SKNode? {
        guard let imagePath = obj.image else { return nil }
        let model: WEModel? = loadJSON(path: imagePath, dir: dir)
        guard let materialPath = model?.material else { return nil }
        let material: WEMaterial? = loadJSON(path: materialPath, dir: dir)
        // textures is [String?]? — first non-nil element is the primary texture
        guard let textureName = (material?.passes?.first?.textures?.compactMap { $0 })?.first else { return nil }

        // Determine display size and position
        let nodeSize: CGSize
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            nodeSize = CGSize(width: w, height: h)
        } else if let mw = model?.width, let mh = model?.height {
            nodeSize = CGSize(width: mw, height: mh)
        } else {
            nodeSize = sceneSize
        }

        let nodePos: CGPoint
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            // WE world space: (0,0) at screen center, Y-up.
            // SpriteKit: (0,0) at bottom-left, Y-up. Add half-scene offset.
            nodePos = CGPoint(x: x + sceneSize.width/2, y: y + sceneSize.height/2)
        } else {
            nodePos = CGPoint(x: sceneSize.width/2, y: sceneSize.height/2)
        }

        // Try loading the texture — could be static image or embedded video
        let pass = material?.passes?.first
        guard let tex = loadTexture(named: textureName, materialDir: materialPath, dir: dir) else { return nil }
        switch tex {
        case .image(let image):
            return buildSpriteNode(image: image, obj: obj, size: nodeSize, position: nodePos, pass: pass)
        case .video(let mp4Data):
            return buildVideoNode(mp4Data: mp4Data, size: nodeSize, position: nodePos)
        }
    }

    private func buildSpriteNode(image: NSImage, obj: WESceneObject, size: CGSize,
                                  position: CGPoint, pass: WEMaterialPass?) -> SKSpriteNode {
        let base = SKTexture(image: image)
        let node = SKSpriteNode(texture: base)
        node.size = size
        node.position = position
        node.alpha = CGFloat(obj.alpha ?? 1.0)

        if let colorStr = obj.color {
            let c = colorStr.parseColor()
            node.color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
            node.colorBlendFactor = (obj.colorBlendMode ?? 0) > 0 ? 1.0 : 0.0
        }

        switch pass?.blending {
        case "additive": node.blendMode = .add
        default: node.blendMode = .alpha
        }

        // Sprite-sheet animation: WE uses horizontal strips when SPRITE/ANIMATION combo is set
        if let combos = pass?.combos,
           (combos["SPRITE"] != nil || combos["ANIMATION"] != nil),
           let frameVal = pass?.constantshadervalues?["g_Frames"]?.doubleValue {
            let frames = Int(frameVal)
            if frames > 1 {
                let fps = pass?.constantshadervalues?["g_FrameRate"]?.doubleValue ?? 24.0
                node.run(spriteAnimation(base: base, frames: frames, fps: fps))
            }
        }

        return node
    }

    private func spriteAnimation(base: SKTexture, frames: Int, fps: Double) -> SKAction {
        let fw = 1.0 / CGFloat(frames)
        var textures = [SKTexture]()
        for i in 0..<frames {
            let rect = CGRect(x: CGFloat(i) * fw, y: 0, width: fw, height: 1)
            textures.append(SKTexture(rect: rect, in: base))
        }
        let tpf = max(1.0/60.0, 1.0/fps)
        return SKAction.repeatForever(.animate(with: textures, timePerFrame: tpf))
    }

    private func buildVideoNode(mp4Data: Data, size: CGSize, position: CGPoint) -> SKVideoNode? {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            try mp4Data.write(to: tmpURL)
            tempVideoFiles.append(tmpURL)
        } catch {
            WELogger.shared.error("[SceneVM] Failed to write temp video: \(error)")
            return nil
        }

        let asset = AVURLAsset(url: tmpURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: item)
        videoPlayers.append(player)
        videoLoopers.append(looper)

        let node = SKVideoNode(avPlayer: player)
        node.size = size
        node.position = position
        player.play()
        return node
    }

    // MARK: - Sound objects

    private func loadSoundObject(_ obj: WESceneObject, dir: URL) {
        guard let paths = obj.sound else { return }
        for path in paths {
            var audioURL: URL?
            if let parser = pkgParser, let data = parser.extractFile(named: path) {
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("\(UUID().uuidString).\((path as NSString).pathExtension)")
                if (try? data.write(to: tmp)) != nil {
                    tempVideoFiles.append(tmp)
                    audioURL = tmp
                }
            } else {
                let candidate = dir.appending(path: path)
                if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                    audioURL = candidate
                }
            }
            guard let url = audioURL else { continue }
            if let player = try? AVAudioPlayer(contentsOf: url) {
                player.numberOfLoops = -1  // loop indefinitely
                player.volume = Float(AppDelegate.shared.wallpaperViewModel.playVolume)
                player.play()
                audioPlayers.append(player)
            }
        }
    }

    // MARK: - Particle objects

    private func buildParticleNode(_ obj: WESceneObject, dir: URL, sceneSize: CGSize) -> SKNode? {
        guard let particlePath = obj.particle else { return nil }
        let ps: WEParticleSystem? = loadJSON(path: particlePath, dir: dir)
        guard let ps else { return nil }

        let emitter = SKEmitterNode()

        if let materialPath = ps.material {
            let mat: WEMaterial? = loadJSON(path: materialPath, dir: dir)
            if let texName = mat?.passes?.first?.textures?.first ?? nil {
                if let result = loadTexture(named: texName, materialDir: materialPath, dir: dir),
                   case .image(let img) = result {
                    emitter.particleTexture = SKTexture(image: img)
                } else if let img = generateProceduralTexture(named: texName) {
                    emitter.particleTexture = SKTexture(image: img)
                }
            }
            if let blending = mat?.passes?.first?.blending {
                emitter.particleBlendMode = blending == "additive" ? .add : .alpha
            }
        }

        if let em = ps.emitter?.first {
            emitter.particleBirthRate = CGFloat(em.rate ?? 100)
            if let overrideRate = obj.instanceoverride?.rate?.value {
                emitter.particleBirthRate *= CGFloat(overrideRate)
            }
            if em.name == "sphererandom" {
                let dist = CGFloat(em.distancemax ?? 100)
                emitter.particlePositionRange = CGVector(dx: dist*2, dy: dist*2)
            }
        }

        for ini in ps.initializer ?? [] {
            switch ini.name {
            case "lifetimerandom":
                let lo = ini.min?.doubleValue ?? 1, hi = ini.max?.doubleValue ?? 1
                emitter.particleLifetime = CGFloat((lo+hi)/2)
                emitter.particleLifetimeRange = CGFloat(hi-lo)
            case "sizerandom":
                let lo = ini.min?.doubleValue ?? 1, hi = ini.max?.doubleValue ?? 1
                let avg = (lo+hi)/2, mul = obj.instanceoverride?.size ?? 1.0
                emitter.particleSize = CGSize(width: avg*mul, height: avg*mul)
                emitter.particleScaleRange = CGFloat((hi-lo)/avg) * CGFloat(mul)
            case "velocityrandom":
                let minV = ini.min?.vectorValue ?? (0,0,0)
                let maxV = ini.max?.vectorValue ?? (0,0,0)
                let ax = (minV.0+maxV.0)/2, ay = (minV.1+maxV.1)/2
                let speed = sqrt(ax*ax+ay*ay)
                emitter.particleSpeed = CGFloat(speed)
                emitter.particleSpeedRange = CGFloat(abs(maxV.1-minV.1)/2)
                if speed > 0 { emitter.emissionAngle = CGFloat(atan2(-ay, ax)); emitter.emissionAngleRange = 0.1 }
            case "alpharandom":
                let lo = ini.min?.doubleValue ?? 1, hi = ini.max?.doubleValue ?? 1
                emitter.particleAlpha = CGFloat((lo+hi)/2)
                emitter.particleAlphaRange = CGFloat(hi-lo)
            case "colorrandom":
                if let maxC = ini.max?.vectorValue {
                    emitter.particleColor = NSColor(red: maxC.0/255, green: maxC.1/255, blue: maxC.2/255, alpha: 1)
                }
            default: break
            }
        }

        for op in ps.operator ?? [] {
            switch op.name {
            case "movement":
                if let gStr = op.gravity {
                    let (gx, gy, gz) = gStr.parseVector3()
                    emitter.xAcceleration = CGFloat(gx)
                    emitter.yAcceleration = CGFloat(gy != 0 && gz == 0 ? -gy : -gz)
                }
            case "alphafade":
                if let fo = op.fadeouttime, fo < 1.0 {
                    emitter.particleAlphaSpeed = CGFloat(-1.0 / max(emitter.particleLifetime * CGFloat(1-fo), 0.1))
                }
            default: break
            }
        }

        if let renderer = ps.renderer?.first, renderer.name == "spritetrail" {
            let len = CGFloat(renderer.maxlength ?? 50)
            emitter.particleSize = CGSize(width: 2, height: len)
            emitter.particleRotation = emitter.emissionAngle
        }

        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            emitter.position = CGPoint(x: x + sceneSize.width/2, y: y + sceneSize.height/2)
        }
        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            emitter.xScale = CGFloat(sx); emitter.yScale = CGFloat(sy)
        }

        emitter.numParticlesToEmit = 0
        return emitter
    }

    // MARK: - Asset loading

    private enum TextureContent {
        case image(NSImage)
        case video(Data)
    }

    private func loadTexture(named name: String, materialDir: String, dir: URL) -> TextureContent? {
        let matDirPath = (materialDir as NSString).deletingLastPathComponent
        var texPaths = [String]()
        if !matDirPath.isEmpty { texPaths.append("\(matDirPath)/\(name).tex") }
        let root = matDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootPath = "\(root)/\(name).tex"
        if !texPaths.contains(rootPath) { texPaths.append(rootPath) }
        texPaths.append("\(name).tex")

        for texPath in texPaths {
            if let parser = pkgParser, let data = parser.extractFile(named: texPath) {
                WELogger.shared.verbose("[SceneVM] TEX from PKG '\(texPath)' \(data.count)B")
                let tex = TEXParser(data: Data(data))
                if let mp4 = tex.extractVideoData() { return .video(mp4) }
                if let img = tex.extractImage() { return .image(img) }
                WELogger.shared.verbose("[SceneVM] TEXParser returned nil for '\(texPath)'")
            }
            let texURL = dir.appending(path: texPath)
            if let data = try? Data(contentsOf: texURL) {
                let tex = TEXParser(data: data)
                if let mp4 = tex.extractVideoData() { return .video(mp4) }
                if let img = tex.extractImage() { return .image(img) }
            }
        }

        // Fallback: raw image file (png/jpg/gif)
        for ext in ["png", "jpg", "jpeg", "gif"] {
            let imgPath = matDirPath.isEmpty ? "\(name).\(ext)" : "\(matDirPath)/\(name).\(ext)"
            if let parser = pkgParser, let data = parser.extractFile(named: imgPath),
               let img = NSImage(data: data) { return .image(img) }
            let imgURL = dir.appending(path: imgPath)
            if let img = NSImage(contentsOf: imgURL) { return .image(img) }
        }

        WELogger.shared.verbose("[SceneVM] No texture found for '\(name)'")
        return nil
    }

    private func loadJSON<T: Decodable>(path: String, dir: URL) -> T? {
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return (try? Data(contentsOf: dir.appending(path: path))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func loadPreviewImage(dir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            if let img = NSImage(contentsOf: dir.appending(path: name)) { return img }
        }
        return nil
    }

    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGSize
        switch name {
        case "particle/drop": size = CGSize(width: 4, height: 16)
        default: size = CGSize(width: 32, height: 32)
        }
        return generateRadialGradient(size: size, color: .white)
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let cs = CGColorSpaceCreateDeviceRGB()
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let colors = [
            CGColor(colorSpace: cs, components: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent])!,
            CGColor(colorSpace: cs, components: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, 0])!
        ] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        let center = CGPoint(x: size.width/2, y: size.height/2)
        ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: min(size.width, size.height)/2, options: [])
        img.unlockFocus()
        return img
    }

    // MARK: - System events

    @objc func systemWillSleep(_ notification: Notification) {
        skScene?.isPaused = true
        videoPlayers.forEach { $0.pause() }
        audioPlayers.forEach { $0.pause() }
    }

    @objc func systemDidWake(_ notification: Notification) {
        skScene?.isPaused = false
        let rate = AppDelegate.shared.wallpaperViewModel.playRate
        if rate > 0 {
            videoPlayers.forEach { $0.play() }
            audioPlayers.forEach { $0.play() }
        }
    }

    @objc func spaceDidChange(_ notification: Notification) {
        guard AppDelegate.shared.wallpaperViewModel.playRate > 0 else { return }
        skScene?.isPaused = false
        // Kick video nodes in case Stage Manager froze them
        videoPlayers.forEach { $0.play() }
    }
}
