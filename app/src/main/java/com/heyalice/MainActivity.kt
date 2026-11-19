package com.heyalice

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Minimal glanceable status UI (plan §4 "Minimal status UI").
 * Dark, dim-friendly. v1 shows: listening/running/done agent dots, live
 * transcript, error states. Voice-first — this screen is not a launcher.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                StatusScreen()
            }
        }
    }
}

@Composable
private fun StatusScreen() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0A0A0A)),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Alice", fontSize = 32.sp, color = Color(0xFFEDEDED))
            Spacer(Modifier.height(8.dp))
            Text(
                "idle — say \"Hey Alice\" or hold the side key",
                fontSize = 14.sp,
                color = Color(0xFF8A8A8A),
            )
        }
    }
}
