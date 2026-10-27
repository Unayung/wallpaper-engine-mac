// Scene runtime tests: the script behaviours from upstream's 0.9.0 (Mob, MotionItem,
// scripted origin motion and their constants), their real-wallpaper fixtures (run only when the
// WE_*_WALLPAPER variables point at those MapleStory items), and their binding to
// WallpaperSKScene. Texture decoding, scene building and effects are verified against a whole
// library by Tools/scenecheck and Tools/appcheck instead; see Tools/README.md.
import Foundation
import Compression
import SpriteKit

private var failures = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if condition() {
        print("PASS: \(message)")
    } else {
        failures += 1
        print("FAIL: \(message) (\(file):\(line))")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: T,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let value = actual()
    expect(value == expected, "\(message) — expected \(expected), got \(value)", file: file, line: line)
}

private func expectNear(
    _ actual: @autoclosure () -> Double,
    _ expected: Double,
    accuracy: Double = 0.000_001,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let value = actual()
    expect(
        abs(value - expected) <= accuracy,
        "\(message) — expected \(expected), got \(value)",
        file: file,
        line: line
    )
}

let vector = "1 2 3".parseVector3()
expectEqual(vector.0, 1, "test harness compiles production parsing code")
expectEqual(vector.1, 2, "vector parser returns Y")
expectEqual(vector.2, 3, "vector parser returns Z")

if let wallpaperPath = ProcessInfo.processInfo.environment["WE_HAPPYVILLE_WALLPAPER"] {
    do {
        let wallpaperURL = URL(fileURLWithPath: wallpaperPath, isDirectory: true)
        let projectData = try Data(contentsOf: wallpaperURL.appendingPathComponent("project.json"))
        let project = try JSONSerialization.jsonObject(with: projectData) as? [String: Any]
        expectEqual(
            project?["title"] as? String,
            "MapleStory: Happyville<White Christmas> 冒险岛：幸福村",
            "Happyville fixture title matches the selected wallpaper"
        )

        let package = try PKGParser(url: wallpaperURL.appendingPathComponent("scene.pkg"))
        guard let targetScene = try package.extractJSON(named: "scene.json", as: WEScene.self) else {
            throw NSError(domain: "SceneRuntimeTests", code: 4)
        }
        let motionConfigurations = targetScene.objects.compactMap { object in
            object.originScript.flatMap(MotionItemScriptParser.parse)
        }
        expectEqual(motionConfigurations.count, 2, "Happyville discovers two moving sleigh layers")
        expect(
            motionConfigurations.allSatisfy {
                $0.axis == .x &&
                $0.direction == -1 &&
                $0.speed == 2 &&
                $0.randomRange == 570...750
            },
            "Happyville sleigh layers preserve their authored motion settings"
        )
        let house3 = targetScene.objects.first { $0.id == 170 }
        let house3Roof = targetScene.objects.first { $0.id == 166 }
        let house3Side = targetScene.objects.first { $0.id == 198 }
        expectEqual(house3?.parent, nil, "Happyville house 3 is a hierarchy root")
        expectEqual(house3Roof?.parent, 170, "Happyville house 3 roof references its parent")
        expectEqual(house3Side?.parent, 170, "Happyville house 3 side references its parent")
    } catch {
        failures += 1
        print("FAIL: Happyville fixture validation threw \(error)")
    }
}

if let wallpaperPath = ProcessInfo.processInfo.environment["WE_TOY_TOWER_WALLPAPER"] {
    do {
        let wallpaperURL = URL(fileURLWithPath: wallpaperPath, isDirectory: true)
        let projectData = try Data(
            contentsOf: wallpaperURL.appendingPathComponent("project.json")
        )
        let project = try JSONSerialization.jsonObject(with: projectData)
            as? [String: Any]
        expectEqual(
            project?["title"] as? String,
            "MapleStory: Toy Tower 冒险岛：玩具塔",
            "Toy Tower fixture title matches the selected wallpaper"
        )

        let package = try PKGParser(
            url: wallpaperURL.appendingPathComponent("scene.pkg")
        )
        guard let targetScene = try package.extractJSON(
            named: "scene.json",
            as: WEScene.self
        ) else {
            throw NSError(domain: "SceneRuntimeTests", code: 5)
        }
        let allPropertyScripts = targetScene.objects.flatMap { object in
            [
                object.originScript,
                object.scaleScript,
                object.visibleScript,
                object.alphaScript
            ].compactMap { $0 }
        }
        let constants = SceneScriptConstantsParser.parse(allPropertyScripts)
        expectEqual(constants["speed"], 1, "Toy Tower discovers its shared scene speed")

        let configurations = targetScene.objects.compactMap { object in
            object.originScript.flatMap {
                ScriptedOriginMotionParser.parse($0, constants: constants)
            }
        }
        let cloudLike = configurations.filter {
            $0.horizontalStep > 0 && $0.verticalOscillation == nil
        }
        let airshipLike = configurations.filter {
            $0.horizontalStep < 0 && $0.verticalOscillation != nil
        }
        expect(
            cloudLike.count >= 6,
            "Toy Tower discovers its independently moving cloud layers"
        )
        expectEqual(
            airshipLike.count,
            2,
            "Toy Tower discovers both bobbing airships"
        )
    } catch {
        failures += 1
        print("FAIL: Toy Tower fixture validation threw \(error)")
    }
}

if let wallpaperPath = ProcessInfo.processInfo.environment["WE_LITH_HARBOR_WALLPAPER"] {
    do {
        let wallpaperURL = URL(fileURLWithPath: wallpaperPath, isDirectory: true)
        let projectData = try Data(
            contentsOf: wallpaperURL.appendingPathComponent("project.json")
        )
        let project = try JSONSerialization.jsonObject(with: projectData)
            as? [String: Any]
        expectEqual(
            project?["title"] as? String,
            "MapleStory:  Lith Harbor 冒险岛：明珠港",
            "Lith Harbor fixture title matches the selected wallpaper"
        )

        let package = try PKGParser(
            url: wallpaperURL.appendingPathComponent("scene.pkg")
        )
        guard let targetScene = try package.extractJSON(
            named: "scene.json",
            as: WEScene.self
        ) else {
            throw NSError(domain: "SceneRuntimeTests", code: 6)
        }

        let allPropertyScripts = targetScene.objects.flatMap { object in
            [
                object.originScript,
                object.scaleScript,
                object.visibleScript,
                object.alphaScript
            ].compactMap { $0 }
        }
        let constants = SceneScriptConstantsParser.parse(allPropertyScripts)
        expectEqual(constants["speed"], 0.5, "Lith Harbor discovers its shared scene speed")

        let configurations = targetScene.objects.compactMap { object in
            object.originScript.flatMap {
                ScriptedOriginMotionParser.parse($0, constants: constants)
            }
        }
        expectEqual(
            configurations.count,
            16,
            "Lith Harbor discovers all moving cloud layers"
        )
        expect(
            configurations.allSatisfy { $0.wrapBoundary != nil },
            "every Lith Harbor cloud layer preserves its wrap boundary"
        )

    } catch {
        failures += 1
        print("FAIL: Lith Harbor fixture validation threw \(error)")
    }
}

let snailScript =
    """
    'use strict';
    export function init(value) {
        mob = new shared.Mob({
            range: [132, 1786],
            moveList: [0, 0.0, 0, 1, 1, 2, 3,],
            standList: [0],
            speed: 1,
        })
        return value;
    }
    """

let slimeScript =
    """
    mob = new shared.Mob({
        range: [400, 1515],
        moveList: [3, 3, 4, 4, 5, 6, 7, 8, 9, 10],
        standList: [0, 0, 1, 1, 2, 2],
        speed: 2.2
    })
    """

if let snail = MobScriptParser.parse(snailScript) {
    expectEqual(snail.lowerBound, 132, "Mob parser reads lower range")
    expectEqual(snail.upperBound, 1786, "Mob parser reads upper range")
    expectEqual(snail.moveFrames, [0, 0, 0, 1, 1, 2, 3], "Mob parser normalizes frame numbers")
    expectEqual(snail.standFrames, [0], "Mob parser reads stand frames")
    expectEqual(snail.speed, 1, "Mob parser reads integer speed")
} else {
    failures += 1
    print("FAIL: Mob parser rejected the snail script")
}

if let slime = MobScriptParser.parse(slimeScript) {
    expectEqual(slime.lowerBound, 400, "Mob parser reads second lower range")
    expectEqual(slime.upperBound, 1515, "Mob parser reads second upper range")
    expectEqual(slime.speed, 2.2, "Mob parser reads decimal speed")
    expectEqual(slime.moveFrames.last, 10, "Mob parser reads longer move sequence")
} else {
    failures += 1
    print("FAIL: Mob parser rejected the slime script")
}

expectEqual(MobScriptParser.parse("return value;"), nil, "non-Mob script is ignored")
expectEqual(
    MobScriptParser.parse("new shared.Mob({ range: [0, 1], moveList: [], standList: [] })"),
    nil,
    "Mob parser rejects empty animation lists"
)

private final class SequenceRandomSource:
    MobRandomSource,
    MotionItemRandomSource,
    ScriptedOriginMotionRandomSource
{
    private let values: [Double]
    private var index = 0

    init(_ values: [Double]) {
        self.values = values
    }

    func nextUnit() -> Double {
        guard !values.isEmpty else { return 0.5 }
        defer { index += 1 }
        return values[index % values.count]
    }
}

let sleighScript =
    """
    let item
    export function update(value) {
        item.motion(value)
        return value;
    }
    export function init(value) {
        item = new shared.MotionItem(thisLayer, 2, 'x-', [570, 750])
        return value;
    }
    """

if let sleigh = MotionItemScriptParser.parse(sleighScript) {
    expectEqual(sleigh.axis, .x, "MotionItem parser reads the horizontal axis")
    expectEqual(sleigh.direction, -1, "MotionItem parser reads leftward direction")
    expectEqual(sleigh.speed, 2, "MotionItem parser reads source speed")
    expectEqual(sleigh.randomRange, 570...750, "MotionItem parser reads vertical reset range")
} else {
    failures += 1
    print("FAIL: MotionItem parser rejected the Happyville sleigh script")
}

expectEqual(
    MotionItemScriptParser.parse("return value;"),
    nil,
    "non-MotionItem script is ignored"
)

let sleighConfiguration = MotionItemBehaviorConfiguration(
    axis: .x,
    direction: -1,
    speed: 2,
    randomRange: 570...750
)
let sleighController = MotionItemController(
    configuration: sleighConfiguration,
    canvasSize: MotionItemSize(width: 2580, height: 1080),
    itemSize: MotionItemSize(width: 145, height: 52),
    initialPosition: MotionItemPosition(x: 1250, y: 570),
    randomSource: SequenceRandomSource([0.5])
)
let movedSleigh = sleighController.update(deltaTime: 1)
expectEqual(movedSleigh.x, 1190, "MotionItem speed matches the source's 30 Hz time base")
expectEqual(movedSleigh.y, 570, "horizontal MotionItem preserves Y until reset")

let wrappingSleigh = MotionItemController(
    configuration: sleighConfiguration,
    canvasSize: MotionItemSize(width: 2580, height: 1080),
    itemSize: MotionItemSize(width: 145, height: 52),
    initialPosition: MotionItemPosition(x: -71, y: 570),
    randomSource: SequenceRandomSource([0.5])
)
let wrappedSleigh = wrappingSleigh.update(deltaTime: 1.0 / 30.0)
expectEqual(wrappedSleigh.x, 2652.5, "left-moving MotionItem restarts beyond the right edge")
expectEqual(wrappedSleigh.y, 660, "MotionItem randomizes its perpendicular reset position")

let sharedConstants = SceneScriptConstantsParser.parse([
    """
    export function init(value) {
        shared.speed = 1
        return value
    }
    """
])
expectEqual(sharedConstants["speed"], 1, "scene script parser reads static shared speed")
expectEqual(
    SceneScriptConstantsParser.parse(["shared.speed = Math.random()"])["speed"],
    nil,
    "scene script parser does not execute expressions"
)

let toyTowerCloudScript =
    """
    export function update(value) {
        value.x = value.x + shared.speed * 0.8
        if (value.x > 2200) {
            value.x = -300
        }
        return value
    }
    """

if let cloud = ScriptedOriginMotionParser.parse(
    toyTowerCloudScript,
    constants: sharedConstants
) {
    expectNear(cloud.horizontalStep, 0.8, "cloud parser reads shared-speed horizontal step")
    expectEqual(cloud.alternateHorizontalStep, nil, "cloud has no alternate horizontal step")
    expectEqual(cloud.wrapBoundary, .greaterThan(2200), "cloud parser reads right wrap boundary")
    expectEqual(cloud.restartX, -300, "cloud parser reads restart X")
    expectEqual(cloud.verticalOscillation, nil, "cloud has no vertical oscillation")
} else {
    failures += 1
    print("FAIL: scripted origin parser rejected the Toy Tower cloud")
}

let toyTowerAirshipScript =
    """
    var move = 0.4
    var begin_y = 857
    export function update(value) {
        if (value.x > 1920) {
            value.x = value.x - shared.speed * 0.2
        } else {
            value.x = value.x - shared.speed * 2.5
        }
        value.y = value.y - move
        var r = 60 * move
        r = r > 0 ? r : -r
        if (begin_y - value.y > r || value.y - begin_y > r) {
            move = -move
        }
        if (value.x < -20) {
            value.x = 2090
            begin_y = (Math.random() * (900 - 100 + 1)) + 100
            value.y = begin_y
        }
        return value
    }
    """

let airshipConfiguration = ScriptedOriginMotionParser.parse(
    toyTowerAirshipScript,
    constants: sharedConstants
)
if let airship = airshipConfiguration {
    expectNear(airship.horizontalStep, -2.5, "airship parser reads main horizontal step")
    expectNear(
        airship.alternateHorizontalStep ?? 0,
        -0.2,
        "airship parser reads off-canvas horizontal step"
    )
    expectEqual(
        airship.alternateWhenXGreaterThan,
        1920,
        "airship parser reads alternate-speed boundary"
    )
    expectEqual(airship.wrapBoundary, .lessThan(-20), "airship parser reads left wrap boundary")
    expectEqual(airship.restartX, 2090, "airship parser reads restart X")
    expectEqual(
        airship.verticalOscillation,
        ScriptedOriginVerticalOscillation(step: -0.4, amplitude: 24),
        "airship parser reads vertical bobbing"
    )
    expectEqual(airship.randomYRange, 100...900, "airship parser reads random restart range")
} else {
    failures += 1
    print("FAIL: scripted origin parser rejected the Toy Tower airship")
}

if let airshipConfiguration {
    let movingAirship = ScriptedOriginMotionController(
        configuration: airshipConfiguration,
        initialPosition: MotionItemPosition(x: 1000, y: 857),
        randomSource: SequenceRandomSource([0.5])
    )
    let firstAirshipStep = movingAirship.update(deltaTime: 1.0 / 30.0)
    expectNear(firstAirshipStep.x, 997.5, "airship advances at the authored 30 Hz step")
    expectNear(firstAirshipStep.y, 856.6, "airship begins its vertical bob")

    let sameElapsedAtSixtyFPS = ScriptedOriginMotionController(
        configuration: airshipConfiguration,
        initialPosition: MotionItemPosition(x: 1000, y: 857),
        randomSource: SequenceRandomSource([0.5])
    )
    _ = sameElapsedAtSixtyFPS.update(deltaTime: 1.0 / 60.0)
    let secondHalfFrame = sameElapsedAtSixtyFPS.update(deltaTime: 1.0 / 60.0)
    expectNear(secondHalfFrame.x, 997.5, "airship speed is independent of display FPS")
    expectNear(secondHalfFrame.y, 856.6, "airship bobbing is independent of display FPS")

    let offCanvasAirship = ScriptedOriginMotionController(
        configuration: airshipConfiguration,
        initialPosition: MotionItemPosition(x: 1930, y: 857),
        randomSource: SequenceRandomSource([0.5])
    )
    let offCanvasStep = offCanvasAirship.update(deltaTime: 1.0 / 30.0)
    expectNear(offCanvasStep.x, 1929.8, "airship uses its slower off-canvas approach")

    let wrappingAirship = ScriptedOriginMotionController(
        configuration: airshipConfiguration,
        initialPosition: MotionItemPosition(x: -19, y: 857),
        randomSource: SequenceRandomSource([0.5])
    )
    let resetAirship = wrappingAirship.update(deltaTime: 1.0 / 30.0)
    expectNear(resetAirship.x, 2090, "airship restarts at its authored X")
    expectNear(resetAirship.y, 500, "airship chooses a new height at restart")
}

expectEqual(
    ScriptedOriginMotionParser.parse("return value", constants: sharedConstants),
    nil,
    "unsupported origin scripts remain inert"
)

let lithHarborConstants = ["speed": 0.5]
let lithHarborCloudScript =
    """
    export function update(value) {
        value.x -= shared.speed
        if (value.x <= -200) {
            value.x = 2125
        }
        return value
    }
    """

let lithHarborCloudConfiguration = ScriptedOriginMotionParser.parse(
    lithHarborCloudScript,
    constants: lithHarborConstants
)
if let lithHarborCloudConfiguration {
    expectNear(
        lithHarborCloudConfiguration.horizontalStep,
        -0.5,
        "implicit shared speed uses a multiplier of one"
    )
    expectEqual(
        lithHarborCloudConfiguration.wrapBoundary,
        .lessThanOrEqual(-200),
        "cloud parser preserves an inclusive left wrap boundary"
    )

    let inclusiveCloud = ScriptedOriginMotionController(
        configuration: lithHarborCloudConfiguration,
        initialPosition: MotionItemPosition(x: -199.5, y: 980)
    )
    let inclusiveWrap = inclusiveCloud.update(deltaTime: 1.0 / 30.0)
    expectNear(inclusiveWrap.x, 2125, "cloud wraps when X equals its inclusive boundary")
} else {
    failures += 1
    print("FAIL: scripted origin parser rejected the Lith Harbor cloud")
}

let inclusiveRightScript =
    """
    export function update(value) {
        value.x += shared.speed
        if (value.x >= 200) {
            value.x = -10
        }
        return value
    }
    """
expectEqual(
    ScriptedOriginMotionParser.parse(
        inclusiveRightScript,
        constants: lithHarborConstants
    )?.wrapBoundary,
    .greaterThanOrEqual(200),
    "cloud parser preserves an inclusive right wrap boundary"
)



let movementConfiguration = MobBehaviorConfiguration(
    lowerBound: 10,
    upperBound: 12,
    moveFrames: [0, 1],
    standFrames: [2],
    speed: 1,
    jumpFrame: nil
)

let movingController = MobController(
    configuration: movementConfiguration,
    randomSource: SequenceRandomSource([0, 0.9, 0.9, 0.9]),
    initialX: 11,
    initialDirection: 1,
    initiallyMoving: true
)
expect(
    (1...4).contains(movingController.state.remainingStateTime),
    "Mob state duration starts between one and four seconds"
)
let firstMove = movingController.update(deltaTime: 1.0 / 30.0)
expectEqual(firstMove.x, 10, "moving Mob advances at source speed")
expectEqual(firstMove.frame, 0, "moving Mob advances move frame list")
let boundaryMove = movingController.update(deltaTime: 1.0 / 30.0)
expectEqual(boundaryMove.direction, -1, "Mob reverses source direction at lower bound")
expectEqual(boundaryMove.x, 11, "Mob remains inside its movement range")
expectEqual(boundaryMove.frame, 1, "moving Mob cycles to next frame")

_ = movingController.update(deltaTime: 28.0 / 30.0)
expectEqual(movingController.state.activity, .standing, "Mob switches from moving to standing")
let beforeStandX = movingController.state.x
let standing = movingController.update(deltaTime: 1.0 / 30.0)
expectEqual(standing.x, beforeStandX, "standing Mob does not change X")
expectEqual(standing.frame, 2, "standing Mob uses stand frame list")

let randomizedController = MobController(
    configuration: movementConfiguration,
    randomSource: SequenceRandomSource([0.9, 0.9, 0.5, 0]),
    initialX: nil,
    initialDirection: nil,
    initiallyMoving: nil
)
expect(
    (movementConfiguration.lowerBound...movementConfiguration.upperBound)
        .contains(randomizedController.state.x),
    "random Mob initialization remains inside range"
)


// The behaviours are driven by the fork's WallpaperSKScene, which replaced upstream's
// WESpriteScene. These check the binding, not the controllers: the controllers' numbers
// must land on the layer's holder (and, for a mob, on its artwork's facing and frame).

if let cloudConfiguration = ScriptedOriginMotionParser.parse(
    toyTowerCloudScript,
    constants: sharedConstants
) {
    let scriptedScene = WallpaperSKScene(size: CGSize(width: 1920, height: 1080))
    let cloudHolder = SKNode()
    cloudHolder.position = CGPoint(x: 400, y: 245)
    scriptedScene.addChild(cloudHolder)
    scriptedScene.bind(scriptedMotions: [WallpaperSKScene.ScriptedMotion(
        holder: cloudHolder,
        driver: .origin(ScriptedOriginMotionController(
            configuration: cloudConfiguration,
            initialPosition: MotionItemPosition(x: 400, y: 245)
        ))
    )])
    scriptedScene.update(0)
    scriptedScene.update(1.0 / 30.0)
    expectNear(
        cloudHolder.position.x,
        400.8,
        accuracy: 0.000_1,
        "WallpaperSKScene applies generic origin motion to the holder"
    )
} else {
    failures += 1
    print("FAIL: Toy Tower cloud script did not parse for the binding test")
}

do {
    let scene = WallpaperSKScene(size: CGSize(width: 1920, height: 1080))
    let holder = SKNode()
    holder.position = CGPoint(x: 11, y: 300)
    let artwork = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
    artwork.xScale = 2
    holder.addChild(artwork)
    scene.addChild(holder)
    let frames = (0..<3).map { _ in SKTexture() }
    let controller = MobController(
        configuration: movementConfiguration,
        randomSource: SequenceRandomSource([0, 0.9, 0.9, 0.9]),
        initialX: 11,
        initialDirection: -1,
        initiallyMoving: false
    )
    scene.bind(scriptedMotions: [WallpaperSKScene.ScriptedMotion(
        holder: holder,
        driver: .mob(controller, artwork: artwork, textures: frames, baseXScale: 2)
    )])
    expectNear(holder.position.x, controller.state.x, "mob binding places the holder at its x")
    expectEqual(artwork.xScale, -2, "mob facing mirrors the artwork, keeping its scale")
    expect(artwork.texture === frames[controller.state.frame], "mob binding shows the controller's frame")
    expectNear(holder.position.y, 300, "mob binding leaves y alone")
}

do {
    let scene = WallpaperSKScene(size: CGSize(width: 1920, height: 1080))
    let holder = SKNode()
    holder.position = CGPoint(x: 100, y: 500)
    scene.addChild(holder)
    if let sleigh = MotionItemScriptParser.parse(sleighScript) {
        let controller = MotionItemController(
            configuration: sleigh,
            canvasSize: MotionItemSize(width: 1920, height: 1080),
            itemSize: MotionItemSize(width: 100, height: 50),
            initialPosition: MotionItemPosition(x: 100, y: 500),
            randomSource: SequenceRandomSource([0.5])
        )
        scene.bind(scriptedMotions: [WallpaperSKScene.ScriptedMotion(holder: holder, driver: .item(controller))])
        scene.update(0)
        scene.update(1.0 / 30.0)
        expectNear(holder.position.x, controller.position.x, "MotionItem binding writes x to the holder")
        expectNear(holder.position.y, controller.position.y, "MotionItem binding writes y to the holder")
        expect(holder.position != CGPoint(x: 100, y: 500), "MotionItem binding moves the holder")
    } else {
        failures += 1
        print("FAIL: sleigh script did not parse for the binding test")
    }
}

if failures > 0 {
    print("\n\(failures) test(s) failed")
    exit(1)
}

print("\nAll scene runtime tests passed")
