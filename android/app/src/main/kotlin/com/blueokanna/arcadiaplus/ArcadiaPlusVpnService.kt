package com.blueokanna.arcadiaplus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ArcadiaPlusVpnService : VpnService() {

    // JNI methods for Rust bridge
    private external fun nativeInitRustBridge(): Boolean
    private external fun nativeClearRustBridge()
    private external fun nativeStopProxy()
    private external fun nativeSaveSession(path: String): Boolean
    private external fun nativeRestoreSession(path: String): Boolean
    private external fun nativeResumePackets(fd: Int): Boolean
    private external fun nativeForgetSession()

    companion object {
        private const val TAG = "ArcadiaPlusVpnService"
        private const val SESSION_PREFS = "vpn_session"
        const val ACTION_START = "com.blueokanna.arcadiaplus.START_VPN"
        private const val ACTION_RESUME = "com.blueokanna.arcadiaplus.RESUME_VPN"
        const val ACTION_STOP = "com.blueokanna.arcadiaplus.STOP_VPN"
        const val NOTIFICATION_CHANNEL_ID = "arcadiaplus_vpn"
        const val NOTIFICATION_ID = 1

        private val _isRunning = AtomicBoolean(false)
        val isRunning: Boolean
            get() = _isRunning.get()

        private var _proxyMode = ProxyMode.RULE
        val proxyMode: ProxyMode
            get() = _proxyMode

        @Volatile private var _captureLan = true
        val captureLan: Boolean
            get() = _captureLan

        private val PRIVATE_PREFIXES =
                listOf(
                        "10.0.0.0" to 8,
                        "172.16.0.0" to 12,
                        "192.168.0.0" to 16,
                        "169.254.0.0" to 16,
                )

        private val _jniInitialized = AtomicBoolean(false)
        val jniInitialized: Boolean
            get() = _jniInitialized.get()

        // Track native library loading status
        private val _libraryLoaded = AtomicBoolean(false)
        val isLibraryLoaded: Boolean
            get() = _libraryLoaded.get()

        private var _libraryLoadError: String? = null
        val libraryLoadError: String?
            get() = _libraryLoadError

        @Volatile private var _vpnFd: Int = -1
        val vpnFd: Int
            get() = _vpnFd

        @Volatile private var startLatch: CountDownLatch? = null

        @Volatile private var instance: ArcadiaPlusVpnService? = null

        private val _isStarting = AtomicBoolean(false)

        fun confirmStarted(): Boolean = instance?.confirmSession() ?: false
        fun awaitReady(context: Context): Boolean {
            val latch = synchronized(this) {
                if (isRunning && _vpnFd >= 0) return true
                if (!_isStarting.get()) {
                    // Some devices defer sticky-service restarts. An Activity
                    // returning to the foreground can resume the saved session,
                    // but must never undo an explicit stop or take VPN consent.
                    val prefs = context.getSharedPreferences(SESSION_PREFS, MODE_PRIVATE)
                    if (!prefs.getBoolean("requested", false) ||
                        !java.io.File(context.noBackupFilesDir, "vpn-session.json").isFile ||
                        prepare(context) != null) return false

                    _isStarting.set(true)
                    startLatch = CountDownLatch(1)
                    val intent = Intent(context, ArcadiaPlusVpnService::class.java)
                        .setAction(ACTION_RESUME)
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                    } catch (error: Exception) {
                        _isStarting.set(false)
                        startLatch?.countDown()
                        Log.e(TAG, "Could not resume saved VPN session", error)
                        return false
                    }
                }
                startLatch
            }
            try {
                if (latch?.await(30, TimeUnit.SECONDS) != true) return false
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
            return isRunning && _vpnFd >= 0
        }

        init {
            Log.d(TAG, "=== Native library loading started ===")
            Log.d(TAG, "Device ABI: ${Build.SUPPORTED_ABIS.joinToString(", ")}")
            Log.d(TAG, "Primary ABI: ${Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"}")

            try {
                System.loadLibrary("rust_lib_arcadiaplus")
                _libraryLoaded.set(true)
                _libraryLoadError = null
                Log.d(TAG, "=== Native library loaded successfully ===")
            } catch (e: UnsatisfiedLinkError) {
                _libraryLoaded.set(false)
                _libraryLoadError = e.message ?: "Unknown UnsatisfiedLinkError"
                Log.e(TAG, "=== Failed to load native library ===")
                Log.e(TAG, "Error: ${e.message}")
                Log.e(TAG, "Stack trace:", e)
            } catch (e: Exception) {
                _libraryLoaded.set(false)
                _libraryLoadError = e.message ?: "Unknown error"
                Log.e(TAG, "=== Unexpected error loading native library ===")
                Log.e(TAG, "Error: ${e.message}")
                Log.e(TAG, "Stack trace:", e)
            }
        }

        /** Get detailed library loading information for diagnostics */
        fun getLibraryInfo(context: Context): Map<String, Any> {
            val nativeLibDir = context.applicationInfo.nativeLibraryDir
            val libFile = java.io.File(nativeLibDir, "librust_lib_arcadiaplus.so")

            Log.d(TAG, "=== Library Info ===")
            Log.d(TAG, "Native lib dir: $nativeLibDir")
            Log.d(TAG, "Library file exists: ${libFile.exists()}")
            Log.d(TAG, "Library file size: ${if (libFile.exists()) libFile.length() else 0}")
            Log.d(TAG, "Library loaded: ${_libraryLoaded.get()}")
            Log.d(TAG, "Library load error: ${_libraryLoadError ?: "none"}")

            return mapOf(
                    "loaded" to _libraryLoaded.get(),
                    "path" to nativeLibDir,
                    "fileExists" to libFile.exists(),
                    "fileSize" to (if (libFile.exists()) libFile.length() else 0L),
                    "error" to (_libraryLoadError ?: ""),
                    "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                    "primaryAbi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"),
                    "jniInitialized" to _jniInitialized.get()
            )
        }

        @Synchronized
        fun resetAllState() {
            Log.d(TAG, "=== Resetting all VPN static state ===")
            instance?.let { runningService ->
                Log.d(TAG, "Stopping live VPN service before resetting state")
                runningService.stopVpnInternal()
                return
            }

            _isRunning.set(false)
            _jniInitialized.set(false)
            _vpnFd = -1
            _isStarting.set(false)
            startLatch?.countDown()
            startLatch = null
            instance = null
            Log.d(TAG, "All VPN static state reset complete")
        }

        @Synchronized
        fun startVpnAndGetFd(context: Context, mode: String, allowLan: Boolean): Int {
            Log.d(TAG, "=== startVpnAndGetFd called with mode=$mode allowLan=$allowLan ===")

            if (_isRunning.get() && _vpnFd >= 0) {
                Log.d(TAG, "VPN already running, returning existing fd=$_vpnFd")
                return _vpnFd
            }

            if (_isStarting.get()) {
                Log.d(TAG, "VPN start already in progress, waiting...")
                try {
                    val latch = startLatch
                    if (latch != null) {
                        val started = latch.await(10, TimeUnit.SECONDS)
                        if (started && _vpnFd >= 0) {
                            return _vpnFd
                        }
                    }
                } catch (e: InterruptedException) {
                    Log.w(TAG, "Interrupted while waiting for VPN start")
                }
                return -1
            }

            // Check if another VPN is active and try to take over
            try {
                val connectivityManager =
                        context.getSystemService(Context.CONNECTIVITY_SERVICE) as
                                android.net.ConnectivityManager
                val activeNetwork = connectivityManager.activeNetwork
                if (activeNetwork != null) {
                    val capabilities = connectivityManager.getNetworkCapabilities(activeNetwork)
                    if (capabilities?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) ==
                                    true
                    ) {
                        Log.w(TAG, "Another VPN is active - will attempt to take over VPN slot")
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to check VPN status: ${e.message}")
            }

            _vpnFd = -1
            _isStarting.set(true)
            startLatch = CountDownLatch(1)

            Log.d(TAG, "Starting VPN service via Intent...")

            val intent =
                    Intent(context, ArcadiaPlusVpnService::class.java).apply {
                        action = ACTION_START
                        putExtra("mode", mode)
                        putExtra("allowLan", allowLan)
                    }

            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                    Log.d(TAG, "startForegroundService called successfully")
                } else {
                    context.startService(intent)
                    Log.d(TAG, "startService called successfully")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start VPN service: ${e.message}", e)
                _isStarting.set(false)
                startLatch?.countDown()
                return -1
            }

            try {
                Log.d(TAG, "Waiting for VPN to start (max 10 seconds)...")
                val started = startLatch?.await(10, TimeUnit.SECONDS) ?: false
                _isStarting.set(false)

                if (started && _vpnFd >= 0) {
                    Log.d(TAG, "=== VPN started successfully, fd=$_vpnFd ===")
                    return _vpnFd
                } else {
                    Log.e(TAG, "=== VPN start failed ===")
                    return -1
                }
            } catch (e: InterruptedException) {
                Log.e(TAG, "VPN start interrupted: ${e.message}")
                _isStarting.set(false)
                return -1
            }
        }

        fun stopVpnFromOutside(context: Context) {
            Log.d(TAG, "=== stopVpnFromOutside called ===")
            context.getSharedPreferences(SESSION_PREFS, MODE_PRIVATE).edit()
                .putBoolean("requested", false).commit()

            // Set flags first to signal stop
            _isRunning.set(false)
            _vpnFd = -1
            _isStarting.set(false)

            // Stop the instance if available
            instance?.let { vpnInstance ->
                Log.d(TAG, "Calling stopVpnInternal on instance...")
                vpnInstance.stopVpnInternal()
                return
            }

            Log.d(TAG, "=== stopVpnFromOutside complete ===")
        }

        fun setProxyMode(mode: ProxyMode) {
            _proxyMode = mode
            Log.d(TAG, "Proxy mode set to: $mode")
            instance?.let { service ->
                service.currentMode = mode
                service.getSharedPreferences(SESSION_PREFS, MODE_PRIVATE).edit()
                    .putString("mode", mode.name.lowercase()).apply()
                service.refreshNotification()
            }
        }
    }

    enum class ProxyMode {
        RULE,
        GLOBAL,
        DIRECT
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private val isStarting = AtomicBoolean(false)
    private var currentMode: ProxyMode = ProxyMode.RULE
    private var wakeLock: PowerManager.WakeLock? = null
    private val destroyed = AtomicBoolean(false)
    private val sessionFile get() = java.io.File(noBackupFilesDir, "vpn-session.json")

    @Synchronized
    private fun confirmSession(): Boolean {
        if (destroyed.get() || !_isRunning.get() || _vpnFd < 0) return false
        if (!nativeSaveSession(sessionFile.absolutePath)) return false
        return getSharedPreferences(SESSION_PREFS, MODE_PRIVATE).edit()
            .putBoolean("requested", true)
            .putString("mode", currentMode.name.lowercase())
            .putBoolean("allowLan", _captureLan).commit()
    }

    // The lock belongs to the active tunnel, not to the Activity. It is
    // released on every startup failure, explicit stop and service teardown.
    @android.annotation.SuppressLint("WakelockTimeout")
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:VpnRelay")
            .apply { setReferenceCounted(false); acquire() }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // Network connectivity callback for auto-stop on disconnect
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val hasActiveNetwork = AtomicBoolean(true)

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "=== VPN Service onCreate ===")

        _isRunning.set(false)
        _vpnFd = -1
        _jniInitialized.set(false)
        isStarting.set(false)

        instance = this
        createNotificationChannel()

        // Initialize network connectivity monitoring
        initNetworkMonitoring()

        try {
            Log.d(TAG, "Initializing Rust JNI bridge...")
            _jniInitialized.set(nativeInitRustBridge())
            check(_jniInitialized.get()) { "Native socket protection bridge failed to initialize" }
            Log.d(TAG, "Rust JNI bridge initialized successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize Rust JNI bridge: ${e.message}", e)
            _jniInitialized.set(false)
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Native library not loaded: ${e.message}", e)
            _jniInitialized.set(false)
        }

        Log.d(TAG, "VPN Service created, JNI initialized: ${_jniInitialized.get()}")
    }

    /**
     * Initialize network connectivity monitoring Note: We only log network changes, we don't
     * auto-stop VPN when network is lost because the user may want to keep VPN running and
     * reconnect when network is available
     */
    private fun initNetworkMonitoring() {
        try {
            connectivityManager =
                    getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

            networkCallback =
                    object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            Log.d(TAG, "Network available: $network")
                            hasActiveNetwork.set(true)
                        }

                        override fun onLost(network: Network) {
                            Log.d(TAG, "Network lost: $network")
                            // Check if there's still any active network
                            val activeNetwork = connectivityManager?.activeNetwork
                            if (activeNetwork == null) {
                                Log.w(
                                        TAG,
                                        "All networks lost - VPN will wait for network to reconnect"
                                )
                                hasActiveNetwork.set(false)
                                // DO NOT stop VPN when network is lost
                                // The user may want to keep VPN running and reconnect when network
                                // is available
                            }
                        }

                        override fun onCapabilitiesChanged(
                                network: Network,
                                capabilities: NetworkCapabilities
                        ) {
                            // Check if we have internet capability
                            val hasInternet =
                                    capabilities.hasCapability(
                                            NetworkCapabilities.NET_CAPABILITY_INTERNET
                                    )
                            val hasValidated =
                                    capabilities.hasCapability(
                                            NetworkCapabilities.NET_CAPABILITY_VALIDATED
                                    )
                            Log.d(
                                    TAG,
                                    "Network capabilities changed: internet=$hasInternet, validated=$hasValidated"
                            )
                        }

                        override fun onUnavailable() {
                            Log.w(
                                    TAG,
                                    "Network unavailable - VPN will wait for network to reconnect"
                            )
                            hasActiveNetwork.set(false)
                            // DO NOT stop VPN when network is unavailable
                            // The user may want to keep VPN running and reconnect when network is
                            // available
                        }
                    }

            // Register for all network types
            val request =
                    NetworkRequest.Builder()
                            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                            .build()

            connectivityManager?.registerNetworkCallback(request, networkCallback!!)
            Log.d(TAG, "Network monitoring initialized")

            // Check initial network state
            val activeNetwork = connectivityManager?.activeNetwork
            hasActiveNetwork.set(activeNetwork != null)
            Log.d(TAG, "Initial network state: hasActiveNetwork=${hasActiveNetwork.get()}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize network monitoring: ${e.message}", e)
        }
    }

    /** Unregister network callback */
    private fun unregisterNetworkCallback() {
        try {
            networkCallback?.let { callback ->
                connectivityManager?.unregisterNetworkCallback(callback)
                Log.d(TAG, "Network callback unregistered")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister network callback: ${e.message}")
        }
        networkCallback = null
        connectivityManager = null
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand: action=${intent?.action}, startId=$startId")

        val prefs = getSharedPreferences(SESSION_PREFS, MODE_PRIVATE)
        val resumeRequested = intent?.action == ACTION_RESUME ||
            intent?.action == SERVICE_INTERFACE || intent == null
        val recovering = resumeRequested && prefs.getBoolean("requested", false)
        when {
            recovering || intent?.action == ACTION_START -> {
                if (_isRunning.get() && _vpnFd >= 0) return START_STICKY
                if (isStarting.getAndSet(true)) {
                    Log.d(TAG, "VPN start already in progress, ignoring duplicate request")
                    return START_STICKY
                }
                if (recovering && startLatch?.count != 1L) startLatch = CountDownLatch(1)
                _isStarting.set(true)

                val mode = if (recovering) prefs.getString("mode", "rule") ?: "rule"
                    else intent?.getStringExtra("mode") ?: "rule"
                _captureLan = if (recovering) prefs.getBoolean("allowLan", true)
                    else intent?.getBooleanExtra("allowLan", true) ?: true
                currentMode =
                        when (mode.lowercase()) {
                            "global" -> ProxyMode.GLOBAL
                            "direct" -> ProxyMode.DIRECT
                            else -> ProxyMode.RULE
                        }
                _proxyMode = currentMode

                startForeground(NOTIFICATION_ID, createNotification())

                Thread(
                                { startVpn(recovering) },
                                "arcadiaplus-vpn-start",
                        )
                        .start()
            }
            intent?.action == ACTION_STOP -> {
                prefs.edit().putBoolean("requested", false).commit()
                Thread({ stopVpnInternal(stopProxy = true) }, "arcadiaplus-vpn-stop").start()
                return START_NOT_STICKY
            }
            else -> {
                if (!_isRunning.get()) {
                    _isStarting.set(false)
                    startLatch?.countDown()
                    Log.d(TAG, "No action and VPN not running, stopping service")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    @Synchronized
    private fun startVpn(recovering: Boolean = false) {
        try {
            check(!destroyed.get()) { "VPN service was destroyed during startup" }
            acquireWakeLock()
            Log.d(TAG, "=== Starting VPN with mode: $currentMode ===")

            if (!_jniInitialized.get()) {
                Log.w(TAG, "JNI bridge not initialized, attempting to initialize...")
                try {
                    _jniInitialized.set(nativeInitRustBridge())
                    Log.d(TAG, "JNI bridge initialized on retry")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to initialize JNI bridge on retry: ${e.message}", e)
                }
            } else {
                Log.d(TAG, "JNI bridge already initialized")
            }
            check(_jniInitialized.get()) { "Native socket protection bridge is unavailable" }
            if (recovering) {
                check(nativeRestoreSession(sessionFile.absolutePath)) { "Cannot restore VPN engine and DNS" }
            }

            vpnInterface?.let { oldInterface ->
                try {
                    Log.d(TAG, "Closing old VPN interface...")
                    oldInterface.close()
                    Log.d(TAG, "Closed old VPN interface")
                } catch (e: Exception) {
                    Log.w(TAG, "Error closing old VPN interface: ${e.message}")
                }
            }
            vpnInterface = null
            _vpnFd = -1

            Thread.sleep(200)

            Log.d(TAG, "Building VPN interface...")
            val builder =
                    Builder()
                            .setSession("ArcadiaPlus")
                            .setMtu(1500)
                            .addAddress("198.18.0.1", 16)
                            .addAddress("fd7a:115c:a1e0::1", 126)
                            .addDnsServer("198.18.0.2")
                            .setBlocking(false)

            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
            Log.d(TAG, "Added routes: 0.0.0.0/0 and ::/0 (dual-stack traffic)")

            if (!_captureLan) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    for ((address, prefixLength) in PRIVATE_PREFIXES) {
                        try {
                            builder.excludeRoute(
                                    IpPrefix(InetAddress.getByName(address), prefixLength)
                            )
                            Log.d(TAG, "Excluded private route: $address/$prefixLength")
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to exclude $address/$prefixLength: ${e.message}")
                        }
                    }
                } else {
                    Log.d(TAG, "excludeRoute needs API 33+; LAN stays captured")
                }
            }

            try {
                builder.addDisallowedApplication(packageName)
                Log.d(TAG, "Excluded self from VPN: $packageName")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to exclude self from VPN: ${e.message}")
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            var retryCount = 0
            val maxRetries = 5 // Increased from 3 to 5 for better handling of competing VPNs
            var lastError: Exception? = null

            while (retryCount < maxRetries && vpnInterface == null) {
                try {
                    Log.d(
                            TAG,
                            "Calling builder.establish() (attempt ${retryCount + 1}/$maxRetries)..."
                    )
                    vpnInterface = builder.establish()

                    if (vpnInterface == null && retryCount < maxRetries - 1) {
                        Log.w(TAG, "establish() returned null, waiting before retry...")
                        val waitTime = 500L + (retryCount * 500L)
                        Thread.sleep(waitTime)
                        retryCount++
                    } else {
                        break
                    }
                } catch (e: Exception) {
                    lastError = e
                    Log.w(TAG, "establish() failed (attempt ${retryCount + 1}): ${e.message}")
                    if (retryCount < maxRetries - 1) {
                        val waitTime = 500L + (retryCount * 500L)
                        Thread.sleep(waitTime)
                    }
                    retryCount++
                }
            }

            if (vpnInterface != null) {
                val fd = vpnInterface!!.fd
                check(!destroyed.get()) { "VPN service was destroyed during startup" }
                if (recovering) {
                    check(nativeResumePackets(fd)) { "Cannot restart VPN packet processing" }
                }
                _vpnFd = fd
                _isRunning.set(true)
                if (recovering) check(confirmSession()) { "Cannot save restored VPN session" }
                publishTileState()

                Log.d(TAG, "=== VPN STARTED SUCCESSFULLY ===")
                Log.d(TAG, "  fd=$fd")
                Log.d(TAG, "  JNI initialized=${_jniInitialized.get()}")
                Log.d(TAG, "  mode=$currentMode")
                Log.d(TAG, "  retries=$retryCount")

                startLatch?.countDown()
            } else {
                Log.e(TAG, "=== VPN FAILED TO START ===")
                Log.e(TAG, "builder.establish() returned null after $maxRetries attempts")
                if (lastError != null) {
                    Log.e(TAG, "Last error: ${lastError.message}")
                }
                stopVpnInternal(stopProxy = recovering)
            }
        } catch (e: Exception) {
            Log.e(TAG, "=== VPN START EXCEPTION ===", e)
            Log.e(TAG, "Error: ${e.message}")
            stopVpnInternal(stopProxy = recovering)
        } finally {
            isStarting.set(false)
            _isStarting.set(false)
        }
    }

    @Synchronized
    private fun stopVpnInternal(stopProxy: Boolean = false) {
        Log.d(TAG, "=== stopVpnInternal called ===")
        getSharedPreferences(SESSION_PREFS, MODE_PRIVATE).edit().putBoolean("requested", false).commit()
        nativeForgetSession()
        releaseWakeLock()

        _isRunning.set(false)
        _vpnFd = -1
        _isStarting.set(false)
        startLatch?.countDown()
        startLatch = null
        isStarting.set(false)

        try {
            nativeClearRustBridge()
            _jniInitialized.set(false)
        } catch (e: Exception) {
            Log.w(TAG, "Native teardown failed: ${e.message}")
        }

        // Close VPN interface
        vpnInterface?.let { pfd ->
            try {
                Log.d(TAG, "Closing VPN interface fd=${pfd.fd}...")
                pfd.close()
                Log.d(TAG, "VPN interface closed successfully")
            } catch (e: Exception) {
                Log.w(TAG, "Error closing VPN interface: ${e.message}")
            }
        }
        vpnInterface = null

        if (stopProxy) nativeStopProxy()
        publishTileState()

        // Stop foreground service
        stopForegroundCompat()

        // Stop the service
        stopSelf()

        // Clear instance reference
        instance = null

        Log.d(TAG, "=== VPN service stopped completely ===")
    }

    private fun publishTileState() {
        sendBroadcast(Intent(ArcadiaPlusTileService.ACTION_STATE_CHANGED).setPackage(packageName))
        android.service.quicksettings.TileService.requestListeningState(
            this, android.content.ComponentName(this, ArcadiaPlusTileService::class.java))
    }

    private fun stopForegroundCompat() {
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel =
                    NotificationChannel(
                                    NOTIFICATION_CHANNEL_ID,
                                    "ArcadiaPlus VPN",
                                    NotificationManager.IMPORTANCE_LOW
                            )
                            .apply {
                                description = "VPN Service Notifications"
                                setShowBadge(false)
                                lockscreenVisibility = Notification.VISIBILITY_SECRET
                            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun refreshNotification() {
        try {
            getSystemService(NotificationManager::class.java)
                    .notify(NOTIFICATION_ID, createNotification())
        } catch (error: Exception) {
            Log.w(TAG, "Failed to refresh the VPN notification: ${error.message}")
        }
    }

    private fun createNotification(): Notification {
        val intent =
                Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
        val pendingIntent =
                PendingIntent.getActivity(
                        this,
                        0,
                        intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

        val stopIntent =
                Intent(this, ArcadiaPlusVpnService::class.java).apply { action = ACTION_STOP }
        val stopPendingIntent =
                PendingIntent.getService(
                        this,
                        1,
                        stopIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

        val modeText =
                when (currentMode) {
                    ProxyMode.GLOBAL -> "Global Proxy"
                    ProxyMode.RULE -> "Rule Mode"
                    ProxyMode.DIRECT -> "Direct Mode"
                }

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("ArcadiaPlus")
                .setContentText("VPN 正在运行 - $modeText")
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setContentIntent(pendingIntent)
                .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止", stopPendingIntent)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setVisibility(NotificationCompat.VISIBILITY_SECRET)
                .build()
    }

    override fun onDestroy() {
        destroyed.set(true)
        // Native joins and a racing establish() can take seconds. Never wait
        // for the startup monitor on Android's main thread.
        Thread({ destroyResources() }, "arcadiaplus-vpn-destroy").start()
        super.onDestroy()
    }

    @Synchronized
    private fun destroyResources() {
        releaseWakeLock()
        Log.d(TAG, "onDestroy called")
        val ownsState = instance === this
        if (ownsState) {
            _isRunning.set(false)
            _vpnFd = -1
            isStarting.set(false)
            instance = null
            startLatch?.countDown()
            startLatch = null
            publishTileState()
        }

        // Unregister network callback
        unregisterNetworkCallback()

        try {
            if (ownsState && _jniInitialized.getAndSet(false)) nativeClearRustBridge()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to clear Rust JNI bridge: ${e.message}")
        }

        try { vpnInterface?.close() }
        catch (error: Exception) { Log.w(TAG, "Cannot close destroyed VPN interface", error) }
        vpnInterface = null
    }

    override fun onRevoke() {
        Log.d(TAG, "VPN permission revoked")
        getSharedPreferences(SESSION_PREFS, MODE_PRIVATE).edit().putBoolean("requested", false).commit()
        Thread({ stopVpnInternal(stopProxy = true) }, "arcadiaplus-vpn-revoke").start()
        super.onRevoke()
    }
}
