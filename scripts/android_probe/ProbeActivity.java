package org.arcadia.validation;

import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.content.Intent;
import android.view.Gravity;
import android.widget.TextView;

/** Keeps an OEM task freezer from suspending the diagnostic client mid-request. */
public final class ProbeActivity extends Activity {
    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        Intent service = new Intent(this, ProbeService.class);
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(service);
        else startService(service);
        TextView status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setPadding(32, 32, 32, 32);
        status.setTextSize(20);
        status.setText("ArcadiaPlus VPN verification\nDNS and HTTPS requests are running.\nThis screen closes when the test finishes.");
        setContentView(status);
    }
}
