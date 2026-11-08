package com.zanghi.phonecam

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.PowerManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import android.util.Size
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpParameters
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSink
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

enum class Phase { IDLE, CONNECTING, STANDBY, LIVE, RECONNECTING, PAUSED, NEEDS_PAIRING }

/** One paired Mac as the UI shows it. */
data class MacStatus(val macId: String, val name: String, val status: String, val live: Boolean = false,
                     val waiting: Boolean = false, val needsPairing: Boolean = false, val stopped: Boolean = false)

data class UiState(
    val phase: Phase = Phase.IDLE,
    val macName: String? = null,
    val message: String? = null,
    val macs: List<MacStatus> = emptyList(),
    val streaming: Boolean = false,        // a Mac has the camera (live or starting)
    val cameras: List<CameraOption> = emptyList(),
    val camera: String? = null,
    val resolution: Size? = null,
    val fps: Int = 0,
    val cameraNote: String? = null,
    val limited: String? = null,          // "network" | "thermal" when stepped down to 720p
    val torch: Boolean = false,           // light the back flash while live
    val torchLevel: Int = 1,
    val torchMax: Int = 0,                // brightness steps; 1 = on/off only, 0 = no flash
)

/**
 * Owns the camera, the WebRTC sender and one signaling link per paired Mac; each link reconnects on its own until
 * stopped or until its Mac revokes trust. The camera only runs while a Mac asks for video (control "start"), i.e. while
 * an app on that Mac uses Phone Camera, and streams to one Mac at a time ([CameraArbiter]). Everything mutable is
 * confined to [exec].
 */
class StreamController(private val context: Context, private val lifecycleOwner: LifecycleOwner) {
    private val exec = Executors.newSingleThreadScheduledExecutor { Thread(it, "phonecam-controller") }
    private val store = PairingStore(context)
    private val http = OkHttpClient.Builder()
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()
    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state

    val eglBase: EglBase = EglBase.create()
    private lateinit var factory: PeerConnectionFactory
    private lateinit var helper: SurfaceTextureHelper
    private lateinit var source: VideoSource
    lateinit var track: VideoTrack
        private set
    private lateinit var capturer: CameraXCapturer
    private lateinit var audioSource: AudioSource
    private lateinit var audioTrack: AudioTrack
    /** The current peer carries the microphone (the Mac asked for it and the permission is granted). */
    private var peerAudio = false
    private var cameraRunning = false

    private val links = mutableListOf<MacLink>()
    private val arbiter = CameraArbiter()
    private var pc: PeerConnection? = null
    private var peerLink: MacLink? = null
    private var transceiver: RtpTransceiver? = null
    private var videoLive = false
    private var videoInterrupted = false
    private var peerCheckTask: ScheduledFuture<*>? = null
    private var pingTask: ScheduledFuture<*>? = null
    private var cameraOffTask: ScheduledFuture<*>? = null
    private var peerConnectedAt = 0L
    private val quality = QualityPolicy()
    private var thermal = PowerManager.THERMAL_STATUS_NONE
    private var battery: Int? = null
    private var stopped = true
    private var stopMessage: String? = null
    private var scannerOpen = false
    private var notice: String? = null
    private var frames = 0
    private var torchApplied = 0
    private val captureAges = mutableListOf<Long>()

    private val nsd = context.getSystemService(NsdManager::class.java)
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val power = context.getSystemService(PowerManager::class.java)
    private val thermalListener = PowerManager.OnThermalStatusChangedListener { status -> exec.execute { onThermal(status) } }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = exec.execute { if (!stopped) links.filter { it.idle() }.forEach { it.reconnectSoon(0) } }
    }

    private val owner: MacLink? get() = arbiter.owner?.let { id -> links.firstOrNull { it.macId == id } }

    fun init() {
        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context).createInitializationOptions())
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory()
        helper = SurfaceTextureHelper.create("phonecam-capture", eglBase.eglBaseContext)
        source = factory.createVideoSource(false)
        capturer = CameraXCapturer(context, lifecycleOwner, object : CameraXCapturer.Events {
            override fun onCameraState(open: Boolean, error: String?) = exec.execute {
                update { it.copy(cameraNote = error) }
                sendStateAll()
            }
            override fun onResolution(size: Size) = exec.execute { update { it.copy(resolution = size) }; sendStateAll() }
        })
        capturer.initialize(helper, context, source.capturerObserver)
        track = factory.createVideoTrack("phonecam-video", source)
        // Recording only runs while a peer sends this track, i.e. while streaming to a Mac that asked for the mic.
        audioSource = factory.createAudioSource(MediaConstraints())
        audioTrack = factory.createAudioTrack("phonecam-audio", audioSource)
        track.addSink(VideoSink { f ->
            // Capture age when WebRTC gets the frame (sensor timestamp vs now), for the lip-sync log line.
            val age = (System.nanoTime() - f.timestampNs) / 1_000_000
            exec.execute { frames++; captureAges += age }
        })
        val options = CameraXCapturer.availableOptions(context)
        val saved = context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString("camera", null)
        val initial = options.firstOrNull { it.id == saved } ?: options.firstOrNull { it.id == "back" } ?: options.firstOrNull()
        initial?.let { capturer.select(it) }
        val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
        val torchMax = Torch.maxLevel(context)
        update { it.copy(cameras = options, camera = initial?.id, torch = prefs.getBoolean("torch", false),
            torchLevel = prefs.getInt("torchLevel", Torch.defaultLevel(context)).coerceIn(1, maxOf(torchMax, 1)), torchMax = torchMax) }
        exec.scheduleWithFixedDelay({ update { it.copy(fps = frames / 2) }; frames = 0; pollHealth() }, 2, 2, TimeUnit.SECONDS)
        thermal = power.currentThermalStatus
        try { power.addThermalStatusListener(exec, thermalListener) } catch (_: Exception) {}
    }

    // MARK: Public API (any thread)

    /** Connects to every paired Mac; with [pairing], also pairs a new Mac (or renews an existing pairing). */
    fun start(pairing: PairingPayload?) = exec.execute {
        val wasStopped = stopped
        stopped = false
        stopMessage = null
        notice = null
        for (mac in store.loadAll()) {
            val link = links.firstOrNull { it.macId == mac.macId } ?: MacLink(mac, null).also { links += it }
            link.mac = mac
        }
        if (pairing != null) {
            val link = links.firstOrNull { it.macId == pairing.macId } ?: MacLink(null, pairing).also { links += it }
            link.pending = pairing
            link.dropConnection("re-pairing")
            link.revive()
        }
        links.forEach { if (wasStopped || it.dormant) it.revive() }
        if (links.isEmpty()) {
            stopped = true
            publish()
            return@execute
        }
        startDiscovery()
        try { connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), networkCallback) } catch (_: Exception) {}
        if (pingTask == null) pingTask = exec.scheduleWithFixedDelay({ links.forEach { it.ping() } }, 2, 2, TimeUnit.SECONDS)
        links.filter { it.idle() }.forEach { it.connect() }
        publish()
    }

    fun stop() = exec.execute { shutdown(null, bye = true) }

    fun selectCamera(id: String) = exec.execute { applyCamera(id) }

    /** Live indicator: the back flash lights while video is live, at [level]. */
    fun setTorch(enabled: Boolean, level: Int) = exec.execute {
        val l = level.coerceIn(1, maxOf(_state.value.torchMax, 1))
        context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putBoolean("torch", enabled).putInt("torchLevel", l).apply()
        update { it.copy(torch = enabled, torchLevel = l) }
        syncTorch()
        sendStateAll()
    }

    /** Flips the light setting, keeping the saved brightness (notification button). */
    fun toggleTorch() = _state.value.let { setTorch(!it.torch, it.torchLevel) }

    private fun syncTorch() {
        val s = _state.value
        val want = if (s.torch && s.torchMax > 0 && videoLive && cameraRunning) s.torchLevel else 0
        if (want == torchApplied) return
        torchApplied = want
        capturer.setTorch(want)
    }

    /** Moves the camera to [macId], which is waiting for it; the Mac that had it waits instead. */
    fun useOn(macId: String) = exec.execute { moveCameraTo(macId) }

    private fun moveCameraTo(macId: String) {
        val previous = owner
        if (!arbiter.takeOver(macId)) return
        previous?.let { closePeer(); it.sendState() }
        owner?.let { startVideo(it) }
        publish()
    }

    /** Reconnects one Mac that stopped (another phone took it over, or it refused this phone). */
    fun reconnectMac(macId: String) = exec.execute {
        val link = links.firstOrNull { it.macId == macId } ?: return@execute
        if (stopped) return@execute
        link.revive()
        notice = null
        if (link.idle()) link.connect()
        publish()
    }

    /** The QR scanner needs the camera: hold video until it closes (CameraX would unbind one or the other). */
    fun setScanning(open: Boolean) = exec.execute {
        if (scannerOpen == open) return@execute
        scannerOpen = open
        if (!open) owner?.let { startVideo(it) }
    }

    fun forgetMac(macId: String) = exec.execute {
        store.remove(macId)
        val link = links.firstOrNull { it.macId == macId } ?: return@execute
        removeLink(link)
    }

    fun release() = exec.execute {
        shutdown(null, bye = true)
        try { power.removeThermalStatusListener(thermalListener) } catch (_: Exception) {}
        audioTrack.dispose(); audioSource.dispose(); track.dispose(); source.dispose(); helper.dispose(); factory.dispose(); eglBase.release()
        exec.shutdown()
    }

    // MARK: Lifecycle

    private fun shutdown(message: String?, bye: Boolean = false) {
        stopped = true
        stopMessage = message
        pingTask?.cancel(false)
        pingTask = null
        cameraOffTask?.cancel(false)
        links.forEach { it.close(bye) }
        arbiter.clear()
        closePeer()
        stopCamera()
        stopDiscovery()
        try { connectivity.unregisterNetworkCallback(networkCallback) } catch (_: Exception) {}
        publish()
    }

    private fun removeLink(link: MacLink) {
        link.close(bye = false)
        links.remove(link)
        releaseVideo(link)
        if (links.isEmpty()) shutdown(null) else publish()
    }

    // MARK: Camera arbitration

    /** [link]'s Mac asked for video: stream to it if the camera is free, otherwise queue it. */
    private fun requestVideo(link: MacLink) {
        if (link.conn?.isAuthenticated != true) return
        link.wantsVideo = true
        if (arbiter.request(link.macId)) startVideo(link) else link.sendState()
        publish()
    }

    /** [link]'s Mac no longer wants video (idle, paused, gone): hand the camera to the next waiting Mac, if any. */
    private fun releaseVideo(link: MacLink, keepCameraWarm: Boolean = false) {
        link.wantsVideo = false
        val wasOwner = arbiter.owner == link.macId
        val next = arbiter.release(link.macId)
        if (!wasOwner) return
        closePeer()
        val nextLink = next?.let { id -> links.firstOrNull { it.macId == id } }
        if (nextLink != null) {
            startVideo(nextLink)
        } else if (keepCameraWarm) {
            // Keep the camera warm briefly for a quick reconnect, then turn it off.
            cameraOffTask?.cancel(false)
            cameraOffTask = exec.schedule({ if (arbiter.owner == null) stopCamera() }, 15, TimeUnit.SECONDS)
        } else {
            stopCamera()
        }
        sendStateAll()
    }

    /** The camera belongs to [link]: camera on, and a new offer unless a peer to this Mac already exists. */
    private fun startVideo(link: MacLink) {
        if (link.conn?.isAuthenticated != true || arbiter.owner != link.macId) return
        if (scannerOpen) { link.sendState(); publish(); return }   // resumes from setScanning(false)
        cameraOffTask?.cancel(false)
        startCamera()
        if (pc == null || peerLink !== link || peerAudio != wantsAudio(link)) startPeer(link)
        sendStateAll()
    }

    private fun micPermission() = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    /** Each Mac chooses: its "Phone microphone" switch puts mic=true on "start". */
    private fun wantsAudio(link: MacLink) = link.wantsMic && micPermission()

    // MARK: Discovery (Bonjour/NSD) so the phone finds a Mac after its IP changes

    private fun startDiscovery() {
        if (discoveryListener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(info: NsdServiceInfo) = exec.execute {
                        val id = info.attributes["id"]?.let { String(it) } ?: return@execute
                        @Suppress("DEPRECATION")
                        val host = info.host?.hostAddress ?: return@execute
                        val link = links.firstOrNull { it.macId == id } ?: return@execute
                        if (LanAddress.isPrivateIPv4(host)) {
                            link.discovered = host to info.port
                            if (!stopped && link.idle()) link.reconnectSoon(0)
                        }
                    }
                })
            }
        }
        discoveryListener = l
        try { nsd.discoverServices("_phonecam._tcp", NsdManager.PROTOCOL_DNS_SD, l) } catch (e: Exception) { discoveryListener = null }
    }

    private fun stopDiscovery() {
        discoveryListener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        discoveryListener = null
    }

    // MARK: Camera + WebRTC

    private fun startCamera() {
        if (cameraRunning) return
        cameraRunning = true
        val h = quality.decision.height
        capturer.startCapture(if (h == 720) 1280 else 1920, h, cameraFps())
    }

    private fun stopCamera() {
        if (!cameraRunning) return
        cameraRunning = false
        torchApplied = 0
        capturer.setTorch(0)
        capturer.stopCapture()
    }

    private fun startPeer(link: MacLink) {
        closePeer()
        val config = PeerConnection.RTCConfiguration(emptyList()).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
            rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
        }
        val observer = PeerObserver()
        val peer = factory.createPeerConnection(config, observer) ?: return
        observer.peer = peer
        pc = peer
        peerLink = link
        val t = peer.addTransceiver(track, RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_ONLY, listOf("phonecam")))
        transceiver = t
        // Prefer H.264 (hardware encode on the phone, VideoToolbox decode on the Mac).
        val codecs = factory.getRtpSenderCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO).codecs
        t.setCodecPreferences(codecs.sortedBy { if (it.name.equals("H264", true)) 0 else 1 })
        // Same stream id as the video, so the Mac's WebRTC lip-syncs the two.
        peerAudio = wantsAudio(link)
        if (peerAudio) peer.addTransceiver(audioTrack, RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.SEND_ONLY, listOf("phonecam")))
        Log.i(TAG, "offer to ${link.name}: video${if (peerAudio) " + mic" else ""}")
        peer.createOffer(object : LoggingSdpObserver("createOffer") {
            override fun onCreateSuccess(sdp: SessionDescription) = exec.execute {
                if (pc !== peer) return@execute
                peer.setLocalDescription(LoggingSdpObserver("setLocal"), sdp)
                link.conn?.sendSignal(json("t" to "offer", "sdp" to sdp.description))
                tuneSender()
            }
        }, MediaConstraints())
        publish()
    }

    private fun tuneSender() {
        val sender = transceiver?.sender ?: return
        val params = sender.parameters
        // Keep the resolution we pick (1080p or 720p, see QualityPolicy) and let congestion lower the frame rate,
        // instead of libwebrtc scaling down to 360p or below.
        params.degradationPreference = RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION
        params.encodings.firstOrNull()?.apply {
            // 720p looks the same at 3.5 Mbps as at 6; the lower cap saves encoder and Wi-Fi power when stepped down.
            maxBitrateBps = if (appliedHeight == 720) 3_500_000 else 6_000_000
            minBitrateBps = 600_000
            maxFramerate = captureFps()
        }
        sender.setParameters(params)
    }

    // MARK: Quality (720p step-down) and phone health

    private fun pollHealth() {
        val b = try { context.getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) } catch (_: Exception) { null }
        if (b != null && b in 0..100 && b != battery) { battery = b; sendStateAll() }
        val peer = pc ?: return
        logLatency(peer)
        // Ignore the first seconds of a connection while the bandwidth estimate ramps up from the start bitrate.
        if (peerConnectedAt == 0L || System.currentTimeMillis() - peerConnectedAt < 10_000) return
        peer.getStats { report ->
            var available: Double? = null
            for (st in report.statsMap.values) {
                if (st.type == "candidate-pair" && st.members["nominated"] == true) {
                    (st.members["availableOutgoingBitrate"] as? Number)?.toDouble()?.let { available = it }
                }
            }
            exec.execute { if (pc === peer) applyQuality(quality.sample(available, thermal, System.currentTimeMillis())) }
        }
    }

    private var lastEncode = 0.0 to 0L

    /** Phone-side share of the delay: capture age at the encoder input and mean encode time (logcat, tag PhoneCam). */
    private fun logLatency(peer: PeerConnection) {
        val ages = captureAges.sorted().also { captureAges.clear() }
        peer.getStats { report ->
            for (st in report.statsMap.values) {
                if (st.type != "outbound-rtp" || st.members["kind"] != "video") continue
                val t = (st.members["totalEncodeTime"] as? Number)?.toDouble() ?: continue
                val n = (st.members["framesEncoded"] as? Number)?.toLong() ?: continue
                exec.execute {
                    val (t0, n0) = lastEncode
                    lastEncode = t to n
                    val enc = if (n > n0) (t - t0) / (n - n0) * 1000 else 0.0
                    Log.i(TAG, "latency: capture age median ${ages.getOrNull(ages.size / 2) ?: -1} ms, encode ${"%.1f".format(enc)} ms/frame")
                }
            }
        }
    }

    private fun onThermal(status: Int) {
        if (status == thermal) return
        val severeChanged = (status >= QualityPolicy.THERMAL_SEVERE) != (thermal >= QualityPolicy.THERMAL_SEVERE)
        thermal = status
        Log.i(TAG, "thermal status $status")
        val heightBefore = appliedHeight
        applyQuality(quality.evaluate(status), force = true)
        if (severeChanged) {
            tuneSender()
            // Capture at the encoder's rate too, instead of capturing 30 and dropping 6 of them.
            if (cameraRunning && appliedHeight == heightBefore) capturer.changeCaptureFormat(if (appliedHeight == 720) 1280 else 1920, appliedHeight, cameraFps())
        }
    }

    /** Encoder (sent) frame rate. */
    private fun captureFps() = if (thermal >= QualityPolicy.THERMAL_SEVERE) 24 else 30

    /** Camera frame rate: 60 with the lip-sync experiment pref "captureFps60" (the encoder still sends [captureFps]). */
    private fun cameraFps(): Int {
        val fast = context.getSharedPreferences("settings", Context.MODE_PRIVATE).getBoolean("captureFps60", false)
        return if (fast && thermal < QualityPolicy.THERMAL_SEVERE) 60 else captureFps()
    }

    private var appliedHeight = 1080
    private var appliedLimited: String? = null

    private fun applyQuality(d: QualityPolicy.Decision, force: Boolean = false) {
        if (d.height != appliedHeight) {
            appliedHeight = d.height
            Log.i(TAG, "capture ${d.height}p (${d.limited ?: "full quality"})")
            if (cameraRunning) capturer.changeCaptureFormat(if (d.height == 720) 1280 else 1920, d.height, cameraFps())
            tuneSender()
        }
        if (d.limited != appliedLimited || force) {
            appliedLimited = d.limited
            update { it.copy(limited = d.limited) }
            sendStateAll()
        }
    }

    private fun closePeer() {
        peerCheckTask?.cancel(false)
        peerConnectedAt = 0L
        videoLive = false
        videoInterrupted = false
        pc?.dispose()
        pc = null
        peerLink = null
        transceiver = null
        peerAudio = false
    }

    /** Callbacks for one peer connection; ignored once that peer is replaced, so a stale event can't reach the next Mac. */
    private inner class PeerObserver : PeerConnection.Observer {
        var peer: PeerConnection? = null
        private fun current() = peer != null && pc === peer
        override fun onIceCandidate(c: IceCandidate) = exec.execute {
            if (!current() || !LanAddress.isLocalCandidate(c.sdp)) return@execute
            peerLink?.conn?.sendSignal(json("t" to "candidate", "candidate" to c.sdp, "sdpMid" to c.sdpMid, "sdpMLineIndex" to c.sdpMLineIndex))
        }
        override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) = exec.execute {
            if (!current()) return@execute
            Log.i(TAG, "peer $newState")
            when (newState) {
                PeerConnection.PeerConnectionState.CONNECTED -> {
                    peerCheckTask?.cancel(false)
                    if (peerConnectedAt == 0L) peerConnectedAt = System.currentTimeMillis()
                    videoLive = true
                    videoInterrupted = false
                    publish()
                }
                PeerConnection.PeerConnectionState.DISCONNECTED, PeerConnection.PeerConnectionState.FAILED -> {
                    if (videoLive) { videoLive = false; videoInterrupted = true; publish() }
                    // ICE may recover by itself; if not, renegotiate over the (still authenticated) signaling link.
                    peerCheckTask?.cancel(false)
                    peerCheckTask = exec.schedule({
                        val o = owner
                        if (pc?.connectionState() != PeerConnection.PeerConnectionState.CONNECTED && o != null &&
                            o.conn?.isAuthenticated == true && !o.pausedByMac && o.wantsVideo) startPeer(o)
                    }, if (newState == PeerConnection.PeerConnectionState.FAILED) 0 else 3000, TimeUnit.MILLISECONDS)
                }
                else -> {}
            }
        }
        override fun onSignalingChange(s: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {}
        override fun onIceConnectionReceivingChange(b: Boolean) {}
        override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) {}
        override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
        override fun onAddStream(s: MediaStream) {}
        override fun onRemoveStream(s: MediaStream) {}
        override fun onDataChannel(d: DataChannel) {}
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(r: RtpReceiver, s: Array<out MediaStream>) {}
    }

    private fun applyCamera(id: String) {
        val opt = _state.value.cameras.firstOrNull { it.id == id } ?: return
        capturer.select(opt)
        context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putString("camera", id).apply()
        update { it.copy(camera = id) }
        sendStateAll()
    }

    private fun sendStateAll() = links.forEach { it.sendState() }

    // MARK: UI state

    /** Recomputes the phone-wide state from the links and the video. */
    private fun publish() {
        val o = owner
        val statuses = links.map { l ->
            val live = l === o && videoLive
            val waiting = arbiter.isWaiting(l.macId)
            val status = when {
                l.dormant -> l.note ?: "Stopped"
                l.authRejected -> "Pair again"
                l === o -> if (live) (if (peerAudio) "Live · camera + mic" else "Live") else if (videoInterrupted) "Video interrupted, reconnecting…" else "Starting video…"
                waiting -> "Wants the camera (in use on ${o?.name ?: "another Mac"})"
                l.pausedByMac && l.conn?.isAuthenticated == true -> "Paused from the Mac"
                l.conn?.isAuthenticated == true -> "Ready"
                l.everAuthenticated -> "Reconnecting…"
                else -> l.note ?: "Looking for this Mac…"
            }
            MacStatus(l.macId, l.name, status, live = live, waiting = waiting, needsPairing = l.authRejected, stopped = l.dormant)
        }
        val ready = links.filter { it.conn?.isAuthenticated == true && !it.dormant }
        val phase = when {
            links.isEmpty() -> Phase.NEEDS_PAIRING
            stopped || links.all { it.dormant } -> Phase.IDLE
            o != null -> if (videoLive) Phase.LIVE else if (videoInterrupted) Phase.RECONNECTING else Phase.CONNECTING
            ready.any { !it.pausedByMac } -> Phase.STANDBY
            ready.isNotEmpty() -> Phase.PAUSED
            links.all { it.authRejected || it.dormant } -> Phase.NEEDS_PAIRING
            links.any { it.everAuthenticated } -> Phase.RECONNECTING
            else -> Phase.CONNECTING
        }
        val name = o?.name ?: ready.singleOrNull()?.name ?: links.singleOrNull()?.name
            ?: ready.takeIf { it.isNotEmpty() }?.joinToString(" or ") { it.name }
        val message = notice ?: when (phase) {
            Phase.IDLE -> stopMessage ?: links.firstNotNullOfOrNull { l -> l.note.takeIf { l.dormant } }
            Phase.NEEDS_PAIRING -> links.firstNotNullOfOrNull { it.note } ?: "Scan the pairing code on your Mac."
            Phase.CONNECTING, Phase.RECONNECTING -> (o ?: links.singleOrNull())?.note
                ?: "Video interrupted. Reconnecting…".takeIf { videoInterrupted }
            Phase.PAUSED -> "Paused from the Mac"
            else -> null
        }
        update { it.copy(phase = phase, macName = name, message = message, macs = statuses, streaming = o != null) }
        syncTorch()
    }

    private fun update(f: (UiState) -> UiState) {
        _state.value = f(_state.value)
    }

    // MARK: One paired Mac

    /**
     * The signaling link to one Mac: pairing (with [pending]) or authentication, reconnect with backoff, and the Mac's
     * control messages. Confined to [exec].
     */
    private inner class MacLink(var mac: TrustedMac?, var pending: PairingPayload?) {
        val macId: String = pending?.macId ?: mac!!.macId
        val name: String get() = pending?.macName ?: mac?.name ?: "Mac"
        var conn: SignalingConnection? = null
        private var candidates: List<Pair<String, Int>> = emptyList()
        private var candidateIndex = 0
        /** Bumped by [connect]; a retry scheduled for an older round of addresses is ignored. */
        private var attempt = 0
        private var failures = 0
        private var reconnectTask: ScheduledFuture<*>? = null
        private var controlFallbackTask: ScheduledFuture<*>? = null
        var discovered: Pair<String, Int>? = null
        var pausedByMac = false
        /** The Mac sent "start" on the current connection (an app is using Phone Camera). */
        var wantsVideo = false
        /** The Mac's "start" asked for the microphone too. */
        var wantsMic = false
        var everAuthenticated = false
        var authRejected = false
        /** Not reconnecting until the user taps Start (another phone took over this Mac, or it refused us). */
        var dormant = false
        /** Latest problem or progress text for this Mac. */
        var note: String? = null

        fun revive() {
            dormant = false
            authRejected = false
            pausedByMac = false
            failures = 0
            note = null
        }

        /** No connection attempt in flight. Parallel attempts would race (and could reuse a single-use pairing token). */
        fun idle() = conn.let { it == null || it.isClosed }

        fun connect() {
            if (stopped || dormant) return
            reconnectTask?.cancel(false)
            val base = pending?.let { p -> p.hosts.map { it to p.port } } ?: mac?.let { t -> t.hosts.map { it to t.port } } ?: emptyList()
            // Known addresses first; Bonjour results (unauthenticated, spoofable) only add fallbacks after an IP change.
            candidates = (base + listOfNotNull(discovered)).distinct()
            candidateIndex = 0
            attempt++
            tryCandidate()
        }

        /** Closes the current socket without treating it as a lost connection (no retry is scheduled for it). */
        fun dropConnection(reason: String) {
            val c = conn
            conn = null
            c?.close(reason)
        }

        private fun tryCandidate() {
            if (stopped || dormant) return
            if (candidateIndex >= candidates.size) {
                if (authRejected) {
                    reconnectSoon(10_000)
                    return
                }
                failures++
                val where = candidates.joinToString { "${it.first}:${it.second}" }
                note = if (failures >= 2)
                    "Can’t reach $name ($where). Check that both are on the same Wi-Fi, the network allows devices to talk to each other, and the Mac firewall allows PhoneCam."
                else "Looking for $name…"
                publish()
                reconnectSoon(minOf(1000L * failures, 5000L))
                return
            }
            val (host, port) = candidates[candidateIndex++]
            val c = SignalingConnection(http, exec, store.deviceId, store.deviceName, host, port, listener)
            conn = c
            c.start(pending?.token, mac?.secret)
        }

        fun reconnectSoon(delayMs: Long) {
            if (stopped || dormant) return
            reconnectTask?.cancel(false)
            reconnectTask = exec.schedule({ if (idle()) connect() }, delayMs, TimeUnit.MILLISECONDS)
        }

        fun ping() {
            val c = conn ?: return
            c.ping()
            if (c.isAuthenticated && System.nanoTime() - c.lastReceived > TimeUnit.SECONDS.toNanos(7)) c.close("Mac stopped responding")
        }

        /** Closes the link for good (until revived); with [bye], tells the Mac the user stopped. */
        fun close(bye: Boolean) {
            reconnectTask?.cancel(false)
            controlFallbackTask?.cancel(false)
            wantsVideo = false
            val c = conn
            conn = null
            // So the Mac shows "Stopped on the phone" instead of reconnecting forever.
            if (bye && c != null && c.isAuthenticated) c.closeWithBye(json("t" to "bye", "note" to "stopped"), "stopped") else c?.close("stopped")
        }

        fun sendState() {
            val s = _state.value
            val o = owner
            conn?.sendSignal(json(
                "t" to "state",
                "streaming" to (o === this && cameraRunning && wantsVideo && !pausedByMac),
                // Another paired Mac has the camera; this one gets it when that Mac lets go.
                "busy" to o?.name?.takeIf { o !== this && wantsVideo },
                "camera" to s.camera,
                "cameras" to s.cameras.toJsonArray(),
                "width" to s.resolution?.width,
                "height" to s.resolution?.height,
                "fps" to 30,
                "note" to s.cameraNote,
                "battery" to battery,
                "thermal" to thermalName(thermal),
                "limited" to s.limited,
                "torch" to s.torch.takeIf { s.torchMax > 0 },
                "mic" to micPermission(),
            ))
        }

        private val listener = object : SignalingConnection.Listener {
            override fun onPaired(conn: SignalingConnection, macName: String, secret: ByteArray) {
                if (conn !== this@MacLink.conn) return
                val p = pending ?: return
                // The Mac id comes from the QR code (seen by the user), not from the unauthenticated reply.
                val m = TrustedMac(p.macId, macName, listOf(conn.host) + p.hosts.filter { it != conn.host }, conn.port, secret)
                store.save(m)
                mac = m
                pending = null
                publish()
            }

            override fun onAuthenticated(conn: SignalingConnection, macName: String?) {
                if (conn !== this@MacLink.conn) return
                failures = 0
                everAuthenticated = true
                authRejected = false
                wantsVideo = false
                note = null
                if (macName != null && mac != null && macName != mac?.name) mac = mac?.copy(name = macName)
                store.updateAddress(macId, conn.host, conn.port)
                publish()
                sendState()
                // The Mac answers auth with start/idle/stop. An older Mac sends nothing: behave as "start".
                controlFallbackTask?.cancel(false)
                controlFallbackTask = exec.schedule({
                    if (this@MacLink.conn === conn && conn.isAuthenticated && !pausedByMac && !wantsVideo) {
                        Log.i(TAG, "no control from $name; starting video")
                        requestVideo(this@MacLink)
                    }
                }, 3, TimeUnit.SECONDS)
            }

            override fun onSignal(conn: SignalingConnection, body: JSONObject) {
                if (conn !== this@MacLink.conn) return
                val link = this@MacLink
                when (body.optString("t")) {
                    "answer" -> if (peerLink === link) pc?.setRemoteDescription(LoggingSdpObserver("setRemote"),
                        SessionDescription(SessionDescription.Type.ANSWER, LanAddress.filterSdp(body.getString("sdp"))))
                    "revoked" -> {
                        store.remove(macId)
                        note = "$name no longer trusts this phone. Scan a new code."
                        notice = note
                        removeLink(link)
                    }
                    "replaced" -> {
                        val other = body.optString("note").ifBlank { "Another phone" }
                        note = "$other is now the camera on $name. Tap Reconnect to take over."
                        dormant = true
                        close(bye = false)
                        releaseVideo(link)
                        publish()
                    }
                    "candidate" -> {
                        val c = body.getString("candidate")
                        // LAN only: never send media toward an address off the local network.
                        if (peerLink !== link) return
                        if (LanAddress.isLocalCandidate(c)) pc?.addIceCandidate(IceCandidate(body.optString("sdpMid"), body.optInt("sdpMLineIndex"), c))
                        else Log.w(TAG, "ignoring non-local candidate")
                    }
                    "control" -> {
                        controlFallbackTask?.cancel(false)
                        when (body.optString("action")) {
                            "stop" -> {
                                pausedByMac = true
                                releaseVideo(link)
                                sendState()
                                publish()
                            }
                            "idle" -> {
                                pausedByMac = false
                                releaseVideo(link)
                                sendState()
                                publish()
                            }
                            "start" -> {
                                pausedByMac = false
                                link.wantsMic = body.optBoolean("mic", false)
                                requestVideo(link)
                            }
                            // "Use on this Mac" in the Mac's menu: same as Use here on the phone.
                            "takeover" -> {
                                pausedByMac = false
                                if (!arbiter.isWaiting(link.macId)) requestVideo(link)
                                if (arbiter.isWaiting(link.macId)) moveCameraTo(link.macId)
                            }
                            // The camera is shared: only the Mac that has it (or any, while none does) may switch lenses.
                            "camera" -> if (owner == null || owner === link) applyCamera(body.optString("camera"))
                            // The phone-wide light setting, same as the switch on the phone.
                            "torch" -> if (body.has("torch")) setTorch(body.optBoolean("torch"), _state.value.torchLevel)
                        }
                    }
                }
            }

            override fun onRejected(conn: SignalingConnection, code: String, message: String) {
                Log.w(TAG, "$name rejected $code: $message")
                val link = this@MacLink
                when (code) {
                    "unknown_device", "revoked", "bad_proof", "mac_identity" -> {
                        // Unauthenticated: could be a spoofed service on the LAN. Ask the user to re-pair but keep the
                        // pairing and keep retrying slowly; only a sealed "revoked" from the real Mac deletes it.
                        authRejected = true
                        note = message.ifBlank { "$name no longer trusts this phone. Scan a new code." }
                        releaseVideo(link)
                        publish()
                    }
                    "token_invalid", "token_expired", "token_used" -> {
                        pending = null
                        val existing = store.load(macId)
                        if (existing != null) {
                            // Still trusted by this Mac: ignore the stale code and reconnect normally (onClosed moves on).
                            mac = existing
                            notice = "$message Using the existing pairing with $name."
                            publish()
                        } else {
                            notice = message
                            removeLink(link)
                        }
                    }
                    else -> {
                        note = message
                        dormant = true
                        close(bye = false)
                        releaseVideo(link)
                        publish()
                    }
                }
            }

            override fun onClosed(conn: SignalingConnection, reason: String) {
                if (conn !== this@MacLink.conn || stopped) return
                Log.i(TAG, "connection to $name at ${conn.host} closed: $reason")
                this@MacLink.conn = null
                if (conn.wasAuthenticated && !authRejected) {
                    controlFallbackTask?.cancel(false)
                    releaseVideo(this@MacLink, keepCameraWarm = true)
                    note = "Lost $name. Reconnecting…"
                    publish()
                    reconnectSoon(500)
                } else {
                    // Try the next address right away; the backoff applies once all addresses failed.
                    val round = attempt
                    exec.schedule({ if (round == attempt && idle()) tryCandidate() }, 200, TimeUnit.MILLISECONDS)
                }
            }
        }
    }

    private open class LoggingSdpObserver(val what: String) : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String?) { Log.e(TAG, "$what failed: $error") }
        override fun onSetFailure(error: String?) { Log.e(TAG, "$what failed: $error") }
    }

    private fun thermalName(status: Int) = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> "none"
        PowerManager.THERMAL_STATUS_LIGHT -> "light"
        PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
        PowerManager.THERMAL_STATUS_SEVERE -> "severe"
        PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
        PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
        PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
        else -> "none"
    }

    companion object {
        private const val TAG = "PhoneCam"
    }
}
