package com.zanghi.phonecam

/**
 * Which paired Mac gets the camera. Several Macs can ask (an app on each uses Phone Camera); the first to ask keeps it
 * until it lets go, then it passes to the Mac that has been waiting longest. The user can hand it over explicitly.
 */
class CameraArbiter {
    private val waiting = LinkedHashSet<String>()
    var owner: String? = null
        private set

    val queue: List<String> get() = waiting.toList()

    /** [macId] wants video. Returns true if it owns the camera now. */
    fun request(macId: String): Boolean {
        if (owner == null) owner = macId
        if (owner != macId) waiting.add(macId)
        return owner == macId
    }

    /** [macId] no longer wants video (went idle, paused, disconnected or was forgotten). Returns the new owner if it changed. */
    fun release(macId: String): String? {
        waiting.remove(macId)
        if (owner != macId) return null
        owner = waiting.firstOrNull()?.also { waiting.remove(it) }
        return owner
    }

    /** The user moves the camera to a waiting Mac; the previous owner waits at the front of the queue. */
    fun takeOver(macId: String): Boolean {
        if (macId !in waiting) return false
        waiting.remove(macId)
        val previous = owner
        owner = macId
        if (previous != null) {
            val rest = waiting.toList()
            waiting.clear()
            waiting.add(previous)
            waiting.addAll(rest)
        }
        return true
    }

    fun isWaiting(macId: String) = macId in waiting

    fun clear() {
        waiting.clear()
        owner = null
    }
}
