package com.blueokanna.arcadia

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

class ArcadiaTileService : TileService() {
    
    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }
    
    override fun onClick() {
        super.onClick()
        
        if (ArcadiaVpnService.isRunning) {
            val intent = Intent(this, ArcadiaVpnService::class.java).apply {
                action = ArcadiaVpnService.ACTION_STOP
            }
            startService(intent)
        } else {
            // Starting the tunnel is driven by the Flutter engine (config,
            // rule sets, DNS), so the tile opens the app instead of inventing
            // a second startup path.
            val intent = Intent(this, MainActivity::class.java).apply {
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
        
        if (ArcadiaVpnService.isRunning) {
            tile.state = Tile.STATE_ACTIVE
            tile.label = "Arcadia"
            tile.contentDescription = "VPN 已连接"
        } else {
            tile.state = Tile.STATE_INACTIVE
            tile.label = "Arcadia"
            tile.contentDescription = "VPN 已断开"
        }
        
        tile.updateTile()
    }
}
