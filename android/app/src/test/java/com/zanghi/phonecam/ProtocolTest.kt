package com.zanghi.phonecam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    private val token = PairingCrypto.b64url(ByteArray(16) { it.toByte() })
    private fun url(h: String = "192.168.1.20", p: String = "47800", k: String = token, n: String = "Mac") =
        "phonecam://pair?v=1&id=abc&n=$n&h=$h&p=$p&k=$k"

    @Test fun parsesValidPayload() {
        val p = PairingPayload.parse(url(h = "192.168.1.20,10.1.2.3,172.20.0.1"))!!
        assertEquals("abc", p.macId)
        assertEquals(listOf("192.168.1.20", "10.1.2.3", "172.20.0.1"), p.hosts)
        assertEquals(47800, p.port)
        assertEquals(16, p.token.size)
    }

    @Test fun rejectsPublicAndNonLiteralHosts() {
        assertNull(PairingPayload.parse(url(h = "8.8.8.8")))
        assertNull(PairingPayload.parse(url(h = "192.168.1.2,8.8.8.8")))   // every host must be private
        assertNull(PairingPayload.parse(url(h = "attacker.example.com")))
        assertNull(PairingPayload.parse(url(h = "172.32.0.1")))
        assertNull(PairingPayload.parse(url(h = "")))
    }

    @Test fun rejectsBadPortAndToken() {
        assertNull(PairingPayload.parse(url(p = "0")))
        assertNull(PairingPayload.parse(url(p = "65536")))
        assertNull(PairingPayload.parse(url(p = "x")))
        assertNull(PairingPayload.parse(url(k = PairingCrypto.b64url(ByteArray(8)))))
        assertNull(PairingPayload.parse(url(k = "!!!")))
        assertNull(PairingPayload.parse("https://pair?v=1"))
    }

    @Test fun cleansMacName() {
        val long = "A".repeat(200)
        assertEquals(64, PairingPayload.parse(url(n = long))!!.macName.length)
        assertEquals("BadName", PairingPayload.parse(url(n = "Bad%0AName"))!!.macName)
        assertEquals("Mac", PairingPayload.parse(url(n = "%0A%0D"))!!.macName)
    }

    @Test fun lanAddress() {
        listOf("10.0.0.1", "172.16.5.5", "172.31.255.255", "192.168.0.1").forEach { assertTrue(it, LanAddress.isPrivateIPv4(it)) }
        listOf("8.8.8.8", "172.15.0.1", "172.32.0.1", "169.254.1.1", "192.169.0.1", "1.2.3", "300.1.1.1", "a.b.c.d").forEach {
            assertFalse(it, LanAddress.isPrivateIPv4(it))
        }
        assertTrue(LanAddress.isLocal("169.254.3.4"))
        assertTrue(LanAddress.isLocal("fe80::1"))
        assertTrue(LanAddress.isLocal("fd12:3456::1"))
        assertTrue(LanAddress.isLocal("1f2e3d4c-aaaa.local"))
        assertFalse(LanAddress.isLocal("2001:db8::1"))
        assertFalse(LanAddress.isLocal("203.0.113.5"))
    }

    @Test fun filtersCandidatesAndSdp() {
        val lan = "candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host generation 0"
        val wan = "candidate:2 1 udp 1686052607 203.0.113.5 54321 typ srflx raddr 0.0.0.0 rport 0"
        val v6 = "candidate:3 1 udp 2122262783 2001:db8::5 50000 typ host"
        assertTrue(LanAddress.isLocalCandidate(lan))
        assertTrue(LanAddress.isLocalCandidate("a=$lan"))
        assertFalse(LanAddress.isLocalCandidate(wan))
        assertFalse(LanAddress.isLocalCandidate(v6))
        assertFalse(LanAddress.isLocalCandidate("garbage"))
        val sdp = listOf("v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=$lan", "a=$wan", "a=$v6", "a=mid:0").joinToString("\r\n")
        assertEquals(listOf("v=0", "m=video 9 UDP/TLS/RTP/SAVPF 96", "a=$lan", "a=mid:0").joinToString("\r\n"), LanAddress.filterSdp(sdp))
    }

    @Test fun pairingStillNotNullForMinimalName() {
        assertNotNull(PairingPayload.parse("phonecam://pair?v=1&id=abc&h=10.0.0.2&p=1&k=$token"))
    }
}
