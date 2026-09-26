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

static napi_threadsafe_function g_protect_tsfn = nullptr;

/// The JS callback runs on the JS thread; this trampoline is what the
/// thread-safe function invokes there.
static void CallProtectOnJsThread(napi_env env, napi_value js_callback, void* /*context*/,
                                  void* data) {
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
    if (g_protect_tsfn != nullptr) {
        napi_call_threadsafe_function(
            g_protect_tsfn,
            reinterpret_cast<void*>(static_cast<intptr_t>(fd)),
            napi_tsfn_nonblocking);
    }
    return 1;
}

static std::string ValueToString(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return std::string();
    }
    std::string text(length, '\0');
    size_t written = 0;
    napi_get_value_string_utf8(env, value, text.data(), length + 1, &written);
    text.resize(written);
    return text;
}

static int32_t ValueToInt32(napi_env env, napi_value value) {
    int32_t number = 0;
    napi_get_value_int32(env, value, &number);
    return number;
}

static bool ValueToBool(napi_env env, napi_value value) {
    bool flag = false;
    napi_get_value_bool(env, value, &flag);
    return flag;
}

static napi_value StartVpn(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 5) {
        napi_throw_error(env, nullptr, "startVpn expects (configPath, geoipPath, logPath, tunFd, protectProcess)");
        return nullptr;
    }

    const std::string config_path = ValueToString(env, argv[0]);
    const std::string geoip_path = ValueToString(env, argv[1]);
    const std::string log_path = ValueToString(env, argv[2]);
    const int32_t tun_fd = ValueToInt32(env, argv[3]);
    const int32_t protect_process = ValueToBool(env, argv[4]) ? 1 : 0;

    const int32_t code = arcadia_ohos_start(config_path.c_str(), geoip_path.c_str(),
                                            log_path.c_str(), tun_fd, protect_process);
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
        napi_throw_error(env, nullptr, "setProxyMode expects (mode)");
        return nullptr;
    }
    const std::string mode = ValueToString(env, argv[0]);
    const int32_t code = arcadia_ohos_set_proxy_mode(mode.c_str());
    napi_value result = nullptr;
    napi_create_int32(env, code, &result);
    return result;
}

static napi_value SetProtectCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    // A previous callback (from an earlier extension run) is released first:
    // the JS reference must not outlive the ability that created it.
    if (g_protect_tsfn != nullptr) {
        napi_release_threadsafe_function(g_protect_tsfn, napi_tsfn_release);
        g_protect_tsfn = nullptr;
        arcadia_ohos_set_protect_callback(nullptr);
    }
    if (argc < 1) {
        return nullptr;
    }

    napi_valuetype type = napi_undefined;
    napi_typeof(env, argv[0], &type);
    if (type != napi_function) {
        napi_throw_error(env, nullptr, "setProtectCallback expects a function");
        return nullptr;
    }

    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "arcadia_protect", NAPI_AUTO_LENGTH, &resource_name);
    const napi_status status = napi_create_threadsafe_function(
        env, argv[0], nullptr, resource_name, 0, 1, nullptr, nullptr, nullptr,
        CallProtectOnJsThread, &g_protect_tsfn);
    if (status != napi_ok) {
        napi_throw_error(env, nullptr, "failed to create the protect thread-safe function");
        return nullptr;
    }

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
