package com.zanghi.phonecam

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {
    private var hasCamera by mutableStateOf(false)
    private var scanning by mutableStateOf(false)
    private var scanError by mutableStateOf<String?>(null)
    /** Pairing waiting for the user's OK. Any app or web page can open a phonecam:// link, so never pair silently. */
    private var pendingPairing by mutableStateOf<Pair<String, PairingPayload>?>(null)
    private var confirmForget by mutableStateOf<String?>(null)

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        hasCamera = granted()
        if (hasCamera) autoStart()
        StreamService.refresh(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hasCamera = granted()
        setContent {
            PhoneCamTheme {
                AppScreen(
                    hasCamera = hasCamera,
                    scanning = scanning,
                    scanError = scanError,
                    onRequestPermission = { requestPermissions() },
                    onScanned = { onPairingText(it) },
                    onScanAgain = { scanError = null; scanning = true },
                    onCancelScan = { scanning = false },
                    onStart = { StreamService.start(this) },
                    onStop = { StreamService.stop(this) },
                    onForget = { confirmForget = it },
                )
                pendingPairing?.let { (text, p) -> PairConfirm(text, p) }
                confirmForget?.let { ForgetConfirm(it) }
            }
        }
        handleIntent(intent)
        if (!hasCamera) requestPermissions() else { autoStart(); askMicOnce() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent?.dataString?.takeIf { it.startsWith("phonecam://") }?.let { onPairingText(it) }
    }

    private fun granted() = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestPermissions() {
        val list = mutableListOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) list += Manifest.permission.POST_NOTIFICATIONS
        permissions.launch(list.toTypedArray())
    }

    /** Installs from before the phone microphone have the camera but were never asked for the mic: ask once. */
    private fun askMicOnce() {
        val prefs = getSharedPreferences("settings", MODE_PRIVATE)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED ||
            prefs.getBoolean("askedMic", false)) return
        prefs.edit().putBoolean("askedMic", true).apply()
        permissions.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
    }

    /** Paired already: start streaming as soon as the app opens. Otherwise show the scanner. */
    private fun autoStart() {
        if (PairingStore(this).loadAll().isNotEmpty()) {
            if (StreamService.controller.value == null) StreamService.start(this)
        } else {
            scanning = true
        }
    }

    private fun onPairingText(text: String) {
        val payload = PairingPayload.parse(text)
        if (payload == null) {
            scanError = "That isn’t a PhoneCam pairing code."
            return
        }
        scanning = false
        scanError = null
        pendingPairing = text to payload
    }

    private fun confirmPairing(text: String) {
        pendingPairing = null
        if (!granted()) { requestPermissions(); return }
        // Adds the Mac; the phone stays connected to the Macs it already trusts.
        StreamService.start(this, text)
    }

    @androidx.compose.runtime.Composable
    private fun PairConfirm(text: String, p: PairingPayload) {
        val paired = PairingStore(this).loadAll()
        val replaces = when {
            paired.any { it.macId == p.macId } -> " This renews the existing pairing."
            paired.isNotEmpty() -> " It stays paired with ${paired.joinToString(" and ") { it.name }} too; the camera goes to whichever Mac uses it first."
            else -> ""
        }
        AlertDialog(
            onDismissRequest = { pendingPairing = null },
            title = { Text("Pair with ${p.macName}?") },
            text = { Text("${p.hosts.joinToString()} · This phone will stream its camera to that Mac.$replaces") },
            confirmButton = { TextButton(onClick = { confirmPairing(text) }) { Text("Pair") } },
            dismissButton = { TextButton(onClick = { pendingPairing = null }) { Text("Cancel") } },
        )
    }

    @androidx.compose.runtime.Composable
    private fun ForgetConfirm(macId: String) {
        val name = PairingStore(this).load(macId)?.name ?: "this Mac"
        AlertDialog(
            onDismissRequest = { confirmForget = null },
            title = { Text("Forget $name?") },
            text = { Text("You'll need to scan a new code on that Mac to stream to it again.") },
            confirmButton = { TextButton(onClick = { confirmForget = null; forget(macId) }) { Text("Forget") } },
            dismissButton = { TextButton(onClick = { confirmForget = null }) { Text("Cancel") } },
        )
    }

    private fun forget(macId: String) {
        val store = PairingStore(this)
        val others = store.loadAll().filter { it.macId != macId }
        StreamService.controller.value?.forgetMac(macId) ?: store.remove(macId)
        if (others.isEmpty()) {
            StreamService.stop(this)
            scanning = true
        }
    }
}
