package com.zanghi.phonecam

import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import java.util.concurrent.Executors

/** Flight Strip tokens. Alert orange only marks something the user must act on. */
object Z {
    val page = Color(0xFF13171B)
    val well = Color(0xFF0D1013)
    val ink1 = Color(0xFFEEEAE0)
    val ink2 = Color(0xFFC4C0B4)
    val ink3 = Color(0xFFA4A39B)
    val pencil = Color(0xFFECDCB8)
    val alert = Color(0xFFF0703F)
    val rule = Color(0x26EEEAE0)
}

@Composable
fun PhoneCamTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            background = Z.page, surface = Z.page, onBackground = Z.ink1, onSurface = Z.ink1,
            primary = Z.ink1, onPrimary = Z.page, secondaryContainer = Z.ink3, onSecondaryContainer = Z.page,
            outline = Z.ink3,
        ),
        content = content,
    )
}

@Composable
fun AppScreen(
    hasCamera: Boolean,
    scanning: Boolean,
    scanError: String?,
    onRequestPermission: () -> Unit,
    onScanned: (String) -> Unit,
    onScanAgain: () -> Unit,
    onCancelScan: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onForget: (String) -> Unit,
) {
    val controller by StreamService.controller.collectAsState()
    androidx.compose.runtime.CompositionLocalProvider(LocalContentColor provides Z.ink1) { Box(Modifier.fillMaxSize().background(Z.page).safeDrawingPadding()) {
        when {
            !hasCamera -> Message(
                title = "Camera access needed",
                body = "PhoneCam sends this phone’s camera to your Mac over Wi-Fi. Video stays on your local network.",
                action = "Allow camera" to onRequestPermission,
                needsUser = true,
            )
            scanning -> ScanScreen(scanError, onScanned, onCancel = onCancelScan)
            controller == null -> {
                val ctx = LocalContext.current
                val paired = remember(controller) { PairingStore(ctx).loadAll() }
                if (paired.isNotEmpty()) Message("Stopped", "Paired with ${paired.joinToString(" and ") { it.name }}.", "Start" to onStart,
                    secondary = "Pair another Mac" to onScanAgain)
                else Message("Pair with your Mac", "Open PhoneCam on your Mac and scan the code in its menu.", "Scan code" to onScanAgain, needsUser = true)
            }
            else -> StreamScreen(controller!!, onStop, onForget, onScanAgain)
        }
    } }
}

@Composable
private fun Message(title: String, body: String, action: Pair<String, () -> Unit>, secondary: Pair<String, () -> Unit>? = null, needsUser: Boolean = false) {
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center) {
        Row {
            if (needsUser) Box(Modifier.width(3.dp).height(48.dp).background(Z.alert))
            Column(Modifier.padding(start = if (needsUser) 12.dp else 0.dp)) {
                Text(title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Z.ink1)
                Spacer(Modifier.height(6.dp))
                Text(body, fontSize = 15.sp, color = Z.ink2)
            }
        }
        Spacer(Modifier.height(24.dp))
        Button(onClick = action.second, shape = MaterialTheme.shapes.small) { Text(action.first) }
        secondary?.let { TextButton(onClick = it.second) { Text(it.first, color = Z.ink2) } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StreamScreen(controller: StreamController, onStop: () -> Unit, onForget: (String) -> Unit, onScan: () -> Unit) {
    val s by controller.state.collectAsState()
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("PhoneCam", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(statusLabel(s), fontSize = 14.sp, color = if (s.phase == Phase.NEEDS_PAIRING) Z.alert else Z.ink2)
        }
        Box(Modifier.fillMaxWidth().weight(1f).background(Z.well), contentAlignment = Alignment.Center) {
            when (s.phase) {
                Phase.PAUSED -> Text("Paused from the Mac", color = Z.ink3)
                Phase.STANDBY -> Text("Camera off until an app on ${s.macName ?: "the Mac"} uses Phone Camera", color = Z.ink3,
                    modifier = Modifier.padding(24.dp))
                Phase.NEEDS_PAIRING, Phase.IDLE -> Text("Not streaming", color = Z.ink3)
                else -> LocalPreview(controller, mirror = s.cameras.firstOrNull { it.id == s.camera }?.isFront == true)
            }
        }
        HorizontalDivider(color = Z.rule)
        Column(Modifier.padding(16.dp)) {
            val detail = listOfNotNull(
                s.message,
                s.cameraNote,
                s.resolution?.let { "${maxOf(it.width, it.height)}×${minOf(it.width, it.height)} · ${s.fps} fps" }?.takeIf { s.phase == Phase.LIVE },
                when (s.limited) { "network" -> "Lowered to 720p: weak Wi-Fi"; "thermal" -> "Lowered to 720p: phone is warm"; else -> null }
                    ?.takeIf { s.phase == Phase.LIVE },
                "Starts when an app on ${s.macName ?: "your Mac"} uses Phone Camera.".takeIf { s.phase == Phase.STANDBY },
            )
            detail.forEach { Text(it, fontSize = 13.sp, color = Z.ink2) }
            if (s.phase == Phase.NEEDS_PAIRING) {
                Spacer(Modifier.height(12.dp))
                Button(onClick = onScan, shape = MaterialTheme.shapes.small) { Text("Scan new code") }
            } else if (s.cameras.size > 1) {
                Spacer(Modifier.height(12.dp))
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    s.cameras.forEachIndexed { i, cam ->
                        SegmentedButton(
                            selected = cam.id == s.camera,
                            onClick = { controller.selectCamera(cam.id) },
                            shape = SegmentedButtonDefaults.itemShape(i, s.cameras.size),
                            colors = SegmentedButtonDefaults.colors(activeContainerColor = Z.ink3, activeContentColor = Z.page),
                        ) { Text(cam.label, fontSize = 12.sp, maxLines = 1) }
                    }
                }
            }
            if (s.phase != Phase.NEEDS_PAIRING && s.torchMax > 0) TorchSetting(s, controller)
            if (s.macs.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                HorizontalDivider(color = Z.rule)
                s.macs.forEach { m -> MacRow(m, onUseHere = { controller.useOn(m.macId) }, onReconnect = { controller.reconnectMac(m.macId) },
                    onForget = { onForget(m.macId) }) }
            }
            if (s.phase != Phase.NEEDS_PAIRING) {
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (s.phase == Phase.IDLE) Button(onClick = { controller.start(null) }, shape = MaterialTheme.shapes.small) { Text("Start") }
                    else OutlinedButton(onClick = onStop, shape = MaterialTheme.shapes.small) { Text("Stop") }
                    // The scanner needs the camera, so not while it streams.
                    TextButton(onClick = onScan, enabled = !s.streaming) { Text("Pair another Mac", color = if (s.streaming) Z.ink3 else Z.ink2) }
                }
            }
            Text("Keeps streaming with the screen locked. Hold the phone sideways for a full-width picture.",
                fontSize = 12.sp, color = Z.ink3, modifier = Modifier.padding(top = 8.dp))
        }
    }
}

/** The back flash as an on-air light: lit only while video is live on a Mac. */
@Composable
private fun TorchSetting(s: UiState, controller: StreamController) {
    val backStreaming = s.cameras.firstOrNull { it.id == s.camera }?.isFront != true
    Spacer(Modifier.height(12.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Light while live", fontSize = 14.sp)
            Text(if (backStreaming) "Flash faces you while it streams" else "Flash is on the back of the phone",
                fontSize = 12.sp, color = Z.ink2)
        }
        Switch(checked = s.torch, onCheckedChange = { controller.setTorch(it, s.torchLevel) },
            colors = SwitchDefaults.colors(checkedTrackColor = Z.ink3, checkedThumbColor = Z.page))
    }
    if (!s.torch || s.torchMax <= 1) return
    if (backStreaming && !Torch.adjustableWhileStreaming) {
        Text("Brightness can’t be dimmed while the back camera streams on Android 14 (needs Android 15). Front camera: dimmable.",
            fontSize = 12.sp, color = Z.ink3)
        return
    }
    var level by remember(s.torchLevel) { mutableFloatStateOf(s.torchLevel.toFloat()) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Brightness", fontSize = 12.sp, color = Z.ink2, modifier = Modifier.width(76.dp))
        Slider(value = level, onValueChange = { level = it; controller.setTorch(true, it.toInt()) },
            valueRange = 1f..s.torchMax.toFloat(), modifier = Modifier.weight(1f),
            colors = SliderDefaults.colors(thumbColor = Z.ink1, activeTrackColor = Z.ink2, inactiveTrackColor = Z.rule))
    }
}

@Composable
private fun MacRow(m: MacStatus, onUseHere: () -> Unit, onReconnect: () -> Unit, onForget: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(m.name, fontSize = 14.sp, fontWeight = if (m.live) FontWeight.SemiBold else FontWeight.Normal)
            Text(m.status, fontSize = 12.sp, color = if (m.needsPairing) Z.alert else Z.ink2)
        }
        if (m.waiting) TextButton(onClick = onUseHere) { Text("Use here", color = Z.ink1) }
        if (m.stopped) TextButton(onClick = onReconnect) { Text("Reconnect", color = Z.ink1) }
        TextButton(onClick = onForget) { Text("Forget", color = Z.ink3) }
    }
}

private fun statusLabel(s: UiState) = when (s.phase) {
    Phase.LIVE -> "Live on ${s.macName ?: "Mac"}"
    Phase.CONNECTING -> "Connecting…"
    Phase.STANDBY -> "Ready"
    Phase.RECONNECTING -> "Reconnecting…"
    Phase.PAUSED -> "Paused"
    Phase.NEEDS_PAIRING -> "Pair again"
    Phase.IDLE -> "Stopped"
}

@Composable
private fun LocalPreview(controller: StreamController, mirror: Boolean) {
    val track = controller.track
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            SurfaceViewRenderer(ctx).apply {
                init(controller.eglBase.eglBaseContext, null)
                setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                setEnableHardwareScaler(true)
                track.addSink(this)
            }
        },
        update = { it.setMirror(mirror) },
        onRelease = {
            track.removeSink(it)
            it.release()
        },
    )
}

@Composable
private fun ScanScreen(error: String?, onScanned: (String) -> Unit, onCancel: () -> Unit) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val context = LocalContext.current
    val executor = remember { Executors.newSingleThreadExecutor() }
    val scanner = remember { BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()) }
    // Owned use cases only: unbindAll() would also take the camera away from a stream to another Mac.
    val bound = remember { mutableListOf<androidx.camera.core.UseCase>() }
    DisposableEffect(Unit) {
        val controller = StreamService.controller.value
        controller?.setScanning(true)
        onDispose { scanner.close(); executor.shutdown(); controller?.setScanning(false) }
    }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(16.dp)) {
            Text("Scan the code on your Mac", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            Text("Click PhoneCam in the Mac menu bar to show it. Codes expire after 2 minutes and work once.", fontSize = 14.sp, color = Z.ink2)
            error?.let { Text(it, fontSize = 14.sp, color = Z.ink1, modifier = Modifier.padding(top = 8.dp)) }
        }
        AndroidView(
            modifier = Modifier.fillMaxWidth().aspectRatio(3f / 4f),
            factory = { ctx ->
                val view = PreviewView(ctx)
                val future = ProcessCameraProvider.getInstance(ctx)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    val analysis = ImageAnalysis.Builder()
                        .setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(
                            ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build())
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                    var done = false
                    analysis.setAnalyzer(executor) { proxy ->
                        val media = proxy.image
                        if (media == null || done) { proxy.close(); return@setAnalyzer }
                        scanner.process(InputImage.fromMediaImage(media, proxy.imageInfo.rotationDegrees))
                            .addOnSuccessListener { codes ->
                                val text = codes.firstNotNullOfOrNull { it.rawValue?.takeIf { v -> v.startsWith("phonecam://") } }
                                if (text != null && !done) {
                                    done = true
                                    provider.unbind(*bound.toTypedArray())
                                    onScanned(text)
                                }
                            }
                            .addOnCompleteListener { proxy.close() }
                    }
                    bound += listOf(preview, analysis)
                    provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }, ContextCompat.getMainExecutor(ctx))
                view
            },
            onRelease = { ProcessCameraProvider.getInstance(context).get().unbind(*bound.toTypedArray()) },
        )
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onCancel, modifier = Modifier.padding(16.dp)) { Text("Cancel", color = Z.ink2) }
    }
}

