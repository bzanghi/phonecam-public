package com.zanghi.phonecam

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same vectors as mac/.../PairingTests.swift testCrossPlatformVectors (also checked against Python's hmac/hashlib). */
class PairingCryptoTest {
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    @Test fun pairingKeyMatchesMac() {
        val kp = PairingCrypto.pairingKey(ByteArray(16) { it.toByte() })
        assertEquals("5ecefb528d85c078ec68c5b8d6c518d8953c72b9c82519020383677e45b666e4", kp.hex())
        val proof = PairingCrypto.hmac(kp, PairingCrypto.pairProofMessage("dev-1", ByteArray(16) { 0xAB.toByte() }))
        assertEquals("ed13386e1d66c9d0e5f945074e52d6b06f60ea8a8c5ded0a2ae3e321fe4db9c4", proof.hex())
    }

    @Test fun sessionKeyMatchesMac() {
        val ks = PairingCrypto.sessionKey(ByteArray(32) { 0x11 }, ByteArray(16) { 1 }, ByteArray(16) { 2 })
        assertEquals("743cf5d52e379b3fcbc088bf91ffd5aa37f94b24225fe3ad1a53bac11b0cbf25", ks.hex())
    }

    @Test fun aesGcmMatchesCryptoKit() {
        val kp = PairingCrypto.pairingKey(ByteArray(16) { it.toByte() })
        val sealed = PairingCrypto.seal(kp, ByteArray(12) { 3 }, ByteArray(32) { 0x22 }, "dev-1")
        assertEquals("c532d3465c7f3ae2c4730d4a20374ab7af0ee0b70fc872c713d6aadf379d5d3e01798e4f21fe28c1e9b23fe48f04450d", sealed.hex())
        assertArrayEquals(ByteArray(32) { 0x22 }, PairingCrypto.open(kp, ByteArray(12) { 3 }, sealed, "dev-1"))
    }

    @Test fun base64UrlRoundTrip() {
        val data = PairingCrypto.randomBytes(33)
        assertArrayEquals(data, PairingCrypto.fromB64url(PairingCrypto.b64url(data)))
        assertTrue(!PairingCrypto.b64url(data).contains('='))
    }
}
