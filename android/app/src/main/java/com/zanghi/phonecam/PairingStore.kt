package com.zanghi.phonecam

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

data class TrustedMac(val macId: String, val name: String, val hosts: List<String>, val port: Int, val secret: ByteArray)

/**
 * Phone identity and the trusted Macs (any number; the camera streams to one at a time). Each device secret is wrapped
 * with a non-exportable Android Keystore key.
 */
class PairingStore(private val context: Context) {
    private val prefs = context.getSharedPreferences("pairing", Context.MODE_PRIVATE)

    val deviceId: String
        get() = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("deviceId", it).apply() }

    val deviceName: String
        get() = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    /** Trusted Macs, oldest pairing first. Entries whose secret can't be unwrapped are skipped. */
    fun loadAll(): List<TrustedMac> = synchronized(LOCK) {
        migrateSingle()
        val arr = try { JSONArray(prefs.getString("macs", "[]")) } catch (e: Exception) { JSONArray() }
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val id = o.optString("macId").ifBlank { return@mapNotNull null }
            val secret = try { unwrap(PairingCrypto.fromB64url(o.getString("secret"))) } catch (e: Exception) { return@mapNotNull null }
            TrustedMac(id, o.optString("name", "Mac"), o.optString("hosts").split(",").filter { it.isNotBlank() },
                o.optInt("port", 47800), secret)
        }
    }

    fun load(macId: String): TrustedMac? = loadAll().firstOrNull { it.macId == macId }

    /** Adds the Mac, or replaces the entry with the same id (re-pairing renews its secret). */
    fun save(mac: TrustedMac) {
        val entry = MacList.entry(mac.macId, mac.name, mac.hosts, mac.port, PairingCrypto.b64url(wrap(mac.secret)))
        edit { list -> MacList.upsert(list, entry) }
    }

    /** Remember addresses that worked or were discovered, most recent first. */
    fun updateAddress(macId: String, host: String, port: Int) = edit { list -> MacList.updateAddress(list, macId, host, port) }

    fun remove(macId: String) = edit { list -> MacList.remove(list, macId) }

    fun clear() = synchronized(LOCK) { prefs.edit().remove("macs").commit(); Unit }

    /** The activity and the service each make a store; one lock serializes their read-modify-write. */
    private fun edit(f: (List<JSONObject>) -> List<JSONObject>) = synchronized(LOCK) {
        migrateSingle()
        val arr = try { JSONArray(prefs.getString("macs", "[]")) } catch (e: Exception) { JSONArray() }
        val list = (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
        prefs.edit().putString("macs", JSONArray(f(list)).toString()).commit()
    }

    /** Builds before multi-Mac pairing kept one Mac in separate keys; move it into the list once. */
    private fun migrateSingle() {
        val id = prefs.getString("macId", null) ?: return
        val e = prefs.edit()
        MacList.migrateLegacy(id, prefs.getString("macName", null), prefs.getString("hosts", null), prefs.getInt("port", 47800),
            prefs.getString("secret", null), hasList = prefs.contains("macs"))?.let { e.putString("macs", JSONArray(it).toString()) }
        e.remove("macId").remove("macName").remove("hosts").remove("port").remove("secret").commit()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .build())
        return gen.generateKey()
    }

    private fun wrap(data: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return c.iv + c.doFinal(data)
    }

    private fun unwrap(blob: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12)))
        return c.doFinal(blob.copyOfRange(12, blob.size))
    }

    companion object {
        private const val KEY_ALIAS = "phonecam-device-secret"
        private val LOCK = Any()
    }
}

/**
 * The stored list of trusted Macs as JSON entries (`macId`, `name`, `hosts` comma-separated, `port`, `secret` wrapped),
 * kept free of Android APIs so the list rules are unit-tested.
 */
object MacList {
    const val MAX_HOSTS = 4

    fun entry(macId: String, name: String, hosts: List<String>, port: Int, wrappedSecret: String): JSONObject =
        JSONObject().put("macId", macId).put("name", name).put("hosts", hosts.joinToString(",")).put("port", port).put("secret", wrappedSecret)

    /** Replaces the entry with the same id in place, or appends a new one (the list stays oldest pairing first). */
    fun upsert(list: List<JSONObject>, entry: JSONObject): List<JSONObject> {
        val id = entry.optString("macId")
        return if (list.any { it.optString("macId") == id }) list.map { if (it.optString("macId") == id) entry else it } else list + entry
    }

    /** Puts [host] first in that Mac's addresses (deduplicated, at most [MAX_HOSTS]) and records [port]. */
    fun updateAddress(list: List<JSONObject>, macId: String, host: String, port: Int): List<JSONObject> = list.map { o ->
        if (o.optString("macId") != macId) o
        else o.put("hosts", (listOf(host) + o.optString("hosts").split(",")).map { it.trim() }.filter { it.isNotBlank() }.distinct()
            .take(MAX_HOSTS).joinToString(",")).put("port", port)
    }

    fun remove(list: List<JSONObject>, macId: String): List<JSONObject> = list.filter { it.optString("macId") != macId }

    /**
     * Builds before multi-Mac pairing kept one Mac in separate keys. Returns the list to store, or null when there is
     * nothing to move (no secret, or a list already exists and wins).
     */
    fun migrateLegacy(macId: String, name: String?, hosts: String?, port: Int, secret: String?, hasList: Boolean): List<JSONObject>? {
        if (secret == null || hasList) return null
        return listOf(JSONObject().put("macId", macId).put("name", name ?: "Mac").put("hosts", hosts ?: "").put("port", port).put("secret", secret))
    }
}
