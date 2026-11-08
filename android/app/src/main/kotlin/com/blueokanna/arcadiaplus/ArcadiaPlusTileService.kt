package com.blueokanna.arcadiaplus

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class ArcadiaPlusTileService : TileService() {
    companion object {
        const val ACTION_CONNECT = "com.blueokanna.arcadiaplus.CONNECT"
        const val ACTION_STATE_CHANGED = "com.blueokanna.arcadiaplus.VPN_STATE_CHANGED"
    }

    private var listening = false
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { updateTile() }
    }

    
    override fun onStartListening() {
        super.onStartListening()
        if (!listening) {
            ContextCompat.registerReceiver(this, stateReceiver,
                IntentFilter(ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
            listening = true
        }
        updateTile()
    }
    
    override fun onStopListening() {
        if (listening) {
            unregisterReceiver(stateReceiver)
            listening = false
        }
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        
        if (ArcadiaPlusVpnService.isRunning) {
            val intent = Intent(this, ArcadiaPlusVpnService::class.java).apply {
                action = ArcadiaPlusVpnService.ACTION_STOP
            }
            startService(intent)
        } else {
            val intent = Intent(this, MainActivity::class.java).apply {
                action = ACTION_CONNECT
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val pendingIntent = PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                startActivityAndCollapse(pendingIntent)
            } else {
                startActivityAndCollapseCompat(intent)
            }
        }
        
        updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    @Suppress("DEPRECATION")
    private fun startActivityAndCollapseCompat(intent: Intent) {
        startActivityAndCollapse(intent)
    }
    
    private fun updateTile() {
        val tile = qsTile ?: return
        
        if (ArcadiaPlusVpnService.isRunning) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = "ArcadiaPlus"
            tile.contentDescription = "VPN Connected"
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "ArcadiaPlus"
            tile.contentDescription = "VPN Disconnected"
        }
        
        tile.updateTile()
    }
}
