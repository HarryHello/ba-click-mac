import Foundation
import simd
import Darwin

// Minimal assertion harness (kept dependency-free to match the project's
// raw-swiftc build style). Run via ./test.sh.

var passed = 0
var failures = 0

func expect(_ condition: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failures += 1
        print("FAIL: \(name) (\(file):\(line))")
    }
}

func approx(_ a: Float, _ b: Float, _ eps: Float = 1e-4) -> Bool {
    abs(a - b) <= eps
}

// MARK: - BAEval keyframe evaluation

func testBAEval() {
    let linear: [[Float]] = [[0, 0], [0.5, 1], [1, 2]]
    expect(approx(BAEval.number(linear, 0.25), 0.5), "number: midpoint lerp")
    expect(BAEval.number(linear, 0) == 0, "number: at start")
    expect(BAEval.number(linear, 1) == 2, "number: at end")
    expect(BAEval.number(linear, 2) == 2, "number: clamps high")
    expect(BAEval.number(linear, -1) == 0, "number: clamps low")

    let smooth: [[Float]] = [[0, 0], [1, 10]]
    // smoothstep(0.25) = 3t^2-2t^3 = 0.15625 -> lerp(0,10,0.15625) = 1.5625
    expect(approx(BAEval.smoothNumber(smooth, 0.25), 1.5625), "smoothNumber: smoothstep")

    let hermite: [[Float]] = [[0, 0, 0, 0], [1, 10, 0, 0]]
    expect(approx(BAEval.hermite(hermite, 0.5), 5), "hermite: zero-slope midpoint")

    let color: [[Float]] = [[0, 255, 255, 255], [1, 0, 0, 0]]
    let c = BAEval.color(color, 0.5)
    expect(approx(c.x, 127.5) && approx(c.y, 127.5) && approx(c.z, 127.5), "color: midpoint lerp")
}

// MARK: - ParticleSystem simulation

func testParticleSystem() {
    let ps = ParticleSystem()
    ps.setViewportHeight(1080) // scale = 1

    expect(!ps.hasActiveParticles(), "empty system inactive")

    ps.addClick(at: SIMD2(100, 100))
    expect(ps.bursts.isEmpty, "click not processed until update")
    ps.update(now: 1000.0) // now is in seconds (CACurrentMediaTime style)
    expect(ps.bursts.count == 1, "click processed on update")
    expect(ps.bursts[0].ageMs == 0, "burst starts at age 0")
    expect(ps.shards.count == BAEffect.shards.clickCount, "click spawns shards")
    expect(ps.hasActiveParticles(), "system active after click")

    ps.update(now: 1000.016)
    let age = ps.bursts[0].ageMs
    expect(age >= 15.9 && age <= 16.1, "burst advances ~16ms per frame")

    // Bursts must be removed after rings lifetime (600ms); feed small steps so
    // the 33ms clamp is never hit (matches real 60fps behavior).
    for i in 2...40 {
        ps.update(now: 1000.0 + Double(i) * 0.016)
    }
    expect(ps.bursts.isEmpty, "bursts removed after rings lifetime")

    // Trail min-distance dedup (deterministic; no clock dependency).
    let ps2 = ParticleSystem()
    ps2.setViewportHeight(1080)
    ps2.addTrailPoint(at: SIMD2(0, 0))
    ps2.addTrailPoint(at: SIMD2(0, 0))
    expect(ps2.trail.count == 1, "identical trail points deduped")
    ps2.addTrailPoint(at: SIMD2(0, 100))
    expect(ps2.trail.count == 2, "distant trail point added")

    // clear() drops bursts, shards and trail immediately.
    let ps3 = ParticleSystem()
    ps3.setViewportHeight(1080)
    ps3.addClick(at: SIMD2(50, 50))
    ps3.addTrailPoint(at: SIMD2(10, 10))
    ps3.addTrailPoint(at: SIMD2(20, 10))
    ps3.update(now: 1000)
    expect(ps3.hasActiveParticles(), "system active before clear")
    ps3.clear()
    expect(ps3.bursts.isEmpty && ps3.shards.isEmpty && ps3.trail.isEmpty, "clear empties everything")
    expect(!ps3.hasActiveParticles(), "inactive after clear")
}

// MARK: - SettingsStore

func testSettingsStore() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("baclick-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let oldCwd = FileManager.default.currentDirectoryPath
    defer {
        FileManager.default.changeCurrentDirectoryPath(oldCwd)
        try? FileManager.default.removeItem(at: tmp)
    }
    FileManager.default.changeCurrentDirectoryPath(tmp.path)

    let store = SettingsStore()

    // binding writes through to the model.
    store.binding(\.trailScale).wrappedValue = 5.5
    expect(store.model.trailScale == 5.5, "binding updates model")

    // clickScaleBinding writes disk/ring/shard together.
    store.clickScaleBinding().wrappedValue = 1.25
    expect(store.model.diskScale == 1.25, "clickScale sets diskScale")
    expect(store.model.ringScale == 1.25, "clickScale sets ringScale")
    expect(store.model.shardScale == 1.25, "clickScale sets shardScale")

    // persist writes JSON to the cwd settings.json (persistURL picks it).
    try? "{}".write(to: tmp.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    store.persist()
    guard let data = try? Data(contentsOf: tmp.appendingPathComponent("settings.json")),
          let roundtrip = try? JSONDecoder().decode(FXSettings.self, from: data) else {
        expect(false, "persist wrote readable JSON")
        return
    }
    expect(roundtrip.trailScale == 5.5, "persisted trailScale round-trips")
}

// MARK: - L10n

func testL10n() {
    expect(L10n.strings.isEmpty == false, "L10n has strings")
    for (key, pair) in L10n.strings {
        expect(!pair.zh.isEmpty, "L10n zh non-empty: \(key)")
        expect(!pair.en.isEmpty, "L10n en non-empty: \(key)")
    }
    expect(!L10n.t("quit").isEmpty, "L10n.t returns non-empty")
    // The two variants must actually differ (real translation, not a no-op).
    for (key, pair) in L10n.strings where key != "panelTitle" {
        expect(pair.zh != pair.en, "L10n zh/en differ: \(key)")
    }
}

// MARK: - UpdateManager version parsing (pure functions)

func testVersionCompare() {
    expect(UpdateManager.normalizeVersion("v1.2.3") == [1, 2, 3], "normalize: strips leading v")
    expect(UpdateManager.normalizeVersion("1.2.3") == [1, 2, 3], "normalize: plain version")
    expect(UpdateManager.normalizeVersion("v0.1.1") == [0, 1, 1], "normalize: 0.x version")
    expect(UpdateManager.normalizeVersion("  V2.0 ") == [2, 0], "normalize: trims + uppercase V")

    expect(UpdateManager.compare([1, 0, 0], [1, 0, 0]) == 0, "compare: equal")
    expect(UpdateManager.compare([1, 0, 0], [1, 0, 1]) == -1, "compare: older")
    expect(UpdateManager.compare([2, 0, 0], [1, 9, 9]) == 1, "compare: newer")
    expect(UpdateManager.compare([1, 2], [1, 2, 0]) == 0, "compare: missing components are zero")
    expect(UpdateManager.compare([1, 2], [1, 2, 1]) == -1, "compare: shorter is older")

    // Pre-release suffixes (semver-ish): newer core wins, own release wins.
    expect(UpdateManager.compare("0.2.2-beta1", "0.2.1") == 1, "compare: beta above older release")
    expect(UpdateManager.compare("0.2.2-beta1", "0.2.2") == -1, "compare: beta below its own release")
    expect(UpdateManager.compare("0.2.2", "0.2.2-beta1") == 1, "compare: release above its beta")
    expect(UpdateManager.compare("1.0.0-alpha", "1.0.0-alpha") == 0, "compare: identical betas equal")
    expect(UpdateManager.compare("v0.2.1", "0.2.2-beta1") == -1, "compare: tag with v-prefix handled")
    expect(UpdateManager.normalizeVersion("0.2.2-beta1") == [0, 2, 2], "normalize: core keeps suffix-segment")
}

// MARK: - GitHub proxy URL construction (pure)

func testProxyURLs() {
    for prefix in GitHubProxy.api {
        expect(
            URL(string: prefix + AppInfo.latestReleaseAPI.absoluteString) != nil,
            "proxy API URL builds: \(prefix)"
        )
        expect(prefix.hasSuffix("/"), "proxy API prefix ends with /: \(prefix)")
    }
    for prefix in GitHubProxy.download {
        expect(
            URL(string: prefix + "https://github.com/x/y/releases/download/v1/a.dmg") != nil,
            "proxy download URL builds: \(prefix)"
        )
        expect(prefix.hasSuffix("/"), "proxy download prefix ends with /: \(prefix)")
    }
}

// MARK: - Update helper script safety invariants (pure)

/// The helper script replaces the running app, so its safety behavior is
/// release-critical: pin the invariants here (it runs detached after the app
/// quits, where nothing else guards it).
func testUpdateHelperScript() {
    let script = UpdateManager.helperScriptText()

    expect(script.hasPrefix("#!/bin/bash"), "helper: shebang")

    // Signature gate: only replace the app with a build signed by the same
    // certificate (designated requirement = identifier + pinned cert hash).
    expect(script.contains("designated => "), "helper: extracts running app's requirement")
    expect(script.contains("codesign --verify --strict -R="), "helper: verifies new app against requirement")
    expect(script.contains("-z \"$REQ\""), "helper: refuses when no requirement can be extracted")

    // Atomic swap with rollback: stage a copy first, rename-swap, restore the
    // old app if the swap fails. The old delete-then-copy must stay gone.
    expect(script.contains(".ba-click-update-stage"), "helper: stages the new app beside the old one")
    expect(script.contains(".ba-click-update-old"), "helper: keeps the old app until the swap succeeds")
    expect(script.contains("mv \"$OLD\" \"$CURRENT_APP\""), "helper: rolls back on failed swap")
    expect(!script.contains("rm -rf \"$CURRENT_APP\""), "helper: never deletes the running app up front")

    // Args are positional; $1..$7 must stay in sync with spawnDetached.
    expect(script.contains("APP_PID=\"$1\""), "helper: reads pid argument")
    expect(script.contains("SELF=\"$7\""), "helper: reads self-path argument")
}

// MARK: - ScreenGeometry routing (multi-display)

func testScreenGeometryRouting() {
    // Two 1920x1080 displays side by side; the left one is "main" (origin 0),
    // so the right display's global frame starts at x=1920.
    let left = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
    let frames = [left, right]

    expect(ScreenGeometry.frameIndex(for: NSPoint(x: 100, y: 100), in: frames) == 0, "routing: point on left display")
    expect(ScreenGeometry.frameIndex(for: NSPoint(x: 2000, y: 500), in: frames) == 1, "routing: point on right display")
    // Edges are inclusive, so a point exactly on a shared edge belongs to
    // the first containing frame — imperceptible either way.
    expect(ScreenGeometry.frameIndex(for: NSPoint(x: 1920, y: 0), in: frames) == 0, "routing: shared edge belongs to the first containing frame")
    // No frame contains the point -> nearest display wins.
    expect(ScreenGeometry.frameIndex(for: NSPoint(x: 3900, y: 500), in: frames) == 1, "routing: nearest display on miss (right)")
    expect(ScreenGeometry.frameIndex(for: NSPoint(x: -50, y: 500), in: frames) == 0, "routing: nearest display on miss (left)")
    expect(ScreenGeometry.frameIndex(for: NSPoint(x: 1, y: 1), in: []) == nil, "routing: no screens at all")

    // Local conversion subtracts the display origin — under the old
    // single-overlay math, secondary-display clicks stayed offset by the
    // main screen's frame.
    let local = ScreenGeometry.shared.convert(NSPoint(x: 2000, y: 500), in: right)
    expect(local.x == 80 && local.y == 500, "routing: local point subtracts the display origin")
}

// MARK: - SingleInstance lock (filesystem)

func testSingleInstanceLock() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("baclick-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let lock = dir.appendingPathComponent("instance.lock")

    expect(SingleInstance.acquire(lockURL: lock), "first acquire wins the lock")
    expect(!SingleInstance.acquire(lockURL: lock), "second acquire on the same lock is refused")
    expect(
        SingleInstance.acquire(lockURL: dir.appendingPathComponent("other.lock")),
        "a different lock file is independent"
    )
}

// MARK: - Up-to-date label formatting (pure)

func testUpToDateLabel() {
    let label = L10n.upToDateLabel(latestVersion: "0.2.0", currentVersion: "0.2.1")
    expect(label.contains("v0.2.0"), "up-to-date label contains the latest version")
    expect(!label.contains("vv"), "up-to-date label has exactly one 'v' prefix")
    // Falls back to the running version when the API returned none.
    expect(
        L10n.upToDateLabel(latestVersion: nil, currentVersion: "9.9.9").contains("v9.9.9"),
        "up-to-date label falls back to the running version"
    )
}

// MARK: - Automatic update check throttling (pure)

func testAutoCheckThrottle() {
    let now = Date()
    expect(UpdateManager.isAutoCheckDue(lastCheck: nil, now: now), "auto check: first check always due")
    expect(
        !UpdateManager.isAutoCheckDue(lastCheck: now.addingTimeInterval(-10), now: now),
        "auto check: throttled within the window"
    )
    expect(
        UpdateManager.isAutoCheckDue(lastCheck: now.addingTimeInterval(-61), now: now),
        "auto check: due again after the window"
    )
    // A custom (shorter) throttle must be honored.
    expect(
        UpdateManager.isAutoCheckDue(lastCheck: now.addingTimeInterval(-10), now: now, throttle: 5),
        "auto check: honors a custom throttle"
    )
}

// MARK: - Update check (live network; opt-in via BA_TEST_NETWORK=1)

/// Exercises the real GitHub latest-release API + proxy fallback. Skipped
/// unless BA_TEST_NETWORK is set (unauthenticated API is rate-limited to 60/hr).
func testUpdateCheckLive() {
    guard getenv("BA_TEST_NETWORK") != nil else { return }

    // Full checkForUpdates() flow: direct, then proxies.
    let manager = UpdateManager()
    manager.checkForUpdates()
    let deadline = Date().addingTimeInterval(20)
    while manager.state == .checking && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    expect(
        manager.state == .upToDate || manager.state == .updateAvailable,
        "live update check resolves (state=\(manager.state))"
    )

    // Live-verify the primary proxy forwards the latest-release API JSON.
    guard let proxyURL = URL(string: GitHubProxy.api[0] + AppInfo.latestReleaseAPI.absoluteString) else { return }
    var request = URLRequest(url: proxyURL)
    request.timeoutInterval = 15
    let semaphore = DispatchSemaphore(value: 0)
    var proxyOK = false
    URLSession.shared.dataTask(with: request) { data, _, _ in
        if let data,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["tag_name"] as? String != nil {
            proxyOK = true
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 20)
    expect(proxyOK, "gh-proxy.org forwards the latest-release API")
}

// MARK: - FXSettings defaults + loading

func testFXSettings() {
    let defaults = FXSettings()
    expect(defaults.trailScale == 2.2, "default trailScale = 2.2 (tuned best)")
    expect(defaults.diskScale == 0.8, "default diskScale = 0.8")
    expect(defaults.clickBloomStrength == 0.1, "default clickBloomStrength = 0.1")
    expect(defaults.trailBloomStrength == 3.5, "default trailBloomStrength = 3.5")
    expect(defaults.showInFullscreen == true, "default showInFullscreen = true")
    expect(defaults.enabled == true, "default enabled = true")
    expect(defaults.trailAlwaysVisible == true, "default trailAlwaysVisible = true")
    expect(defaults.rightClickEnabled == true, "default rightClickEnabled = true")
    expect(defaults.middleClickEnabled == true, "default middleClickEnabled = true")
    expect(defaults.powerConnectedOnly == false, "default powerConnectedOnly = false (effects on battery)")
    expect(defaults.autoUpdateCheck == true, "default autoUpdateCheck = true")
    expect(defaults.clickBrightness == 1.0, "default clickBrightness = 1.0")
    expect(defaults.clickDiskOpacity == 1.0, "default clickDiskOpacity = 1.0")
    expect(defaults.triangleOpacity == 1.0, "default triangleOpacity = 1.0")
    expect(defaults.refreshRate == 60, "default refreshRate = 60")

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("baclick-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let oldCwd = FileManager.default.currentDirectoryPath
    defer {
        FileManager.default.changeCurrentDirectoryPath(oldCwd)
        try? FileManager.default.removeItem(at: tmp)
    }
    FileManager.default.changeCurrentDirectoryPath(tmp.path)
    let settingsURL = tmp.appendingPathComponent("settings.json")

    // Valid settings override defaults; unset keys keep defaults.
    try? "{\"trailScale\": 9.9, \"diskScale\": 0.5}".write(to: settingsURL, atomically: true, encoding: .utf8)
    let loaded = FXSettings.load()
    expect(loaded.trailScale == 9.9, "valid settings override trailScale")
    expect(loaded.diskScale == 0.5, "valid settings override diskScale")
    expect(loaded.bloomStrength == 1.7, "unset keys keep defaults")

    // Unknown keys are tolerated (ignored) without breaking decode.
    try? "{\"trailScale\": 3.0, \"bloomStrength\": 2.0, \"bogusKey\": 123}".write(to: settingsURL, atomically: true, encoding: .utf8)
    let loaded2 = FXSettings.load()
    expect(loaded2.trailScale == 3.0, "unknown keys tolerated")
    expect(loaded2.bloomStrength == 2.0, "known keys still decode with unknown present")

    // Invalid JSON falls back to defaults.
    try? "{not json".write(to: settingsURL, atomically: true, encoding: .utf8)
    let loaded3 = FXSettings.load()
    expect(loaded3.trailScale == 2.2, "invalid JSON falls back to defaults")

    // 0.2.1 toggles decode from a minimal file and round-trip through encode.
    let fragment = Data(#"{"powerConnectedOnly": true, "autoUpdateCheck": false}"#.utf8)
    let decoded = try! JSONDecoder().decode(FXSettings.self, from: fragment)
    expect(decoded.powerConnectedOnly == true, "powerConnectedOnly decodes")
    expect(decoded.autoUpdateCheck == false, "autoUpdateCheck decodes")
    expect(decoded.enabled == true, "absent toggles keep defaults")
    let roundtrip = try! JSONDecoder().decode(
        FXSettings.self,
        from: try! JSONEncoder().encode(decoded)
    )
    expect(
        roundtrip.powerConnectedOnly == true && roundtrip.autoUpdateCheck == false,
        "new toggles round-trip through encode/decode"
    )

    // persistURL prefers an existing cwd settings.json. (Build the expected URL
    // the same way persistURL does — the cwd is /private/var/... while the
    // temp dir URL is /var/..., so a direct string comparison would differ.)
    try? "{}".write(to: settingsURL, atomically: true, encoding: .utf8)
    let expectedCwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("settings.json")
    expect(FXSettings.persistURL() == expectedCwdURL, "persistURL prefers existing cwd file")
}

testBAEval()
testParticleSystem()
testFXSettings()
testL10n()
testSettingsStore()
testVersionCompare()
testProxyURLs()
testScreenGeometryRouting()
testSingleInstanceLock()
testUpToDateLabel()
testAutoCheckThrottle()
testUpdateHelperScript()
testUpdateCheckLive()

print("passed: \(passed), failed: \(failures)")
if failures > 0 {
    exit(1)
}
