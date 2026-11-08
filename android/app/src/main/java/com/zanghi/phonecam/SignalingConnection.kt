package com.zanghi.phonecam

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.Executor

/**
 * One WebSocket to the Mac: optional pairing, then challenge-response auth, then HMAC-sealed signaling.
 * All listener callbacks run on [executor].
 */
class SignalingConnection(
    private val http: OkHttpClient,
    private val executor: Executor,
    private val deviceId: String,
    private val deviceName: String,
    val host: String,
    val port: Int,
    private val listener: Listener,
) {
    interface Listener {
        fun onOpen(conn: SignalingConnection) {}
        fun onPaired(conn: SignalingConnection, macName: String, secret: ByteArray)
        fun onAuthenticated(conn: SignalingConnection, macName: String?)
        fun onSignal(conn: SignalingConnection, body: JSONObject)
        fun onRejected(conn: SignalingConnection, code: String, message: String)
        fun onClosed(conn: SignalingConnection, reason: String)
    }

    private enum class State { CONNECTING, PAIRING, HELLO, AUTH, AUTHENTICATED, CLOSED }

    private var ws: WebSocket? = null
    private var state = State.CONNECTING
    private var pairToken: ByteArray? = null
    private var secret: ByteArray? = null
    private var phoneNonce = ByteArray(0)
    private var macNonce = ByteArray(0)
    private var sessionKey: ByteArray? = null
    private var sendSeq = 0
    private var recvSeq = 0
    @Volatile var lastReceived = System.nanoTime()
        private set
    val isAuthenticated get() = state == State.AUTHENTICATED
    /** True once auth succeeded, even after the socket closed. */
    var wasAuthenticated = false
        private set
    val isClosed get() = state == State.CLOSED

    /** Pair with a QR token (then auth with the issued secret), or auth with an existing [secret]. */
    fun start(pairToken: ByteArray?, secret: ByteArray?) {
        this.pairToken = pairToken
        this.secret = secret
        val request = Request.Builder().url("ws://$host:$port/").build()
        ws = http.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) = executor.execute { handleOpen() }
            override fun onMessage(webSocket: WebSocket, text: String) = executor.execute { handle(text) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                executor.execute { closeLocally("Mac closed the connection") }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                executor.execute { closeLocally(t.message ?: t.javaClass.simpleName) }
        })
    }

    fun close(reason: String = "closed") {
        ws?.close(1000, null)
        closeLocally(reason)
    }

    /** Sends a sealed goodbye, then closes without cancelling, so OkHttp flushes the queued message first. */
    fun closeWithBye(body: JSONObject, reason: String) {
        if (state == State.CLOSED) return
        sendSignal(body)
        ws?.close(1000, null)
        state = State.CLOSED
        listener.onClosed(this, reason)
    }

    fun ping() {
        if (state != State.CLOSED) ws?.send("""{"t":"ping"}""")
    }

    fun sendSignal(body: JSONObject) {
        val key = sessionKey ?: return
        if (state != State.AUTHENTICATED) return
        sendSeq += 1
        val text = body.toString()
        val mac = PairingCrypto.hmac(key, "p2m|$sendSeq|$text")
        ws?.send(json("t" to "sealed", "seq" to sendSeq, "body" to text, "mac" to PairingCrypto.b64url(mac)).toString())
    }

    private fun handleOpen() {
        if (state == State.CLOSED) return
        listener.onOpen(this)
        val token = pairToken
        if (token != null) {
            state = State.PAIRING
            val nonce = PairingCrypto.randomBytes(16)
            val proof = PairingCrypto.hmac(PairingCrypto.pairingKey(token), PairingCrypto.pairProofMessage(deviceId, nonce))
            send(json("t" to "pair", "v" to PROTOCOL_VERSION, "deviceId" to deviceId, "deviceName" to deviceName,
                "nonce" to PairingCrypto.b64url(nonce), "proof" to PairingCrypto.b64url(proof)))
        } else {
            sendHello()
        }
    }

    private fun sendHello() {
        state = State.HELLO
        phoneNonce = PairingCrypto.randomBytes(16)
        send(json("t" to "hello", "v" to PROTOCOL_VERSION, "deviceId" to deviceId, "nonce" to PairingCrypto.b64url(phoneNonce)))
    }

    private fun handle(text: String) {
        if (state == State.CLOSED) return
        val m = try { JSONObject(text) } catch (e: Exception) { return }
        // After auth only authenticated (sealed) traffic proves the Mac is alive; a spoofed plain pong must not.
        if (state != State.AUTHENTICATED || m.optString("t") == "sealed") lastReceived = System.nanoTime()
        when (m.optString("t")) {
            "pong" -> {}
            "error" -> {
                val code = m.optString("code")
                listener.onRejected(this, code, m.optString("message"))
                close("rejected: $code")
            }
            "paired" -> {
                val token = pairToken ?: return close("unexpected paired")
                try {
                    val s = PairingCrypto.open(PairingCrypto.pairingKey(token), PairingCrypto.fromB64url(m.getString("sealedNonce")),
                        PairingCrypto.fromB64url(m.getString("sealedSecret")), deviceId)
                    secret = s
                    pairToken = null
                    listener.onPaired(this, m.optString("macName", "Mac"), s)
                    sendHello()
                } catch (e: Exception) {
                    listener.onRejected(this, "bad_proof", "Could not read the pairing response.")
                    close("pairing decrypt failed")
                }
            }
            "challenge" -> {
                val s = secret ?: return close("no secret")
                if (state != State.HELLO) return close("unexpected challenge")
                macNonce = PairingCrypto.fromB64url(m.getString("nonce"))
                state = State.AUTH
                val proof = PairingCrypto.hmac(s, PairingCrypto.authMessage("phone", deviceId, phoneNonce, macNonce))
                send(json("t" to "auth", "proof" to PairingCrypto.b64url(proof)))
            }
            "authok" -> {
                val s = secret ?: return close("no secret")
                if (state != State.AUTH) return close("unexpected authok")
                // The Mac proves it holds the same secret, so we never stream to an impostor on the network.
                val ok = PairingCrypto.verify(s, PairingCrypto.authMessage("mac", deviceId, phoneNonce, macNonce),
                    PairingCrypto.fromB64url(m.optString("proof")))
                if (!ok) {
                    listener.onRejected(this, "mac_identity", "This Mac could not prove its identity.")
                    return close("mac proof failed")
                }
                sessionKey = PairingCrypto.sessionKey(s, phoneNonce, macNonce)
                state = State.AUTHENTICATED
                wasAuthenticated = true
                listener.onAuthenticated(this, m.optString("macName").ifBlank { null })
            }
            "sealed" -> {
                val key = sessionKey ?: return
                val seq = m.optInt("seq")
                val body = m.optString("body")
                val mac = PairingCrypto.fromB64url(m.optString("mac"))
                if (seq <= recvSeq || !PairingCrypto.verify(key, "m2p|$seq|$body", mac)) {
                    Log.w(TAG, "dropping unauthenticated message")
                    return close("bad message authentication")
                }
                recvSeq = seq
                val b = JSONObject(body)
                if (b.optString("t") != "pong") listener.onSignal(this, b)
            }
        }
    }

    private fun send(o: JSONObject) {
        ws?.send(o.toString())
    }

    private fun closeLocally(reason: String) {
        if (state == State.CLOSED) return
        state = State.CLOSED
        ws?.cancel()
        listener.onClosed(this, reason)
    }

    companion object {
        private const val TAG = "PhoneCamSignal"
    }
}
