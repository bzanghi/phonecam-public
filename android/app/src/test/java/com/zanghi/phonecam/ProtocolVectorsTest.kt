package com.zanghi.phonecam

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Cross-language vectors in docs/protocol-vectors.json; the Mac tests read the same file. */
class ProtocolVectorsTest {
    private val v: JSONObject by lazy {
        var dir: File? = File("").absoluteFile
        while (dir != null && !File(dir, "docs/protocol-vectors.json").exists()) dir = dir.parentFile
        JSONObject(File(dir ?: error("docs/protocol-vectors.json not found"), "docs/protocol-vectors.json").readText())
    }
    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test fun protocolVersion() = assertEquals(PROTOCOL_VERSION, v.getInt("protocolVersion"))

    @Test fun pairingUrl() {
        val p = v.getJSONObject("pairing")
        val parsed = PairingPayload.parse(p.getString("url"))!!
        assertEquals(p.getString("macId"), parsed.macId)
        assertEquals(p.getString("macName"), parsed.macName)
        assertEquals((0 until p.getJSONArray("hosts").length()).map { p.getJSONArray("hosts").getString(it) }, parsed.hosts)
        assertEquals(p.getInt("port"), parsed.port)
        assertArrayEquals(hex(p.getString("tokenHex")), parsed.token)
        val rejected = v.getJSONArray("rejectedPairingUrls")
        for (i in 0 until rejected.length()) assertNull(rejected.getString(i), PairingPayload.parse(rejected.getString(i)))
    }

    @Test fun sealedEnvelopes() {
        val a = v.getJSONArray("sealed")
        for (i in 0 until a.length()) {
            val s = a.getJSONObject(i)
            val mac = PairingCrypto.hmac(hex(s.getString("keyHex")), "${s.getString("dir")}|${s.getInt("seq")}|${s.getString("body")}")
            assertEquals(s.getString("macB64url"), PairingCrypto.b64url(mac))
        }
    }

    @Test fun authMessages() {
        val a = v.getJSONObject("auth")
        val pn = hex(a.getString("phoneNonceHex")); val mn = hex(a.getString("macNonceHex"))
        assertEquals(a.getString("phone"), PairingCrypto.authMessage("phone", a.getString("deviceId"), pn, mn))
        assertEquals(a.getString("mac"), PairingCrypto.authMessage("mac", a.getString("deviceId"), pn, mn))
    }

    @Test fun bodies() {
        val b = v.getJSONArray("bodies")
        val byName = (0 until b.length()).associate { b.getJSONObject(it).getString("name") to JSONObject(b.getJSONObject(it).getString("json")) }
        assertEquals("idle", byName.getValue("control-idle").getString("action"))
        val start = byName.getValue("control-start-mic")
        assertEquals("start", start.getString("action")); assertTrue(start.getBoolean("mic"))
        val state = byName.getValue("state")
        assertEquals(80, state.getInt("battery")); assertEquals("moderate", state.getString("thermal")); assertEquals("network", state.getString("limited")); assertTrue(state.getBoolean("mic"))
        assertEquals("bye", byName.getValue("bye").getString("t"))
        assertEquals("Pixel 7", byName.getValue("replaced").getString("note"))
        // What the phone builds for the same state must carry the same fields and values.
        val built = json("t" to "state", "width" to 1920, "height" to 1080, "battery" to 80, "thermal" to "moderate", "limited" to "network", "mic" to true)
        assertEquals(state.toMap(), built.toMap())
    }
}
