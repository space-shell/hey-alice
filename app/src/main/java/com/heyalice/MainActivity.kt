package com.heyalice

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Minimal glanceable status UI (plan §4). Dark, dim-friendly. M1: gateway
 * URL + connect, live state/transcript, latency numbers, D1.3 AEC test.
 * Voice-first — this screen is not a launcher.
 */
class MainActivity : ComponentActivity() {

    private val micPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) Toast.makeText(this,
                "RECORD_AUDIO denied — voice loop will not work", Toast.LENGTH_LONG).show()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED) micPermission.launch(
                Manifest.permission.RECORD_AUDIO)
        // Service-first (plan ADR-3): the service owns the loop; the UI observes.
        startForegroundService(Intent(this, AliceService::class.java))
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                StatusScreen()
            }
        }
    }
}

@Composable
private fun StatusScreen() {
    val connection by AliceRuntime.connection.collectAsState()
    val gatewayInfo by AliceRuntime.gatewayInfo.collectAsState()
    val state by AliceRuntime.state.collectAsState()
    val partial by AliceRuntime.partial.collectAsState()
    val finalText by AliceRuntime.finalText.collectAsState()
    val latency by AliceRuntime.latency.collectAsState()
    val suError by AliceRuntime.suError.collectAsState()
    val aecStatus by AliceRuntime.aecStatus.collectAsState()

    val ctx = androidx.compose.ui.platform.LocalContext.current
    var url by remember {
        mutableStateOf(ctx.getSharedPreferences("alice", 0)
            .getString("gateway", AliceRuntime.DEFAULT_URL) ?: AliceRuntime.DEFAULT_URL)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0A0A)),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("Alice", fontSize = 32.sp, color = Color(0xFFEDEDED))
            Text(connection, fontSize = 14.sp, color = Color(0xFF8A8A8A))
            if (gatewayInfo.isNotEmpty())
                Text(gatewayInfo, fontSize = 12.sp, color = Color(0xFF6A6A6A),
                    fontFamily = FontFamily.Monospace)

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()) {
                OutlinedTextField(
                    value = url, onValueChange = { url = it },
                    label = { Text("gateway") },
                    modifier = Modifier.weight(1f),
                    singleLine = true)
                Button(onClick = {
                    android.util.Log.i("AliceUI", "connect clicked: $url")
                    ctx.getSharedPreferences("alice", 0).edit()
                        .putString("gateway", url).apply()
                    AliceRuntime.connectGateway(url)
                }) { Text("Connect") }
            }

            Text("state: $state", fontSize = 16.sp, color = Color(0xFFD0D0D0))
            if (partial.isNotEmpty())
                Text("… $partial", fontSize = 16.sp, color = Color(0xFF9A9A9A))
            Text(
                if (finalText.isEmpty()) "hold the side key to talk" else finalText,
                fontSize = 20.sp, color = Color(0xFFEDEDED))

            latency?.let {
                Text(
                    "release→final ${it.releaseMs} ms (budget 500)  |  " +
                        "release→tts ${it.ttsFirstMs} ms  |  →play ${it.playMs} ms\n" +
                        "server stt ${it.sttServerMs} ms  |  server tts ${it.ttsServerMs} ms",
                    fontSize = 12.sp, fontFamily = FontFamily.Monospace,
                    color = Color(0xFF7A9A7A))
            }

            suError?.let {
                Text(it, fontSize = 12.sp, color = Color(0xFF9A5A5A))
            }

            Button(onClick = { AliceRuntime.runAecTest() }) { Text("D1.3 AEC test") }
            aecStatus?.let {
                Text(it, fontSize = 11.sp, fontFamily = FontFamily.Monospace,
                    color = Color(0xFF7A7A9A))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}
