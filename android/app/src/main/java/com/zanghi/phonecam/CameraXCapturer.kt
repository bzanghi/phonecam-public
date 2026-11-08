package com.zanghi.phonecam

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Matrix
import android.os.Build
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import org.webrtc.CapturerObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoCapturer
import org.webrtc.VideoFrame
import kotlin.math.roundToInt

/**
 * WebRTC VideoCapturer backed by CameraX. CameraX renders into WebRTC's SurfaceTexture, so frames stay on the GPU
 * and go straight to the hardware encoder. Lenses are zoom presets on the logical camera (Pixel exposes ultra-wide
 * and telephoto that way). Frame rotation follows the physical device orientation, even with the screen locked.
 */
class CameraXCapturer(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val events: Events,
) : VideoCapturer {
    interface Events {
        fun onCameraState(open: Boolean, error: String?)
        fun onResolution(size: Size)
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var helper: SurfaceTextureHelper
    private lateinit var observer: CapturerObserver
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    @Volatile private var sensorOrientation = 90
    @Volatile private var front = false
    @Volatile private var deviceOrientation = 0
    @Volatile private var running = false
    private var target = Size(1920, 1080)
    private var fps = 30
    var option: CameraOption? = null
        private set
    /** Live-indicator torch level wanted by the controller (0 = off). Main thread. */
    private var torchLevel = 0
    /** The torch is on through CameraManager (front camera streaming, so the back flash is free). */
    private var managerTorchOn = false
    /** Recovery: rebinds after a camera error CameraX won't retry itself (fatal, stream config) or a frame stall.
     *  Backoff doubles per failed attempt up to [MAX_BACKOFF_MS]; it resets once the camera has stayed open. Main thread. */
    private var recoverAttempts = 0
    private var openedAt = 0L
    @Volatile private var lastFrameAt = 0L
    private val recover = Runnable { if (running) { Log.w(TAG, "recovery: rebinding (attempt $recoverAttempts)"); bind() } }
    private val stable = Runnable { recoverAttempts = 0 }
    private val watchdog = object : Runnable {
        override fun run() {
            if (!running) return
            val open = camera?.cameraInfo?.cameraState?.value?.type == CameraState.Type.OPEN
            val since = maxOf(openedAt, lastFrameAt)
            if (open && openedAt > 0 && now() - since > STALL_MS && !main.hasCallbacks(recover)) {
                Log.w(TAG, "recovery: no frames for ${now() - since} ms")
                scheduleRecovery("Camera stalled")
            }
            main.postDelayed(this, 2_000)
        }
    }

    private val orientationListener = object : OrientationEventListener(context) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation == ORIENTATION_UNKNOWN) return
            // Hysteresis: only switch buckets once clearly past the 45° boundary.
            val bucket = ((orientation + 45) / 90 % 4) * 90
            val diff = Math.abs(((orientation - deviceOrientation + 540) % 360) - 180)
            if (bucket != deviceOrientation && diff > 55) deviceOrientation = bucket
        }
    }

    override fun initialize(helper: SurfaceTextureHelper, context: Context, observer: CapturerObserver) {
        this.helper = helper
        this.observer = observer
    }

    override fun startCapture(width: Int, height: Int, framerate: Int) {
        target = Size(width, height)
        fps = framerate
        running = true
        orientationListener.enable()
        helper.startListening { frame -> onFrame(frame) }
        observer.onCapturerStarted(true)
        main.post {
            recoverAttempts = 0
            bind()
            main.removeCallbacks(watchdog)
            main.postDelayed(watchdog, 2_000)
        }
    }

    override fun stopCapture() {
        running = false
        orientationListener.disable()
        val done = java.util.concurrent.CountDownLatch(1)
        main.post {
            main.removeCallbacks(recover)
            main.removeCallbacks(stable)
            main.removeCallbacks(watchdog)
            openedAt = 0
            setManagerTorch(0)
            provider?.unbindAll()
            camera = null
            done.countDown()
        }
        if (Looper.myLooper() != Looper.getMainLooper()) done.await(2, java.util.concurrent.TimeUnit.SECONDS)
        helper.stopListening()
        observer.onCapturerStopped()
    }

    override fun changeCaptureFormat(width: Int, height: Int, framerate: Int) {
        target = Size(width, height)
        fps = framerate
        main.post { bind() }
    }

    override fun dispose() {}

    /** Lights the back flash at [level] (1..[Torch.maxLevel]; 0 = off) while the camera runs. */
    fun setTorch(level: Int) = main.post {
        torchLevel = level
        applyTorch()
    }

    /** Streaming camera has the flash: torch through the capture session (CameraManager can't reach an open camera).
     *  Otherwise the back flash is idle and CameraManager drives it. Re-run whenever the camera opens. */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun applyTorch() {
        val level = if (running) torchLevel else 0
        val cam = camera
        if (cam != null && cam.cameraInfo.hasFlashUnit()) {
            setManagerTorch(0)
            if (cam.cameraInfo.cameraState.value?.type != CameraState.Type.OPEN) return
            cam.cameraControl.enableTorch(level > 0)
            val interop = Camera2CameraControl.from(cam.cameraControl)
            if (level > 0 && Torch.adjustableWhileStreaming) {
                interop.setCaptureRequestOptions(CaptureRequestOptions.Builder()
                    .setCaptureRequestOption(CaptureRequest.FLASH_STRENGTH_LEVEL, level.coerceIn(1, Torch.maxLevel(context))).build())
            } else interop.clearCaptureRequestOptions()
        } else if (cam != null || level == 0) setManagerTorch(level)
    }

    private fun setManagerTorch(level: Int) {
        if (level == 0 && !managerTorchOn) return
        val manager = context.getSystemService(CameraManager::class.java)
        val id = Torch.cameraId(context) ?: return
        try {
            if (level > 0) {
                if (Torch.adjustableIdle(context)) manager.turnOnTorchWithStrengthLevel(id, level.coerceIn(1, Torch.maxLevel(context)))
                else manager.setTorchMode(id, true)
                managerTorchOn = true
            } else {
                manager.setTorchMode(id, false)
                managerTorchOn = false
            }
        } catch (e: Exception) {
            Log.w(TAG, "torch $level failed", e)
        }
    }

    override fun isScreencast() = false

    fun select(option: CameraOption) {
        val sameCamera = this.option?.facing == option.facing
        this.option = option
        main.post {
            val cam = camera
            if (sameCamera && cam != null) cam.cameraControl.setZoomRatio(option.zoom) else if (running) bind()
        }
    }

    @OptIn(ExperimentalCamera2Interop::class)
    @SuppressLint("RestrictedApi")
    private fun bind() {
        if (!running) return
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (!running) return@addListener
            val p = future.get()
            provider = p
            val opt = option ?: return@addListener
            val selector = if (opt.isFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            val resolution = ResolutionSelector.Builder()
                .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                // 1080p preferred; the closest lower size (720p) is the fallback.
                .setResolutionStrategy(ResolutionStrategy(target, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                .build()
            val builder = Preview.Builder()
                .setResolutionSelector(resolution)
                .setTargetFrameRate(Range(fps, fps))
            // Lip-sync experiment (settings pref "latencyMode", set over adb): "preview" uses the viewfinder intent,
            // "fast" also asks for fast noise reduction and edges. Default: the video-record tuning below.
            val mode = context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString("latencyMode", "default")
            Log.i(TAG, "capture latency mode $mode")
            // Video-style focus (smooth, no photo hunting) and the video-record 3A tuning.
            val ext = Camera2Interop.Extender(builder)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                .setCaptureRequestOption(CaptureRequest.CONTROL_CAPTURE_INTENT,
                    if (mode == "default") CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD else CaptureRequest.CONTROL_CAPTURE_INTENT_PREVIEW)
                // The video-record intent turns electronic stabilization on (seen on the Pixel 6 Pro). On a fixed mount it
                // only crops and heats the phone, which then steps down to 720p and 24 fps; optical stabilization stays.
                .setCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF)
            if (mode == "fast") {
                ext.setCaptureRequestOption(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_FAST)
                    .setCaptureRequestOption(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_FAST)
            }
            val preview = builder.build()
            preview.setSurfaceProvider(ContextCompat.getMainExecutor(context)) { request ->
                val size = request.resolution
                helper.setTextureSize(size.width, size.height)
                val surface = Surface(helper.surfaceTexture)
                events.onResolution(size)
                request.provideSurface(surface, ContextCompat.getMainExecutor(context)) { surface.release() }
            }
            try {
                main.removeCallbacks(recover)
                openedAt = 0
                camera?.cameraInfo?.cameraState?.removeObservers(lifecycleOwner)
                setManagerTorch(0)
                p.unbindAll()
                val cam = p.bindToLifecycle(lifecycleOwner, selector, preview)
                camera = cam
                front = opt.isFront
                sensorOrientation = cam.cameraInfo.sensorRotationDegrees
                cam.cameraControl.setZoomRatio(opt.zoom)
                cam.cameraInfo.cameraState.removeObservers(lifecycleOwner)
                cam.cameraInfo.cameraState.observe(lifecycleOwner) { state ->
                    val code = state.error?.code
                    if (code != null) Log.w(TAG, "camera state ${state.type} error $code")
                    when {
                        state.type == CameraState.Type.OPEN -> {
                            if (openedAt == 0L) openedAt = now()
                            main.removeCallbacks(stable)
                            main.postDelayed(stable, STABLE_MS)
                            events.onCameraState(true, state.error?.let { describe(it.code) })
                            applyTorch()
                        }
                        // CameraX retries the recoverable errors itself (PENDING_OPEN); a CLOSED camera with an error is
                        // given up on (fatal, stream config, disabled), so rebind with backoff while capture is wanted.
                        state.type == CameraState.Type.CLOSED && code != null && running -> scheduleRecovery(describe(code))
                        else -> events.onCameraState(false, state.error?.let { describe(it.code) })
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "bind failed", e)
                scheduleRecovery("Camera unavailable: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Reports [reason] and rebinds after the current backoff. Main thread. */
    private fun scheduleRecovery(reason: String) {
        main.removeCallbacks(stable)
        main.removeCallbacks(recover)
        openedAt = 0
        val delay = minOf(MAX_BACKOFF_MS, 1_000L shl minOf(recoverAttempts, 5))
        recoverAttempts++
        Log.w(TAG, "recovery: $reason; retry in $delay ms")
        events.onCameraState(false, "$reason, restarting in ${delay / 1000} s")
        main.postDelayed(recover, delay)
    }

    private fun now() = android.os.SystemClock.elapsedRealtime()

    private fun describe(code: Int) = when (code) {
        CameraState.ERROR_CAMERA_IN_USE, CameraState.ERROR_MAX_CAMERAS_IN_USE -> "Camera in use by another app"
        CameraState.ERROR_CAMERA_DISABLED -> "Camera disabled by device policy"
        CameraState.ERROR_DO_NOT_DISTURB_MODE_ENABLED -> "Camera blocked by Do Not Disturb"
        CameraState.ERROR_OTHER_RECOVERABLE_ERROR -> "Camera interrupted, retrying"
        CameraState.ERROR_CAMERA_FATAL_ERROR -> "Camera failed"
        CameraState.ERROR_STREAM_CONFIG -> "Camera setup failed"
        else -> "Camera error ($code)"
    }

    /** Same un-transform as WebRTC's Camera2Session: undo the SurfaceTexture's sensor rotation/mirroring and carry
     *  the rotation as frame metadata (sent to the Mac via the RTP video-orientation extension). */
    private fun onFrame(frame: VideoFrame) {
        lastFrameAt = now()
        val buffer = frame.buffer as TextureBufferImpl
        val m = Matrix()
        m.preTranslate(0.5f, 0.5f)
        if (front) m.preScale(-1f, 1f)
        m.preRotate(-sensorOrientation.toFloat())
        m.preTranslate(-0.5f, -0.5f)
        val modified = buffer.applyTransformMatrix(m, buffer.width, buffer.height)
        val d = deviceOrientation
        val rotation = (sensorOrientation + (if (front) -d else d) + 360) % 360
        val out = VideoFrame(modified, rotation, frame.timestampNs)
        observer.onFrameCaptured(out)
        out.release()
    }

    companion object {
        private const val TAG = "PhoneCamCapturer"
        private const val MAX_BACKOFF_MS = 30_000L
        /** Open this long without an error before the backoff resets. */
        private const val STABLE_MS = 30_000L
        /** Open with no frames this long counts as a stall. */
        private const val STALL_MS = 6_000L

        /** Lens presets the device actually supports. */
        fun availableOptions(context: Context): List<CameraOption> {
            val manager = context.getSystemService(CameraManager::class.java)
            val options = mutableListOf<CameraOption>()
            var hasBack = false
            var hasFront = false
            for (id in manager.cameraIdList) {
                val c = manager.getCameraCharacteristics(id)
                when (c.get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_BACK -> if (!hasBack) {
                        hasBack = true
                        val zoom = c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                        val minZoom = zoom?.lower ?: 1f
                        val maxZoom = zoom?.upper ?: 1f
                        if (minZoom < 0.9f) options += CameraOption("back-uw", "Back 0.5×", "back", maxOf(minZoom, 0.5f))
                        options += CameraOption("back", "Back 1×", "back", 1f)
                        teleRatio(manager, c)?.takeIf { it in 2..maxZoom.toInt() }?.let {
                            options += CameraOption("back-tele", "Back ${it}×", "back", it.toFloat())
                        }
                    }
                    CameraCharacteristics.LENS_FACING_FRONT -> if (!hasFront) {
                        hasFront = true
                        options += CameraOption("front", "Front", "front", 1f)
                    }
                }
            }
            // Back lenses first (wide to tele), front last.
            return options.sortedBy { if (it.isFront) 1 else 0 }
        }

        /** Telephoto magnification relative to the main camera: ratio of (focal length / sensor width), i.e. field of view. */
        private fun teleRatio(manager: CameraManager, logical: CameraCharacteristics): Int? {
            val scales = logical.physicalCameraIds.mapNotNull {
                try {
                    val c = manager.getCameraCharacteristics(it)
                    val f = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return@mapNotNull null
                    val w = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)?.width ?: return@mapNotNull null
                    f / w
                } catch (e: Exception) { null }
            }.sorted()
            if (scales.size < 3) return null
            return (scales.last() / scales[scales.size / 2]).roundToInt()
        }
    }
}

/** The back flash used as the live indicator. */
object Torch {
    /** Strength while the back camera streams needs CaptureRequest.FLASH_STRENGTH_LEVEL (Android 15). */
    val adjustableWhileStreaming get() = Build.VERSION.SDK_INT >= 35

    fun cameraId(context: Context): String? {
        val manager = context.getSystemService(CameraManager::class.java)
        return manager.cameraIdList.firstOrNull {
            val c = manager.getCameraCharacteristics(it)
            c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK &&
                c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        }
    }

    /** Brightness steps the flash supports; 1 = on/off only, 0 = no flash. */
    fun maxLevel(context: Context): Int {
        val id = cameraId(context) ?: return 0
        if (Build.VERSION.SDK_INT < 33) return 1
        val c = context.getSystemService(CameraManager::class.java).getCameraCharacteristics(id)
        return c.get(CameraCharacteristics.FLASH_INFO_STRENGTH_MAXIMUM_LEVEL) ?: 1
    }

    /** The phone's own flashlight brightness, a sensible starting level. */
    fun defaultLevel(context: Context): Int {
        val id = cameraId(context) ?: return 0
        if (Build.VERSION.SDK_INT < 33) return 1
        val c = context.getSystemService(CameraManager::class.java).getCameraCharacteristics(id)
        return c.get(CameraCharacteristics.FLASH_INFO_STRENGTH_DEFAULT_LEVEL) ?: 1
    }

    fun adjustableIdle(context: Context) = Build.VERSION.SDK_INT >= 33 && maxLevel(context) > 1
}
