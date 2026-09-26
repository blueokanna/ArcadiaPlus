// NAPI wrapper around the Rust engine entry points.
//
// The VPN extension process is an ArkTS host; the engine inside it is the
// ArcadiaPlus Rust crate, statically linked into this shared library. Every
// function here is a thin, panic-safe bridge: argument coercion, one call into
// `rust/src/ohos_ffi.rs`, and an integer code back (see that file for the
// meaning of each code — the ArkTS side reports them verbatim).
//
// The one piece of real machinery is `setProtectCallback`: ArkTS passes a JS
// function, the Rust engine calls it from arbitrary threads for every socket
// it opens, and a thread-safe function carries those calls onto the JS thread.
// The engine treats the callback's return value as "will be protected": the
// JS side reports its own failures through hilog, because an asynchronous
// protect can not answer yes or no in time for the socket being opened.

#include <atomic>
#include <cstdint>
#include <string>

#include <napi/native_api.h>

extern "C" {
int32_t arcadia_ohos_start(const char* config_path, const char* geoip_path,
                           const char* log_path, int32_t tun_fd,
                           int32_t protect_process);
int32_t arcadia_ohos_stop(void);
int32_t arcadia_ohos_set_protect_callback(int32_t (*callback)(int32_t));
int32_t arcadia_ohos_set_proxy_mode(const char* mode);
}

/// The protect trampoline's thread-safe function.
///
/// The engine calls it from arbitrary threads, the JS thread swaps it during
/// teardown, so the handle is atomic: a dial that is asking for the current
/// value either sees the live handle or null, never a torn value.
static std::atomic<napi_threadsafe_function> g_protect_tsfn{nullptr};

/// The JS callback runs on the JS thread; this trampoline is what the
/// thread-safe function invokes there.
static void CallProtectOnJsThread(napi_env env, napi_value js_callback, void* /*context*/,
                                  void* data) {
    if (js_callback == nullptr) {
        return;
    }
    int32_t fd = static_cast<int32_t>(reinterpret_cast<intptr_t>(data));
    napi_value argument = nullptr;
    napi_create_int32(env, fd, &argument);
    napi_value global = nullptr;
    napi_get_global(env, &global);
    napi_call_function(env, global, js_callback, 1, &argument, nullptr);
}

/// Called from the engine's threads. Returns `1` — "treated as protected" —
/// because the actual `vpnConnection.protect` call is asynchronous.
static int32_t ProtectCallbackFromEngine(int32_t fd) {
    napi_threadsafe_function tsfn = g_protect_tsfn.load(std::memory_order_acquire);
    if (tsfn != nullptr) {
        napi_call_threadsafe_function(
            tsfn,
            reinterpret_cast<void*>(static_cast<intptr_t>(fd)),
            napi_tsfn_nonblocking);
    }
    return 1;
}

/// Read a string argument into `out`; `false` when the value is not a string.
static bool ValueToString(napi_env env, napi_value value, std::string* out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    std::string text(length, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, text.data(), length + 1, &written) != napi_ok) {
        return false;
    }
    text.resize(written);
    *out = std::move(text);
    return true;
}

/// Read a number argument into `out`; `false` when the value is not a number.
static bool ValueToInt32(napi_env env, napi_value value, int32_t* out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_int32(env, value, out) == napi_ok;
}

/// Read a boolean argument into `out`; `false` when the value is not a boolean.
static bool ValueToBool(napi_env env, napi_value value, bool* out) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_boolean) {
        return false;
    }
    return napi_get_value_bool(env, value, out) == napi_ok;
}

static napi_value StartVpn(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_type_error(env, nullptr,
                              "startVpn expects (configPath, geoipPath, logPath, tunFd, protectProcess)");
        return nullptr;
    }

    std::string config_path;
    std::string geoip_path;
    std::string log_path;
    int32_t tun_fd = -1;
    bool protect_process = false;
    // A mistyped argument must never reach the engine: reading a string as an
    // int used to produce 0 without a word, and 0 is a valid descriptor
    // (stdin) the packet path would then have been pointed at.
    if (!ValueToString(env, argv[0], &config_path) ||
        !ValueToString(env, argv[1], &geoip_path) ||
        !ValueToString(env, argv[2], &log_path) ||
        !ValueToInt32(env, argv[3], &tun_fd) ||
        !ValueToBool(env, argv[4], &protect_process)) {
        napi_throw_type_error(env, nullptr,
                              "startVpn expects (string, string, string, number, boolean)");
        return nullptr;
    }
    if (tun_fd < 0) {
        napi_throw_range_error(env, nullptr, "startVpn received a negative tun descriptor");
        return nullptr;
    }

    const int32_t code = arcadia_ohos_start(config_path.c_str(), geoip_path.c_str(),
                                            log_path.c_str(), tun_fd,
                                            protect_process ? 1 : 0);
    napi_value result = nullptr;
    napi_create_int32(env, code, &result);
    return result;
}

static napi_value StopVpn(napi_env env, napi_callback_info info) {
    const int32_t code = arcadia_ohos_stop();
    napi_value result = nullptr;
    napi_create_int32(env, code, &result);
    return result;
}

static napi_value SetProxyMode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "setProxyMode expects (mode)");
        return nullptr;
    }
    std::string mode;
    if (!ValueToString(env, argv[0], &mode)) {
        napi_throw_type_error(env, nullptr, "setProxyMode expects a string");
        return nullptr;
    }
    const int32_t code = arcadia_ohos_set_proxy_mode(mode.c_str());
    napi_value result = nullptr;
    napi_create_int32(env, code, &result);
    return result;
}

static napi_value SetProtectCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    // Decide first, mutate second: an argument of the wrong type must not
    // tear down the callback that is currently in place. `setProtectCallback()`
    // with no argument (or with nothing/undefined) is the documented way to
    // clear it.
    napi_valuetype type = napi_undefined;
    const bool clearing =
        argc < 1 ||
        (napi_typeof(env, argv[0], &type) == napi_ok &&
         (type == napi_undefined || type == napi_null));
    if (!clearing && type != napi_function) {
        napi_throw_type_error(env, nullptr, "setProtectCallback expects a function");
        return nullptr;
    }

    // The engine is detached before the JS reference is dropped: the
    // trampoline must stop being reachable first, then the thread-safe
    // function that owns the JS function can go. `napi_tsfn_abort` is
    // deliberate — a queued protect() for a session that is already shutting
    // down must not run after the ability is gone.
    napi_threadsafe_function previous =
        g_protect_tsfn.exchange(nullptr, std::memory_order_acq_rel);
    if (previous != nullptr) {
        arcadia_ohos_set_protect_callback(nullptr);
        napi_release_threadsafe_function(previous, napi_tsfn_abort);
    }

    if (clearing) {
        napi_value result = nullptr;
        napi_create_int32(env, 0, &result);
        return result;
    }

    napi_threadsafe_function created = nullptr;
    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "arcadia_protect", NAPI_AUTO_LENGTH, &resource_name);
    const napi_status status = napi_create_threadsafe_function(
        env, argv[0], nullptr, resource_name, 0, 1, nullptr, nullptr, nullptr,
        CallProtectOnJsThread, &created);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "failed to create the protect thread-safe function");
        return nullptr;
    }
    g_protect_tsfn.store(created, std::memory_order_release);

    const int32_t code = arcadia_ohos_set_protect_callback(ProtectCallbackFromEngine);
    napi_value result = nullptr;
    napi_create_int32(env, code, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        {"startVpn", nullptr, StartVpn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopVpn", nullptr, StopVpn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProxyMode", nullptr, SetProxyMode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setProtectCallback", nullptr, SetProtectCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
EXTERN_C_END

static napi_module arcadia_core_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "arcadia_core",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterArcadiaCoreModule(void) {
    napi_module_register(&arcadia_core_module);
}
