package com.zanghi.phonecam

/**
 * Chooses 1080p or 720p (never lower) from the sender's bandwidth estimate and the phone's thermal state.
 * Pure so it can be unit-tested; the controller feeds it a sample every 2 s.
 */
class QualityPolicy {
    data class Decision(val height: Int, val limited: String?)

    private var height = 1080
    private var networkLimited = false
    private var lowSamples = 0
    private var backoffMs = INITIAL_BACKOFF_MS
    private var retryAt = 0L
    private var upgradedAt = 0L
    var decision = Decision(1080, null)
        private set

    /** [bitrateBps] is availableOutgoingBitrate (null if unknown); [thermal] is PowerManager.THERMAL_STATUS_*. */
    fun sample(bitrateBps: Double?, thermal: Int, nowMs: Long): Decision {
        if (height == 1080) {
            lowSamples = if (bitrateBps != null && bitrateBps < LOW_BPS) lowSamples + 1 else 0
            if (lowSamples >= LOW_SAMPLES) {
                // Fell back soon after an upgrade: wait longer before the next try.
                if (upgradedAt > 0 && nowMs - upgradedAt < QUICK_FALLBACK_MS) backoffMs = minOf(backoffMs * 2, MAX_BACKOFF_MS)
                height = 720
                networkLimited = true
                lowSamples = 0
                retryAt = nowMs + backoffMs
            } else if (upgradedAt > 0 && nowMs - upgradedAt > STABLE_MS) {
                backoffMs = INITIAL_BACKOFF_MS
                upgradedAt = 0
            }
        } else if (networkLimited && nowMs >= retryAt) {
            height = 1080
            networkLimited = false
            upgradedAt = nowMs
        }
        return evaluate(thermal)
    }

    /** Re-evaluate after a thermal change without counting a bandwidth sample. */
    fun evaluate(thermal: Int): Decision {
        decision = when {
            thermal >= THERMAL_MODERATE -> Decision(720, "thermal")
            networkLimited -> Decision(720, "network")
            else -> Decision(1080, null)
        }
        return decision
    }

    fun reset() {
        height = 1080; networkLimited = false; lowSamples = 0; backoffMs = INITIAL_BACKOFF_MS; upgradedAt = 0
        decision = Decision(1080, null)
    }

    companion object {
        const val LOW_BPS = 3_000_000.0
        const val LOW_SAMPLES = 3
        const val INITIAL_BACKOFF_MS = 30_000L
        const val MAX_BACKOFF_MS = 300_000L
        const val QUICK_FALLBACK_MS = 20_000L
        const val STABLE_MS = 300_000L
        // Mirrors PowerManager.THERMAL_STATUS_MODERATE / SEVERE without needing Android in unit tests.
        const val THERMAL_MODERATE = 2
        const val THERMAL_SEVERE = 3
    }
}
