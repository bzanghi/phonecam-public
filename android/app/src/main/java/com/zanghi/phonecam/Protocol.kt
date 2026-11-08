package com.zanghi.phonecam

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder

const val PROTOCOL_VERSION = 1

/** Contents of the QR code: phonecam://pair?v=1&id=..&n=..&h=ip1,ip2&p=port&k=token */
data class PairingPayload(val macId: String, val macName: String, val hosts: List<String>, val port: Int, val token: ByteArray) {
    companion object {
        /**
         * Strict: any app or web page can hand us this URL, so only private-LAN IPv4 hosts are accepted (no hostnames,
         * no public addresses). java.net.URI keeps this testable on the JVM.
         */
        fun parse(text: String): PairingPayload? = try {
            val uri = URI(text.trim())
            if (uri.scheme != "phonecam" || uri.host != "pair") null
            else {
                val q = query(uri.rawQuery ?: "")
                val id = q["id"]
                val hosts = q["h"]?.split(",")?.filter { it.isNotBlank() } ?: emptyList()
                val port = q["p"]?.toIntOrNull()
                val token = q["k"]?.let { PairingCrypto.fromB64url(it) }
                if (q["v"] != PROTOCOL_VERSION.toString() || id.isNullOrEmpty() || id.length > 128 ||
                    hosts.isEmpty() || !hosts.all { LanAddress.isPrivateIPv4(it) } ||
                    port == null || port !in 1..65535 || token == null || token.size != 16) null
                else PairingPayload(id, cleanName(q["n"]), hosts, port, token)
            }
        } catch (e: Exception) {
            null
        }

        private fun query(raw: String): Map<String, String> = raw.split("&").filter { it.isNotEmpty() }.associate {
            val i = it.indexOf('=')
            val k = if (i < 0) it else it.substring(0, i)
            val v = if (i < 0) "" else it.substring(i + 1)
            URLDecoder.decode(k, "UTF-8") to URLDecoder.decode(v, "UTF-8")
        }

        private fun cleanName(name: String?): String =
            name?.filter { !it.isISOControl() }?.trim()?.take(64)?.ifBlank { null } ?: "Mac"
    }
}

/** LAN-only checks for pairing hosts, Bonjour results and ICE candidates. */
object LanAddress {
    fun isPrivateIPv4(ip: String): Boolean {
        val p = ipv4(ip) ?: return false
        return p[0] == 10 || (p[0] == 172 && p[1] in 16..31) || (p[0] == 192 && p[1] == 168)
    }

    /** Private/link-local IPv4, IPv6 link-local (fe80::/10) or unique-local (fc00::/7), or an mDNS .local name. */
    fun isLocal(address: String): Boolean {
        val a = address.trim().removePrefix("[").removeSuffix("]")
        if (a.endsWith(".local", ignoreCase = true)) return true
        ipv4(a)?.let { p -> return isPrivateIPv4(a) || (p[0] == 169 && p[1] == 254) }
        if (!a.contains(':')) return false
        val first = a.substringBefore(':').ifEmpty { return false }
        val word = first.toIntOrNull(16) ?: return false
        return (word and 0xffc0) == 0xfe80 || (word and 0xfe00) == 0xfc00
    }

    /** True if an ICE candidate line ("candidate:… <ip> <port> typ …", optionally prefixed "a=") is on the LAN. */
    fun isLocalCandidate(candidate: String): Boolean {
        val parts = candidate.trim().removePrefix("a=").split(" ")
        return parts.size > 5 && isLocal(parts[4])
    }

    /** Removes a=candidate lines that point off the LAN. */
    fun filterSdp(sdp: String): String =
        sdp.split("\r\n").filter { !it.startsWith("a=candidate:") || isLocalCandidate(it) }.joinToString("\r\n")

    private fun ipv4(s: String): List<Int>? {
        val p = s.split(".")
        if (p.size != 4) return null
        val n = p.map { part -> if (part.isEmpty() || part.length > 3 || !part.all { it.isDigit() }) return null else part.toInt() }
        return n.takeIf { it.all { v -> v in 0..255 } }
    }
}

/** Camera or lens option offered to the user and the Mac. */
data class CameraOption(val id: String, val label: String, val facing: String, val zoom: Float) {
    val isFront get() = facing == "front"
    fun toJson() = JSONObject().put("id", id).put("label", label).put("facing", facing)
}

fun json(vararg pairs: Pair<String, Any?>): JSONObject {
    val o = JSONObject()
    for ((k, v) in pairs) if (v != null) o.put(k, v)
    return o
}

fun List<CameraOption>.toJsonArray() = JSONArray().also { a -> forEach { a.put(it.toJson()) } }
