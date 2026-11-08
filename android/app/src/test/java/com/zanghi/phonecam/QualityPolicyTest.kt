package com.zanghi.phonecam

import org.junit.Assert.assertEquals
import org.junit.Test

class QualityPolicyTest {
    private val ok = 5_000_000.0
    private val low = 2_000_000.0
    private val none = QualityPolicy.THERMAL_MODERATE - 2

    @Test fun stepsDownAfterThreeLowSamplesAndNeverBelow720() {
        val q = QualityPolicy()
        assertEquals(1080, q.sample(low, none, 0).height)
        assertEquals(1080, q.sample(low, none, 2_000).height)
        val d = q.sample(low, none, 4_000)
        assertEquals(QualityPolicy.Decision(720, "network"), d)
        assertEquals(720, q.sample(100_000.0, none, 6_000).height)
    }

    @Test fun ignoresSingleDipsAndUnknownSamples() {
        val q = QualityPolicy()
        q.sample(low, none, 0); q.sample(low, none, 2_000); q.sample(ok, none, 4_000); q.sample(null, none, 6_000)
        assertEquals(1080, q.sample(low, none, 8_000).height)
    }

    @Test fun retriesWithDoublingBackoff() {
        val q = QualityPolicy()
        var t = 0L
        fun drop() { repeat(3) { q.sample(low, none, t); t += 2_000 } }
        drop()                                                   // 720 at t=4s, retry at 34s
        assertEquals(720, q.sample(ok, none, 30_000).height)
        assertEquals(1080, q.sample(ok, none, 34_000).height)    // upgrade
        t = 36_000; drop()                                       // fell back within 20 s: backoff 60 s
        val fellAt = t - 2_000
        assertEquals(720, q.sample(ok, none, fellAt + 59_000).height)
        assertEquals(1080, q.sample(ok, none, fellAt + 60_000).height)
    }

    @Test fun backoffResetsAfterStableRun() {
        val q = QualityPolicy()
        var t = 0L
        fun drop() { repeat(3) { q.sample(low, none, t); t += 2_000 } }
        drop(); q.sample(ok, none, 34_000)                       // upgrade at 34 s
        t = 36_000; drop()                                       // quick fallback → 60 s
        val up = t - 2_000 + 60_000
        q.sample(ok, none, up)                                   // upgrade
        q.sample(ok, none, up + 301_000)                         // stable 5 min → reset to 30 s
        t = up + 303_000; drop()
        val fellAt = t - 2_000
        assertEquals(1080, q.sample(ok, none, fellAt + 30_000).height)
    }

    @Test fun thermalForces720AndWins() {
        val q = QualityPolicy()
        assertEquals(QualityPolicy.Decision(720, "thermal"), q.evaluate(QualityPolicy.THERMAL_MODERATE))
        assertEquals(QualityPolicy.Decision(720, "thermal"), q.sample(ok, QualityPolicy.THERMAL_SEVERE, 0))
        assertEquals(QualityPolicy.Decision(1080, null), q.evaluate(none))
    }
}
