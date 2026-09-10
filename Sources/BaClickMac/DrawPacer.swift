/// Adaptive draw pacing for the render loop. Sampling (recording the cursor
/// position) is cheap and must never be starved — under GPU contention it is
/// the expensive draw() calls that slow the tick loop down, and a slowed loop
/// records the cursor less often, so the trail head visibly lags behind it.
///
/// When measured ticks run sustainedly over budget this pacer repaints every
/// second tick while sampling stays full-rate; when degraded pacing fits
/// comfortably for a few draws it restores full rate. Different enter/exit
/// thresholds plus an EMA reset on recovery keep it from oscillating at the
/// boundary.
struct DrawPacer {
    private(set) var degraded = false
    private(set) var ema: Double = 0
    private var lastTickTime: Double = 0
    private var lastDrawTime: Double = 0
    private var recentDrawDeltas: [Double] = []
    private var drawOnNextTick = true

    /// Tick EMA over this multiple of the budget means sustained contention.
    static let degradeFactor = 1.5
    /// Degraded pacing is healthy at ~2×budget (one skipped tick per draw);
    /// draw-to-draw deltas must fit under this multiple to restore full rate.
    static let recoverFactor = 2.2
    /// A tick gap this large is a loop restart (idle stop / sleep), not
    /// contention.
    static let resetGap: Double = 0.5
    static let emaAlpha = 0.25
    static let recoverSamples = 3

    /// Feed one tick observed at `now`; returns whether the expensive draws
    /// should run this tick. Sampling happens regardless of the answer.
    mutating func shouldDraw(at now: Double, budget: Double) -> Bool {
        var drawNow = true
        if lastTickTime > 0 {
            let delta = now - lastTickTime
            if delta >= Self.resetGap {
                ema = budget
            } else {
                ema = ema == 0 ? delta : ema * (1 - Self.emaAlpha) + delta * Self.emaAlpha
            }
            if !degraded, ema > budget * Self.degradeFactor {
                degraded = true
                recentDrawDeltas.removeAll()
                drawOnNextTick = true
            }
        }
        lastTickTime = now

        if degraded {
            drawNow = drawOnNextTick
            drawOnNextTick.toggle()
            if drawNow {
                if lastDrawTime > 0 {
                    let drawDelta = now - lastDrawTime
                    if drawDelta < Self.resetGap {
                        recentDrawDeltas.append(drawDelta)
                        if recentDrawDeltas.count > Self.recoverSamples {
                            recentDrawDeltas.removeFirst()
                        }
                        if recentDrawDeltas.count == Self.recoverSamples,
                           recentDrawDeltas.allSatisfy({ $0 <= budget * Self.recoverFactor }) {
                            degraded = false
                            ema = budget
                            recentDrawDeltas.removeAll()
                        }
                    }
                }
                lastDrawTime = now
            }
        }
        return drawNow
    }

    /// The refresh rate (budget) changed: the EMA describes the old pace.
    mutating func reset(budget: Double) {
        ema = budget
    }
}
