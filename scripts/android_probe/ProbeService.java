package org.arcadia.validation;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

/** Keeps the test client runnable while the phone is locked. */
public final class ProbeService extends Service {
    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager notifications = getSystemService(NotificationManager.class);
        String channel = "vpn-validation";
        Notification.Builder notification;
        if (Build.VERSION.SDK_INT >= 26) {
            notifications.createNotificationChannel(new NotificationChannel(channel,
                    "VPN verification", NotificationManager.IMPORTANCE_LOW));
            notification = new Notification.Builder(this, channel);
        } else {
            notification = new Notification.Builder(this);
        }
        startForeground(1, notification.setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle("Verifying ArcadiaPlus VPN")
                .setContentText("DNS and HTTPS checks are running")
                .setOngoing(true).build());
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
