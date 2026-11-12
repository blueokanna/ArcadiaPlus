package org.arcadia.validation;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.Process;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;

/** Runs outside the VPN application's UID; platform TLS verification stays enabled. */
public final class NetworkProbe extends Instrumentation {
    private static final String[] HOSTS = {
        "jpushsc.m.jd.com", "pool.ntp.org", "github.com", "www.gstatic.com", "www.baidu.com"
    };
    private static final String[] TARGETS = {
        "https://github.com/", "https://www.gstatic.com/generate_204", "https://www.baidu.com/"
    };
    private final StringBuilder report = new StringBuilder();
    private Bundle options;

    @Override
    public void onCreate(Bundle arguments) {
        options = arguments == null ? new Bundle() : arguments;
        start();
    }

    private void emit(String line) {
        android.util.Log.i("ArcadiaVpnProbe", line);
        report.append(line).append('\n');
        Bundle status = new Bundle();
        status.putString("stream", line + "\n");
        sendStatus(0, status);
    }

    private static long elapsedMillis(long begin) {
        return (System.nanoTime() - begin) / 1_000_000;
    }

    private void requireVpn() throws Exception {
        ConnectivityManager manager = (ConnectivityManager)
                getContext().getSystemService(Context.CONNECTIVITY_SERVICE);
        Network network = manager.getActiveNetwork();
        NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
        LinkProperties links = manager.getLinkProperties(network);
        if (Process.myUid() < 10000 || capabilities == null
                || !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                || links == null
                || !links.getDnsServers().contains(InetAddress.getByName("198.18.0.2"))) {
            throw new Exception("Probe is not an ordinary app on the expected VPN network");
        }
        emit("VPN uid=" + Process.myUid() + " network=" + network
                + " interface=" + links.getInterfaceName() + " OK");
    }

    private boolean resolve(String host) {
        long begin = System.nanoTime();
        try {
            InetAddress[] addresses = InetAddress.getAllByName(host);
            if (addresses.length == 0) throw new Exception("No addresses");
            emit("DNS host=" + host + " count=" + addresses.length
                    + " ms=" + elapsedMillis(begin) + " OK");
            return true;
        } catch (Exception error) {
            emit("DNS host=" + host + " ms=" + elapsedMillis(begin) + " FAIL " + error);
            return false;
        }
    }

    private boolean request(String target) {
        HttpsURLConnection connection = null;
        long begin = System.nanoTime();
        long bytes = 0;
        String phase = "connect/headers";
        try {
            connection = (HttpsURLConnection) new URL(target).openConnection();
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(15000);
            connection.setUseCaches(false);
            connection.setRequestProperty("User-Agent", "ArcadiaPlus-Device-Validation/1.0");
            int code = connection.getResponseCode();
            int expected = target.endsWith("generate_204") ? 204 : 200;
            if (code != expected) {
                throw new Exception("Expected HTTP " + expected + ", received " + code);
            }
            phase = "response body";
            try (InputStream input = connection.getInputStream()) {
                byte[] buffer = new byte[16384];
                for (int count; (count = input.read(buffer)) != -1;) bytes += count;
            }
            emit("HTTPS url=" + target + " status=" + code + " bytes=" + bytes
                    + " ms=" + elapsedMillis(begin) + " cipher=" + connection.getCipherSuite() + " OK");
            return true;
        } catch (Exception error) {
            emit("HTTPS url=" + target + " ms=" + elapsedMillis(begin)
                    + " phase=" + phase + " bytes=" + bytes + " FAIL " + error);
            return false;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    @Override
    public void onStart() {
        int failed = 0;
        Activity foreground = null;
        try {
            foreground = startActivitySync(new Intent(getTargetContext(), ProbeActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            int delay = Math.max(0, Math.min(600, Integer.parseInt(options.getString("delay", "0"))));
            emit("READY delay_seconds=" + delay);
            if (delay > 0) Thread.sleep(delay * 1000L);
            requireVpn();
            int rounds = Math.max(1, Math.min(10, Integer.parseInt(options.getString("rounds", "1"))));
            for (int round = 0; round < rounds; round++) {
                emit("ROUND " + (round + 1));
                for (String host : HOSTS) {
                    if (!resolve(host)) failed++;
                }
                for (String target : TARGETS) {
                    if (!request(target)) failed++;
                }
                requireVpn();
            }
        } catch (Exception error) {
            failed++;
            emit("SETUP FAIL " + error);
        } finally {
            getTargetContext().stopService(new Intent(getTargetContext(), ProbeService.class));
            if (foreground != null) {
                Activity activity = foreground;
                runOnMainSync(activity::finish);
            }
        }
        emit("RESULT failures=" + failed);
        Bundle result = new Bundle();
        result.putString("report", report.toString());
        result.putInt("failures", failed);
        finish(failed == 0 ? Activity.RESULT_OK : Activity.RESULT_CANCELED, result);
    }
}
