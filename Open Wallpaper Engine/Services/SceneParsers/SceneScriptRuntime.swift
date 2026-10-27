//
//  SceneScriptRuntime.swift
//  Open Wallpaper Engine
//
//  Runs the JavaScript a wallpaper author bound to a layer property.
//
//  Text is driven live, and so are the visibility, opacity, position and scale scripts that read
//  the calendar — see `liveProperties`. Beyond that, two kinds of script are run once at load: a
//  media script's verdict on its layer's visibility with nothing playing, and a position script
//  that is a pure function of its settings. The text is overwhelmingly clocks: of the 259 scripted text
//  objects in this library, 167 construct a `Date`. Wallpaper Engine bakes the last string a
//  script produced into the scene file, so without a runtime those layers do render — frozen at
//  whatever minute the author happened to save. A wallpaper whose whole subject is a clock
//  showing 12:34 forever reads as more broken than one showing nothing.
//
//  The scripts are Workshop content, so they are treated as untrusted. `JSContext` is a bare
//  ECMAScript environment: no DOM, no network, no file system, nothing beyond the handful of
//  Wallpaper Engine globals declared below. A script that throws, returns nothing useful, or
//  runs long is dropped and its layer keeps the baked string.
//

import Foundation
import JavaScriptCore

final class SceneScriptRuntime {
    // `SceneScriptsDisabled` (Settings → General → Developer → Disable scene scripts) freezes
    // every scripted layer at its baked value, which is how a scripted layer is told apart from
    // a mis-rendered one. It is honoured by the scene builder, which then creates no runtime at
    // all (`SceneQuality.scripts`), rather than here: this used to be a `static let`, read once
    // per launch, and a switch in Settings has to reach the next rebuild.

    private let context: JSContext
    /// The `update` function each registered script exported, by handle.
    private var updates: [JSValue] = []
    /// The `init` function beside it, when the script exported one.
    private var inits: [JSValue?] = []
    /// The text object each of those scripts drives, when it is known.
    private var textLayers: [Int?] = []
    /// `__quiet`, which sets a layer handle's value without recording it as a write.
    private lazy var quiet: JSValue? = context.objectForKeyedSubscript("__quiet")
    /// Handles whose script has been abandoned — it threw, or it took long enough that running
    /// it every tick would cost more than the layer is worth.
    private var abandoned: Set<Int> = []

    /// Longer than any of this library's scripts need. A clock formats a date; anything taking
    /// this long per call is looping, and a wallpaper must not spend a display frame on it.
    private static let budget: TimeInterval = 0.02

    /// The limit on evaluating a module's top level — its declarations, `createScriptProperties`
    /// chain and `applyUserProperties`. Larger than a call's because it runs once, at load, on
    /// the load queue; bounded because it is still Workshop code.
    private static let moduleBudget: TimeInterval = 0.1

    /// What every scripted string and live property together may spend in one 10 Hz poll, in
    /// thread CPU time. See `beginTick`.
    private static let tickBudget: TimeInterval = 0.005

    /// `JSContextGroupSetExecutionTimeLimit`, when the system JavaScriptCore exports it.
    ///
    /// The per-call `budget` above used to be enforced only by comparing the clock once the call
    /// had *returned*, and a module's top level was not limited at all. So a Workshop `update`
    /// containing `while (true) {}` never returned: `tickScripts` runs on the main thread, which
    /// froze for good, and the same loop at module level wedged the scene's load queue. The only
    /// way to stop JavaScript from outside is JavaScriptCore's watchdog. It is declared in
    /// `JSContextRefPrivate.h` rather than the public headers, so it is looked up at run time and,
    /// if a future system drops it, the runtime simply goes back to checking after the fact.
    ///
    /// Measured against the system framework: with a 20 ms limit and a callback that always says
    /// stop, `while(true){}` returned after 21–25 ms whether entered by `evaluateScript`, by a
    /// function call or by a `toString` the bridge invoked, and the exception handler saw
    /// "JavaScript execution terminated." The limit counts per entry into the VM — two 15 ms
    /// calls in a row both completed — and the context stays usable after a termination.
    /// Having it armed costs about 0.1 µs a call.
    private typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetExecutionTimeLimit = @convention(c) (
        JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void
    private static let setExecutionTimeLimit: SetExecutionTimeLimit? = {
        // RTLD_DEFAULT, which Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
    }()

    /// Set the limit every later entry into this context runs under. It stays in force until
    /// changed, so anything that enters the VM — an `evaluateScript`, a call, even a `toString`
    /// or a property read that lands on a script's getter — is covered, not just the calls that
    /// remember to arm it.
    private func limitExecution(to seconds: TimeInterval) {
        guard let set = Self.setExecutionTimeLimit else { return }
        set(JSContextGetGroup(context.jsGlobalContextRef), seconds, { _, _ in true }, nil)
    }

    /// Set by the exception handler below rather than read from `context.exception`. Installing
    /// a handler at all is what stops JavaScriptCore logging every Workshop syntax error to the
    /// console, but it also means the context never populates `exception` itself — checking that
    /// property instead silently reports success for every script that failed.
    private var failure: String?

    /// The wallpaper's user property values as a JS object literal, handed to every script's
    /// `applyUserProperties`.
    private let userPropertiesLiteral: String

    /// `canvasSize` is the scene's authored projection, which is what Wallpaper Engine reports as
    /// `engine.canvasSize` — not the display's size. Honkai lays out its whole clock with it.
    init?(userProperties: SceneUserProperties = SceneUserProperties(), canvasSize: CGSize = .zero) {
        guard let context = JSContext() else { return nil }
        self.context = context
        self.failure = nil
        self.userPropertiesLiteral = userProperties.jsLiteral
        context.exceptionHandler = { [weak self] _, exception in
            self?.failure = exception?.toString()
        }
        limitExecution(to: Self.moduleBudget)
        context.evaluateScript(Self.prelude)
        context.evaluateScript(
            "engine.canvasSize = new Vec3(\(Double(canvasSize.width)), \(Double(canvasSize.height)), 0);")
        if let offset = Self.clockOffset {
            context.evaluateScript("__shiftClock(\(offset * 1000));")
        }
        limitExecution(to: Self.budget)
    }

    /// `SceneScriptDate` — `2026-10-19` or `2026-10-19T17:30:00`, local time — moves the clock
    /// every script reads to that instant, and lets it run on from there.
    ///
    /// A verification aid, not a feature: a calendar's layout is only right once a day, and a
    /// render taken on a Sunday says nothing about the six branches that draw the other days.
    /// Passed in the argument domain it reaches the offline tools —
    /// `Tools/scenecheck render <out> 3582294895 -SceneScriptDate 2026-10-19` draws Fujiyama's
    /// Monday. Only the scripts' `Date` moves; nothing else in the app reads it.
    private static let clockOffset: TimeInterval? = {
        guard let raw = UserDefaults.standard.string(forKey: "SceneScriptDate") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date.timeIntervalSinceNow }
        }
        return nil
    }()

    // MARK: - Registration

    /// Evaluate one script as a module and return its exports — `update` and `init` — plus
    /// whatever `prologue` declared and `epilogue` names for the caller to read back.
    ///
    /// Each script becomes a closure rather than a global, because Wallpaper Engine's are ES
    /// modules: they keep state in module-level `let`s, and several dozen of them in this library
    /// declare the same names. Sharing one global scope would have the last script loaded
    /// silently drive every layer before it.
    ///
    /// `applyUserProperties` is handed the *wallpaper's* user properties, the keys of
    /// `project.json`'s `general.properties` — 42 scripts in this library define it, and the
    /// keys they test are those (`_24hourtime`, `invertcar`, `timeofday`), never script
    /// settings. It used to be handed the script's own `scriptproperties` instead, and only when
    /// the script declared any, so every one of those tests came up false. No script reads
    /// `engine.userProperties` (0 of the library's 1220 script fields), so that is not provided.
    ///
    /// `layer` is the object id the script is bound to. Its `thisLayer` is then that layer's
    /// handle — the same object `thisScene.getLayer` returns for it — rather than the detached
    /// stand-in every script used to share, so a script that writes `thisLayer.text` or reads
    /// `thisLayer.origin` is talking about its own layer.
    private func module(_ source: String, properties: [String: WEScriptPropertyValue]?,
                        layer: Int? = nil,
                        prologue: String = "", epilogue: String = "") -> JSValue? {
        let literal = Self.objectLiteral(properties)
        let ownLayer = layer.map { "var thisLayer = __handles[\($0)] || __detachedLayer;" } ?? ""
        let wrapped = """
        (function() {
        'use strict';
        var scriptPropertyOverrides = \(literal);
        \(ownLayer)
        \(prologue)
        \(Self.stripModuleSyntax(source))
        if (typeof scriptProperties !== 'undefined' && scriptProperties) {
            for (var k in scriptPropertyOverrides) { scriptProperties[k] = scriptPropertyOverrides[k]; }
        }
        if (typeof applyUserProperties === 'function') {
            try { applyUserProperties(\(userPropertiesLiteral)); } catch (e) {}
        }
        return {
            update: typeof update === 'function' ? update : null,
            init: typeof init === 'function' ? init : null\(epilogue.isEmpty ? "" : ",\n" + epilogue)
        };
        })()
        """
        failure = nil
        // A module that loops at top level is terminated here, which the exception handler
        // records like any throw, so it registers nothing and its layer keeps the baked value.
        limitExecution(to: Self.moduleBudget)
        let evaluated = context.evaluateScript(wrapped)
        limitExecution(to: Self.budget)
        guard let value = evaluated, value.isObject, failure == nil else {
            failure = nil
            return nil
        }
        return value
    }

    private static func function(_ exports: JSValue, _ name: String) -> JSValue? {
        guard let f = exports.objectForKeyedSubscript(name), !f.isNull, !f.isUndefined else {
            return nil
        }
        return f
    }

    /// Prepare one script and return the handle used to drive it, or nil if it exports no
    /// `update` this runtime can call.
    ///
    /// `layer` is the id of the text object the script drives, so that what it produces is also
    /// what `thisScene.getLayer` reads back for that layer — Pixels' world clocks read the offset
    /// another text layer shows, and its calendar marker copies the string of the day it sits on.
    func register(_ source: String, properties: [String: WEScriptPropertyValue]?,
                  layer: Int? = nil) -> Int? {
        guard let exports = module(source, properties: properties, layer: layer),
              let update = Self.function(exports, "update") else { return nil }
        updates.append(update)
        inits.append(Self.function(exports, "init"))
        textLayers.append(layer)
        return updates.count - 1
    }

    // MARK: - Driving

    /// Call `function` under the time budget. Nil when it threw or overran, and the handle is
    /// then abandoned; `.some(nil)` when it ran but returned nothing.
    private func call(_ function: JSValue, _ arguments: [Any], handle: Int?) -> JSValue?? {
        guard let ran = call(function, arguments, charging: handle.map(Charge.text)) else {
            if let handle { abandoned.insert(handle) }
            return nil
        }
        return ran
    }

    /// `call` without the abandonment, for callers that keep their own record of it.
    ///
    /// A call that loops is stopped by the execution time limit (see `setExecutionTimeLimit`)
    /// and arrives here as a throw; the wall-clock check after it still catches one that is
    /// merely slow, and is all there is on a system without the limit.
    private func call(_ function: JSValue, _ arguments: [Any], charging: Charge? = nil) -> JSValue?? {
        failure = nil
        let started = Date()
        let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = function.call(withArguments: arguments)
        let overran = Date().timeIntervalSince(started) > Self.budget
        if let charging {
            let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStarted
            charge(charging, TimeInterval(cpu) / 1e9)
        }
        let threw = failure != nil
        failure = nil
        if overran || threw { return nil }
        guard let result, !result.isNull, !result.isUndefined else { return .some(nil) }
        return .some(result)
    }

    // MARK: - The per-poll budget

    /// Who a poll's time is charged to.
    private enum Charge: Hashable {
        case text(Int)
        case property(Int)
    }

    /// What each script has spent in the poll under way; nil between polls, so the calls made at
    /// load — `init`, the settle, media and layout scripts — are never charged.
    private var tickSpending: [Charge: TimeInterval]?
    private var tickSpent: TimeInterval = 0

    /// Run one 10 Hz poll's worth of scripts under `tickBudget` in total.
    ///
    /// The 20 ms limit is per call, and a poll makes a great many: `tickProperties` runs up to 12
    /// steps of every live property script, then every scripted string runs once. A script that
    /// took 19 ms a step was never dropped, and cost the main thread some 228 ms ten times a
    /// second. So the poll carries a total as well, and once it is past it the script that has
    /// spent the most of it is abandoned — repeatedly, until the rest fit — rather than whichever
    /// cheap clock happened to be called next. Abandoned scripts keep what they last produced.
    ///
    /// Charged in thread CPU time rather than wall time, so a poll the scheduler happened to
    /// preempt cannot cost a calendar its script. Measured over the installed library's first
    /// polls (104 of them, `Tools/scenecheck render`, other scenes loading alongside): the
    /// costliest spent 1.8 ms of CPU in its scripts, a third of the total. Module top levels, for
    /// `moduleBudget`, took at most 5.5 ms of 576.
    func tick(_ body: () -> Void) {
        tickSpending = [:]
        tickSpent = 0
        defer { tickSpending = nil }
        body()
    }

    private func charge(_ charge: Charge, _ seconds: TimeInterval) {
        guard var spending = tickSpending else { return }
        spending[charge, default: 0] += seconds
        tickSpent += seconds
        while tickSpent > Self.tickBudget,
              let (worst, cost) = spending.max(by: { $0.value < $1.value }) {
            spending[worst] = nil
            tickSpent -= cost
            switch worst {
            case .text(let handle): abandoned.insert(handle)
            case .property(let index): abandonedProperties.insert(index)
            }
            NSLog("[SceneScript] abandoned \(worst): %.1f ms of a %.0f ms poll",
                  cost * 1000, Self.tickBudget * 1000)
        }
        tickSpending = spending
    }

    /// Run one script and return the string it produced, or nil to keep whatever is on screen.
    ///
    /// An empty string is returned as such, not as nil: it is what every "now playing" readout
    /// produces with nothing playing — 20 of this library's scripted text layers return a
    /// `mediaData` that only a media event ever fills — and Wallpaper Engine draws it as nothing.
    func update(_ handle: Int, value: String) -> String? {
        guard handle < updates.count, !abandoned.contains(handle) else { return nil }
        guard let ran = call(updates[handle], [value], handle: handle), let result = ran else {
            return nil
        }
        return produced(result.toString(), by: handle)
    }

    /// Keep a text layer's handle in step with the string its own script produced, without
    /// reporting it back as a write: the caller is about to draw it anyway.
    private func produced(_ text: String?, by handle: Int) -> String? {
        guard let text, handle < textLayers.count, let layer = textLayers[handle] else { return text }
        quiet?.call(withArguments: [layer, "text", text])
        return text
    }

    /// Run the script's `init`, if it exported one, and return the string it produced.
    ///
    /// Wallpaper Engine calls `init` once with the baked value and shows what it returns before
    /// `update` ever runs. The typewriter readouts on Lost Landscape and Fujiyama's media blocks
    /// return "" from it so a track name can be typed in from nothing; skipping it left them on
    /// the baked "Text Layer" the author's editor had saved.
    func initialText(_ handle: Int, value: String) -> String? {
        guard handle < inits.count, !abandoned.contains(handle), let initFunction = inits[handle],
              let ran = call(initFunction, [value], handle: handle), let result = ran else {
            return nil
        }
        return produced(result.toString(), by: handle)
    }

    // MARK: - Layer handles

    /// What a script can read about a layer through `thisScene.getLayer` and `thisLayer`.
    struct LayerState {
        var id: Int
        var name: String?
        var text: String?
        /// The layer's own flag, after the media verdict — not whether an ancestor hides it,
        /// which is not what Wallpaper Engine's `visible` reports either.
        var visible: Bool
        var alpha: Double
        var origin: (Double, Double, Double)
        var scale: (Double, Double, Double)
        var angles: (Double, Double, Double)
        /// The layer's effects by name, and whether each is on.
        var effects: [String: Bool]
    }

    /// Give every script a handle on every layer.
    ///
    /// `thisScene.getLayer` used to answer null, so any script that touched another layer threw
    /// on its first line and kept its baked value forever. That is how the library's calendars
    /// broke, all of them: Fujiyama writes its year, day and month into three plain text layers
    /// by name, Pixels moves its "today" marker onto the cell `C<day>` and its world clocks read
    /// their UTC offset from a sibling, and Winter Conch Street switches its holiday greeting
    /// through one. Measured before this, those showed 2027 / 26 / January, a marker on the 1st,
    /// two clocks at 00:00:00 on 01 January, and "Happy New Year" in October.
    ///
    /// A handle holds plain values. Writing one is recorded and reported by `drainWrites`; the
    /// caller decides what of it the scene can honour. Nothing else is offered on it — no
    /// texture animation, no sound, no parent — so a script that reaches for any of that still
    /// throws and keeps its baked value, as before.
    func declareLayers(_ layers: [LayerState]) {
        let list: [[String: Any]] = layers.map { layer in
            var entry: [String: Any] = [
                "id": layer.id,
                "visible": layer.visible,
                "alpha": layer.alpha,
                "origin": [layer.origin.0, layer.origin.1, layer.origin.2],
                "scale": [layer.scale.0, layer.scale.1, layer.scale.2],
                "angles": [layer.angles.0, layer.angles.1, layer.angles.2],
                "effects": layer.effects,
            ]
            if let name = layer.name { entry["name"] = name }
            if let text = layer.text { entry["text"] = text }
            return entry
        }
        guard JSONSerialization.isValidJSONObject(list),
              let data = try? JSONSerialization.data(withJSONObject: list),
              let json = String(data: data, encoding: .utf8) else { return }
        context.evaluateScript("__declareLayers(\(json));")
    }

    /// One thing a script changed on a layer.
    enum Write {
        case text(String)
        case visible(Bool)
        case alpha(Double)
        case origin(CGPoint)
        case scale(CGVector)
        case effect(name: String, visible: Bool)
    }

    /// Everything scripts have written onto layers since the last drain, latest value only.
    func drainWrites() -> [(layer: Int, write: Write)] {
        guard let drained = context.evaluateScript("__drain()")?.toArray() as? [[Any]] else {
            return []
        }
        var out: [(layer: Int, write: Write)] = []
        for entry in drained where entry.count == 4 {
            guard let id = (entry[0] as? NSNumber)?.intValue, let key = entry[1] as? String else {
                continue
            }
            let value = entry[2]
            let write: Write?
            switch key {
            case "text": write = (value as? String).map(Write.text)
            case "visible": write = (value as? NSNumber).map { .visible($0.boolValue) }
            case "alpha": write = (value as? NSNumber).map { .alpha($0.doubleValue) }
            case "origin", "scale":
                guard let v = value as? [NSNumber], v.count >= 2 else { write = nil; break }
                let (x, y) = (v[0].doubleValue, v[1].doubleValue)
                write = key == "origin" ? .origin(CGPoint(x: x, y: y)) : .scale(CGVector(dx: x, dy: y))
            case "effect":
                guard let name = entry[3] as? String, let on = value as? NSNumber else {
                    write = nil; break
                }
                write = .effect(name: name, visible: on.boolValue)
            default: write = nil
            }
            if let write { out.append((id, write)) }
        }
        return out
    }

    // MARK: - Live property scripts

    /// A visibility, opacity, position or scale script run on the clock.
    private struct LiveProperty {
        let layer: Int
        let runner: JSValue
    }
    private var liveProperties: [LiveProperty] = []
    private var abandonedProperties: Set<Int> = []

    /// Anything whose answer the runtime cannot supply: the cursor and its events, audio and
    /// media, randomness, and the parts of the layer API a handle does not offer.
    private static let liveBlockers = ["cursor", "input", "media", "Media", "audio", "Audio",
                                       "random", "getAnimation", "getTextureAnimation",
                                       "getVideoTexture", "createLayer", "destroyLayer",
                                       "getLayerById", "registerCallback", "openUserShortcut",
                                       "playSound", "getParent", "getChildren"]
    private static let calendarReads = ["getFullYear", "getMonth", "getDate", "getDay", "getHours",
                                        "getMinutes", "getSeconds", "toLocaleDateString",
                                        "toLocaleTimeString", "toDateString"]

    /// A property script this runtime drives live: what it is bound to, and its settings.
    struct PropertyScript {
        let layer: Int
        /// `visible`, `alpha`, `origin` or `scale`.
        let property: String
        let source: String
        let properties: [String: WEScriptPropertyValue]?
    }

    /// Which property scripts to run on the clock, out of the scripts on these objects.
    ///
    /// Two kinds, and only these. A script that reads the calendar — a `Date` and one of its
    /// fields — and nothing the runtime cannot answer. And a script that reads `shared` state
    /// which only scripts of the first kind write: Fujiyama keeps today's weekday in
    /// `shared.hover`, and the marker, the seven labels' size, lift and opacity all follow it.
    ///
    /// The second rule is what keeps this narrow. 11 scenes in this library use `shared`, nearly
    /// all of it cursor and media state, and a script waiting on a key nobody here writes would
    /// run against `undefined` and land wherever that sends it. Over the installed library the
    /// selection is 28 scripts in three scenes: Fujiyama's calendar (1 + 23), Pixels' calendar
    /// marker, month-length cells and day/night icon (3), and the seconds bar on 麻匪 (1).
    /// The stopwatch scripts that read `Date.now()` only to time an intro fade — Three-Body's
    /// and Moon's — are not calendar reads and stay out, as do Lonely Cat's AM/PM sprites,
    /// which flip a texture-animation frame this runtime does not have.
    static func liveProperties(in objects: [WESceneObject], skipping skipped: Set<Int>) -> [PropertyScript] {
        var candidates: [PropertyScript] = []
        for obj in objects {
            guard let id = obj.id, !skipped.contains(id) else { continue }
            let bound: [(String, String?, [String: WEScriptPropertyValue]?)] = [
                ("visible", obj.visibleScript, obj.visibleScriptProperties),
                ("alpha", obj.alphaScript, obj.alphaScriptProperties),
                ("origin", obj.originScript, obj.originScriptProperties),
                ("scale", obj.scaleScript, obj.scaleScriptProperties),
            ]
            for (property, source, properties) in bound {
                guard let source, source.contains("function update"),
                      !liveBlockers.contains(where: { source.contains($0) }) else { continue }
                candidates.append(PropertyScript(layer: id, property: property, source: source,
                                                 properties: properties))
            }
        }
        let readsCalendar: (String) -> Bool = { source in
            source.contains("Date") && calendarReads.contains { source.contains($0) }
        }
        let clock = candidates.filter { readsCalendar($0.source) }
        let produced = Set(clock.flatMap { sharedKeys(in: $0.source, writes: true) })
        let followers = candidates.filter { script in
            guard !readsCalendar(script.source) else { return false }
            let read = Set(sharedKeys(in: script.source, writes: false))
            return !read.isEmpty && read.isSubset(of: produced)
        }
        return clock + followers
    }

    /// The `shared` keys a script assigns, or the ones it reads.
    private static func sharedKeys(in source: String, writes: Bool) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"shared\.(\w+)(\s*=(?!=))?"#) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            let assigns = match.range(at: 2).location != NSNotFound
            guard assigns == writes, let key = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[key])
        }
    }

    /// Prepare one property script and run its `init`. False when it fails to load.
    @discardableResult
    func registerProperty(_ script: PropertyScript) -> Bool {
        guard let exports = module(script.source, properties: script.properties, layer: script.layer),
              let update = Self.function(exports, "update"),
              let makeRunner = context.objectForKeyedSubscript("__property"),
              let runner = makeRunner.call(withArguments: [script.layer, script.property, update]),
              runner.isObject else { return false }
        if let initFunction = Self.function(exports, "init"),
           let makeInit = context.objectForKeyedSubscript("__propertyInit"),
           let initRunner = makeInit.call(withArguments: [script.layer, script.property, initFunction]),
           call(initRunner, []) == nil {
            return false
        }
        liveProperties.append(LiveProperty(layer: script.layer, runner: runner))
        return true
    }

    var hasLiveProperties: Bool { !liveProperties.isEmpty }

    /// One display frame's worth of every live property script, at `frametime`. Whether
    /// anything they wrote moved.
    private func stepProperties(frametime: Double) -> Bool {
        context.evaluateScript("__changed = false;")
        for (index, property) in liveProperties.enumerated() where !abandonedProperties.contains(index) {
            if call(property.runner, [frametime], charging: .property(index)) == nil {
                abandonedProperties.insert(index)
            }
        }
        return context.objectForKeyedSubscript("__changed")?.toBool() ?? false
    }

    /// Run the live property scripts until they come to rest, before the first frame is drawn.
    ///
    /// Wallpaper Engine runs them every frame from load, and the ones that move a layer ease
    /// toward their target — `mix(value, target, speed * engine.frametime)` — so on screen a
    /// calendar slides into place within half a second of loading. Run once, they would leave it
    /// a sixth of the way there. So they are stepped at 60 Hz until nothing they write moves, or
    /// for at most four simulated seconds. Measured: Fujiyama's 24 come to rest in 78 steps,
    /// 5–22 ms of load time off the main thread, which puts one steady-state step — what a
    /// 10 Hz poll costs on any day but the turn of it — near 0.1 ms. Pixels' and 麻匪's take 2.
    ///
    /// Returns the layers whose scripts all came through; a script that threw or overran is
    /// abandoned, and its layer keeps whatever it reached.
    func settleProperties() -> Set<Int> {
        guard !liveProperties.isEmpty else { return [] }
        let started = Date()
        for _ in 0..<240 {
            guard stepProperties(frametime: 1.0 / 60.0) else { break }
            // Each call is already held to the budget; this bounds the sum.
            if Date().timeIntervalSince(started) > 0.25 { break }
        }
        var healthy = Set(liveProperties.map(\.layer))
        for index in abandonedProperties { healthy.remove(liveProperties[index].layer) }
        return healthy
    }

    /// Advance the live property scripts by `elapsed` seconds of display frames.
    ///
    /// The scripts are written for a per-frame call and polled at 10 Hz, so a poll runs the
    /// frames it stands for, at 60 Hz, stopping as soon as one moves nothing — which on a
    /// calendar is every poll but the ones either side of midnight. Running one step with the
    /// whole interval as `frametime` instead would hand an easing script a factor of 1 or more,
    /// and `mix` beyond 1 overshoots rather than arrives.
    func tickProperties(elapsed: TimeInterval) {
        guard !liveProperties.isEmpty else { return }
        let steps = min(max(Int((elapsed * 60).rounded()), 1), 12)
        for _ in 0..<steps {
            guard stepProperties(frametime: 1.0 / 60.0) else { break }
        }
    }

    // MARK: - Media integration with nothing playing

    /// The callbacks and constants only a media-integration script uses.
    private static let mediaMarkers = ["mediaPlaybackChanged", "mediaPropertiesChanged",
                                       "mediaThumbnailChanged", "mediaTimelineChanged",
                                       "MediaPlaybackEvent"]

    static func readsMedia(_ source: String) -> Bool {
        mediaMarkers.contains { source.contains($0) }
    }

    /// What a visibility- or opacity-bound media script decides about its layer when nothing is
    /// playing.
    struct MediaVisibility {
        /// The script leaves its own layer hidden.
        var hidesSelf = false
        /// Layers it hid by name through `thisScene.getLayer`.
        var hiddenNames: [String] = []
    }

    /// Run a media script the way Wallpaper Engine runs it with no player open: `init`, then one
    /// `update`, and no media event at all. Nil when the script is not a media script, or threw.
    ///
    /// No event is delivered because none is: Wallpaper Engine has nothing to report, and the
    /// scripts are written for that — Lost Landscape's album cover starts from
    /// `var mediaState = MediaPlaybackEvent.PLAYBACK_STOPPED` and hides itself in `update`
    /// until told otherwise, which is why its flat white placeholder and the "Text Layer"
    /// strings beneath it never show in Wallpaper Engine. A script that only reacts inside an
    /// event handler therefore decides nothing here and keeps its authored value.
    ///
    /// Only ever *hides*. A script that turns a layer the author saved hidden back on is not
    /// believed, because nothing in this library needs it and a wrong "on" puts a placeholder
    /// on the desktop where a wrong "off" only leaves a gap that the media block had anyway.
    ///
    /// Evaluated once at load rather than every frame: with no media event, the only inputs
    /// left are the script's own settings, so the answer cannot change while the scene runs.
    func hiddenWithNoMedia(_ source: String, property: String, authored: Any,
                           properties: [String: WEScriptPropertyValue]? = nil) -> MediaVisibility? {
        guard Self.readsMedia(source) else { return nil }
        // `thisLayer` and `thisScene` are shadowed per script so that what one script writes
        // cannot leak into the next, and so a write through them can be read back.
        let prologue = """
        var __named = {};
        function __layer(visible) {
            return { visible: visible, alpha: 1, name: '',
                     origin: new Vec3(0, 0, 0), scale: new Vec3(1, 1, 1), angles: new Vec3(0, 0, 0),
                     getEffect: function() { return { visible: true }; },
                     getPropertyValue: function() { return null; } };
        }
        var thisLayer = __layer(\(property == "visible" ? Self.jsLiteral(authored) : "true"));
        var thisScene = {
            getLayer: function(name) {
                if (!__named[name]) { __named[name] = __layer(undefined); }
                return __named[name];
            },
            getLayerById: function() { return __layer(undefined); },
            getTime: function() { return 0; }
        };
        """
        let epilogue = "layer: thisLayer, named: __named"
        // The user's own script settings, as `register` and `staticOrigin` pass them: a player
        // block the user configured differently must be decided on their settings, not the
        // defaults.
        guard let exports = module(source, properties: properties, prologue: prologue,
                                   epilogue: epilogue)
        else { return nil }

        var value: Any = authored
        if let initFunction = Self.function(exports, "init") {
            guard let ran = call(initFunction, [value], handle: nil) else { return nil }
            if let result = ran, let v = result.toObject() { value = v }
        }
        var returned: JSValue?
        if let update = Self.function(exports, "update") {
            guard let ran = call(update, [value], handle: nil) else { return nil }
            returned = ran
        }

        var outcome = MediaVisibility()
        let layer = exports.objectForKeyedSubscript("layer")
        if let visible = layer?.objectForKeyedSubscript("visible"), visible.isBoolean,
           !visible.toBool() {
            outcome.hidesSelf = true
        }
        if property == "visible", let returned, returned.isBoolean, !returned.toBool() {
            outcome.hidesSelf = true
        }
        if let named = exports.objectForKeyedSubscript("named")?.toDictionary() {
            for (name, record) in named {
                guard let name = name as? String,
                      let visible = (record as? [String: Any])?["visible"] as? Bool,
                      !visible else { continue }
                outcome.hiddenNames.append(name)
            }
        }
        return outcome
    }

    // MARK: - Layout scripts

    /// Anything that would make a position script's answer change after load.
    private static let impureMarkers = ["runtime", "frametime", "Date", "cursor", "input",
                                        "media", "audio", "Audio", "getLayer", "thisLayer",
                                        "thisScene", "random", "timeOfDay", "getMillis", "function init",
                                        "shared"]

    /// The position an `origin` script puts its layer at, when that position is a pure function
    /// of the script's own settings and the canvas size.
    ///
    /// Honkai: Star Rail places its whole clock this way — 20 layers carry the same script,
    /// `value.x = scriptProperties.x * engine.canvasSize.x`, with `x` and `y` bound to user
    /// sliders. The `value` baked beside the script is meaningless for those layers: the weekday,
    /// date and time each bake an origin that, through their parents, lands on the same point
    /// within a pixel, so the spaced "S U N D A Y" was drawn straight over the time. Only scripts
    /// that read nothing which moves — no clock, cursor, audio, media or other layer — are run,
    /// once, at load; anything else keeps the baked value as before.
    func staticOrigin(_ source: String, properties: [String: WEScriptPropertyValue]?,
                      authored: String?) -> String? {
        guard !Self.impureMarkers.contains(where: { source.contains($0) }),
              let exports = module(source, properties: properties),
              let update = Self.function(exports, "update") else { return nil }
        let (x, y, z) = (authored ?? "").parseVector3()
        guard let vector = context.evaluateScript("new Vec3(\(x), \(y), \(z))"),
              let ran = call(update, [vector], handle: nil), let result = ran,
              let rx = result.objectForKeyedSubscript("x"), rx.isNumber,
              let ry = result.objectForKeyedSubscript("y"), ry.isNumber else { return nil }
        let rz = result.objectForKeyedSubscript("z").flatMap { $0.isNumber ? $0.toDouble() : nil } ?? z
        let (fx, fy) = (rx.toDouble(), ry.toDouble())
        guard fx.isFinite, fy.isFinite, rz.isFinite else { return nil }
        return "\(fx) \(fy) \(rz)"
    }

    private static func jsLiteral(_ value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let d = value as? Double { return "\(d)" }
        return "undefined"
    }

    // MARK: - Translating a module into something JSContext will take

    /// `JSContext` evaluates scripts, not modules, so `import`/`export` are syntax errors that
    /// would fail the whole file. Both are removed rather than resolved: the modules Wallpaper
    /// Engine offers are declared in the prelude instead, and an `export` on a declaration only
    /// ever means "also visible outside", which inside our closure it already is.
    /// An `export` that follows other code on its line — what a minifier leaves:
    /// `"use strict";export var scriptProperties=…;export function update(e){…}`. One script in
    /// this library is written that way, 麻匪's seconds readout, and since the line-start rule
    /// above never saw it the whole module was a syntax error and the layer sat on its baked
    /// "56 s" — beside a seconds bar that now runs live.
    private static let inlineExport = try? NSRegularExpression(
        pattern: #"([;})])\s*export\s+(?=(?:var|let|const|function|class)\b)"#)

    private static func stripInlineExports(_ line: String) -> String {
        guard line.contains("export"), let inlineExport else { return line }
        return inlineExport.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1")
    }

    private static func stripModuleSyntax(_ source: String) -> String {
        var out: [String] = []
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("import ") { continue }
            if line.hasPrefix("export default ") {
                out.append(String(raw).replacingOccurrences(of: "export default ", with: "var weDefault = "))
                continue
            }
            if line.hasPrefix("export ") {
                out.append(String(raw).replacingOccurrences(of: "export ", with: ""))
                continue
            }
            out.append(Self.stripInlineExports(String(raw)))
        }
        return out.joined(separator: "\n")
    }

    private static func objectLiteral(_ properties: [String: WEScriptPropertyValue]?) -> String {
        guard let properties, !properties.isEmpty else { return "{}" }
        let pairs = properties.map { key, value in
            "\(jsString(key)): \(value.jsLiteral)"
        }
        return "{\(pairs.joined(separator: ", "))}"
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }

    /// The globals Wallpaper Engine hands a script. Everything here is either inert or a
    /// straight computation — nothing reaches the machine.
    private static let prelude = """
    'use strict';
    var WEMath = {
        mix: function(a, b, t) { return a + (b - a) * t; },
        lerp: function(a, b, t) { return a + (b - a) * t; },
        clamp: function(v, lo, hi) { return Math.min(Math.max(v, lo), hi); },
        saturate: function(v) { return Math.min(Math.max(v, 0), 1); },
        smoothstep: function(e0, e1, x) {
            var t = Math.min(Math.max((x - e0) / (e1 - e0), 0), 1);
            return t * t * (3 - 2 * t);
        },
        radians: function(d) { return d * Math.PI / 180; },
        degrees: function(r) { return r * 180 / Math.PI; }
    };
    var WEColor = WEMath;
    function createScriptProperties() {
        var props = {};
        var api = {};
        ['addSlider', 'addCheckbox', 'addColor', 'addText', 'addTextInput',
         'addCombo', 'addFilePicker', 'addSeparator'].forEach(function(name) {
            api[name] = function(d) {
                if (d && d.name !== undefined) { props[d.name] = d.value; }
                return api;
            };
        });
        api.finish = function() { return props; };
        return api;
    }
    function Vec3(x, y, z) {
        if (!(this instanceof Vec3)) { return new Vec3(x, y, z); }
        if (x && typeof x === 'object') { z = x.z; y = x.y; x = x.x; }
        this.x = +x || 0; this.y = +y || 0; this.z = +z || 0;
    }
    function __vecArg(v) { return (v && typeof v === 'object') ? v : { x: +v, y: +v, z: +v }; }
    Vec3.prototype.copy = function() { return new Vec3(this.x, this.y, this.z); };
    Vec3.prototype.add = function(o) { o = __vecArg(o); return new Vec3(this.x + o.x, this.y + o.y, this.z + (o.z || 0)); };
    Vec3.prototype.subtract = function(o) { o = __vecArg(o); return new Vec3(this.x - o.x, this.y - o.y, this.z - (o.z || 0)); };
    Vec3.prototype.multiply = function(o) { o = __vecArg(o); return new Vec3(this.x * o.x, this.y * o.y, this.z * (o.z === undefined ? 1 : o.z)); };
    Vec3.prototype.divide = function(o) { o = __vecArg(o); return new Vec3(this.x / o.x, this.y / o.y, this.z / (o.z === undefined ? 1 : o.z)); };
    Vec3.prototype.length = function() { return Math.sqrt(this.x * this.x + this.y * this.y + this.z * this.z); };
    Vec3.prototype.normalize = function() { var l = this.length() || 1; return new Vec3(this.x / l, this.y / l, this.z / l); };
    Vec3.prototype.toString = function() { return this.x + ' ' + this.y + ' ' + this.z; };
    // Wallpaper Engine's playback states. Fujiyama's own script spells the numbering out
    // ("关闭 0 播放1 暂停2": stopped 0, playing 1, paused 2) and compares against the bare numbers.
    var MediaPlaybackEvent = { PLAYBACK_STOPPED: 0, PLAYBACK_PLAYING: 1, PLAYBACK_PAUSED: 2 };
    var engine = {
        registerCallback: function() {},
        removeCallback: function() {},
        getMillis: function() { return Date.now(); },
        log: function() {},
        canvasSize: new Vec3(0, 0, 0),
        // Seconds since the previous frame. The live property scripts are stepped at 60 Hz and
        // set it per step; anything else reads a frame's worth rather than `undefined`, which
        // turns every easing in the library into NaN.
        frametime: 1 / 60
    };
    // State every script in a scene shares, as Wallpaper Engine's own `shared` is. Before it
    // existed here, every script that mentioned it threw on that line.
    var shared = {};

    // Layer handles — see `declareLayers`. Values are held in `__state`; every write through a
    // handle is coerced, compared, and recorded in `__dirty` for `__drain` to report.
    var __state = Object.create(null);
    var __handles = Object.create(null);
    var __byName = Object.create(null);
    var __dirty = Object.create(null);
    var __changed = false;
    function __same(a, b) {
        if (a instanceof Vec3 && b instanceof Vec3) {
            return Math.abs(a.x - b.x) < 1e-4 && Math.abs(a.y - b.y) < 1e-4 && Math.abs(a.z - b.z) < 1e-4;
        }
        if (typeof a === 'number' && typeof b === 'number') { return Math.abs(a - b) < 1e-4; }
        return a === b;
    }
    function __toVec3(v) {
        if (!v || typeof v !== 'object') { return undefined; }
        var r = new Vec3(+v.x, +v.y, v.z === undefined ? 0 : +v.z);
        return (isFinite(+v.x) && isFinite(+v.y) && isFinite(r.z)) ? r : undefined;
    }
    var __coerce = {
        text: function(v) { return (v === null || v === undefined) ? '' : String(v); },
        visible: function(v) { return !!v; },
        alpha: function(v) { v = +v; return isFinite(v) ? v : undefined; },
        origin: __toVec3,
        scale: __toVec3,
        angles: __toVec3
    };
    function __record(id, key, effect) {
        __dirty[id + '\\u0000' + key + '\\u0000' + (effect === undefined ? '' : effect)] = [id, key, effect];
        __changed = true;
    }
    function __declareLayers(list) {
        list.forEach(function(d) {
            var id = d.id;
            var s = {
                text: d.text, visible: d.visible, alpha: d.alpha,
                origin: new Vec3(d.origin[0], d.origin[1], d.origin[2]),
                scale: new Vec3(d.scale[0], d.scale[1], d.scale[2]),
                angles: new Vec3(d.angles[0], d.angles[1], d.angles[2]),
                effects: d.effects || {}
            };
            __state[id] = s;
            var h = { name: d.name, getPropertyValue: function() { return null; } };
            Object.keys(__coerce).forEach(function(key) {
                Object.defineProperty(h, key, {
                    enumerable: true,
                    get: function() { var v = s[key]; return (v instanceof Vec3) ? v.copy() : v; },
                    set: function(v) {
                        var c = __coerce[key](v);
                        if (c === undefined || __same(c, s[key])) { return; }
                        s[key] = c;
                        __record(id, key);
                    }
                });
            });
            var effects = Object.create(null);
            h.getEffect = function(name) {
                if (!Object.prototype.hasOwnProperty.call(s.effects, name)) { return null; }
                if (!effects[name]) {
                    var e = { name: name };
                    Object.defineProperty(e, 'visible', {
                        enumerable: true,
                        get: function() { return s.effects[name]; },
                        set: function(v) {
                            v = !!v;
                            if (v === s.effects[name]) { return; }
                            s.effects[name] = v;
                            __record(id, 'effect', name);
                        }
                    });
                    effects[name] = e;
                }
                return effects[name];
            };
            __handles[id] = h;
            if (typeof d.name === 'string' && !(d.name in __byName)) { __byName[d.name] = id; }
        });
    }
    function __drain() {
        var out = [];
        for (var k in __dirty) {
            var e = __dirty[k], s = __state[e[0]];
            var v = e[1] === 'effect' ? s.effects[e[2]] : s[e[1]];
            if (v instanceof Vec3) { v = [v.x, v.y, v.z]; }
            out.push([e[0], e[1], v, e[2] === undefined ? null : e[2]]);
        }
        __dirty = Object.create(null);
        return out;
    }
    function __quiet(id, key, v) { var s = __state[id]; if (s) { s[key] = v; } }
    function __property(id, key, update) {
        return function(frametime) {
            engine.frametime = frametime;
            var h = __handles[id];
            var r = update(h[key]);
            if (r !== undefined && r !== null) { h[key] = r; }
        };
    }
    function __propertyInit(id, key, init) {
        return function() {
            var h = __handles[id];
            var r = init(h[key]);
            if (r !== undefined && r !== null) { h[key] = r; }
        };
    }
    function __shiftClock(offset) {
        var Real = Date;
        function Shifted() {
            if (!(this instanceof Shifted)) { return new Real(Real.now() + offset).toString(); }
            if (arguments.length === 0) { return new Real(Real.now() + offset); }
            var args = [null].concat(Array.prototype.slice.call(arguments));
            return new (Function.prototype.bind.apply(Real, args))();
        }
        Shifted.prototype = Real.prototype;
        Shifted.now = function() { return Real.now() + offset; };
        Shifted.UTC = Real.UTC;
        Shifted.parse = Real.parse;
        Date = Shifted;
    }

    // The `thisLayer` of a script bound to no known layer.
    var __detachedLayer = { name: '', visible: true, getPropertyValue: function() { return null; } };
    var thisLayer = __detachedLayer;
    var thisScene = {
        getLayer: function(name) {
            var id = __byName[name];
            return id === undefined ? null : __handles[id];
        },
        getLayerById: function() { return null; },
        getTime: function() { return Date.now() / 1000; }
    };
    """
}

/// A value out of a scene's `scriptproperties` block: the slider positions and toggles the user
/// left the script on. Numbers, flags and strings are all that occur.
enum WEScriptPropertyValue: Decodable {
    case number(Double)
    case bool(Bool)
    case string(String)

    private struct Wrapped: Decodable {
        var value: WEScriptPropertyValue?
        private enum CodingKeys: String, CodingKey { case value, user }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = (try? c.decodeIfPresent(WEScriptPropertyValue.self, forKey: .value)) ?? nil
            // The busiest kind of binding there is to get wrong: 183 of the 283 user bindings in
            // this library whose project value differs from the authored one are script settings,
            // the clocks' among them. Porsche's `use24hFormat` is authored false and set true;
            // Lonely Cat's `use12hFormat` is authored false and set true, and its `dateFormat`
            // likewise on 30 layers. Some of these wrap a binding inside a binding; the outermost
            // is the one resolved, as it is everywhere else. Typed by what the project holds
            // rather than what was authored: the property's own type is the authority on whether
            // the script reads a flag, a number or a string.
            if let raw = SceneUserProperties.resolveRaw(c, .user, decoder: decoder) {
                switch raw {
                case .bool(let b): value = .bool(b)
                case .number(let d): value = .number(d)
                case .string(let s): value = .string(s)
                }
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool first: a JSON `true` also decodes as the number 1.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        // A script property the wallpaper also exposes as a user setting arrives wrapped, the
        // same `{"user": .., "value": ..}` shape every other scene field uses. Without this the
        // whole properties dictionary fails to decode and every slider falls back to its default.
        if let wrapped = try? c.decode(Wrapped.self), let value = wrapped.value {
            self = value
            return
        }
        throw DecodingError.typeMismatch(
            Self.self,
            DecodingError.Context(codingPath: decoder.codingPath,
                                  debugDescription: "unsupported script property"))
    }

    var jsLiteral: String {
        switch self {
        case .number(let d): return "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .string(let s):
            let data = try? JSONSerialization.data(withJSONObject: [s])
            let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(encoded.dropFirst().dropLast())
        }
    }
}
