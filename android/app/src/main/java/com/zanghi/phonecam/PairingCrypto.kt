package com.zanghi.phonecam

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Mirrors mac/Packages/PhoneCamCore/Sources/PhoneCamCore/PairingCrypto.swift. Test vectors must match.
 *  Kp = HKDF-SHA256(token, salt "phonecam-v1", info "pair"); Ks = HKDF-SHA256(S, nonceP||nonceM, "session").
 */
object PairingCrypto {
    private val SALT = "phonecam-v1".toByteArray()
    private val random = SecureRandom()

    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            t = hmac(prk, t + info + byteArrayOf(counter.toByte()))
            val n = minOf(t.size, length - pos)
            System.arraycopy(t, 0, out, pos, n)
            pos += n
            counter++
        }
        return out
    }

    fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun hmac(key: ByteArray, message: String): ByteArray = hmac(key, message.toByteArray(Charsets.UTF_8))

    fun verify(key: ByteArray, message: String, mac: ByteArray): Boolean =
        MessageDigest.isEqual(hmac(key, message), mac)

    fun pairingKey(token: ByteArray) = hkdf(token, SALT, "pair".toByteArray())

    fun sessionKey(secret: ByteArray, phoneNonce: ByteArray, macNonce: ByteArray) =
        hkdf(secret, phoneNonce + macNonce, "session".toByteArray())

    fun pairProofMessage(deviceId: String, nonce: ByteArray) = "phonecam-pair|$deviceId|${b64url(nonce)}"

    fun authMessage(role: String, deviceId: String, phoneNonce: ByteArray, macNonce: ByteArray) =
        "phonecam-auth-$role|$deviceId|${b64url(phoneNonce)}|${b64url(macNonce)}"

    /** AES-GCM; [sealed] is ciphertext||tag as produced by CryptoKit. */
    fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray, aad: String): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad.toByteArray())
        return cipher.doFinal(sealed)
    }

    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, aad: String): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad.toByteArray())
        return cipher.doFinal(plaintext)
    }

    fun randomBytes(n: Int) = ByteArray(n).also { random.nextBytes(it) }

    // java.util.Base64 works on the JVM (unit tests) and on API 26+.
    fun b64url(data: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun fromB64url(s: String): ByteArray = java.util.Base64.getUrlDecoder().decode(s)
}
