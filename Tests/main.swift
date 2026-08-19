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
}

// MARK: - FXSettings defaults + loading

func testFXSettings() {
    let defaults = FXSettings()
    expect(defaults.trailScale == 2.2, "default trailScale = 2.2 (tuned best)")
    expect(defaults.diskScale == 0.8, "default diskScale = 0.8")
    expect(defaults.clickBloomStrength == 0.1, "default clickBloomStrength = 0.1")
    expect(defaults.trailBloomStrength == 3.5, "default trailBloomStrength = 3.5")
    expect(defaults.showInFullscreen == true, "default showInFullscreen = true")

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
}

testBAEval()
testParticleSystem()
testFXSettings()

print("passed: \(passed), failed: \(failures)")
if failures > 0 {
    exit(1)
}
