cmake_minimum_required(VERSION 3.5.0)
project(arcadia_core)

set(CMAKE_CXX_STANDARD 17)

# The Rust engine for this ABI, staged by ohos/scripts/build-rust-ohos.sh.
# The path is the contract between that script and this build: the extension
# links the *static* library, because the engine must live in the extension
# process itself (it owns the tun fd and the tunnel exemption).
set(RUST_STATIC_LIB
    ${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/${OHOS_ARCH}/librust_lib_arcadiaplus.a)

if(NOT EXISTS ${RUST_STATIC_LIB})
    message(FATAL_ERROR
        "The Rust engine for ${OHOS_ARCH} has not been built. "
        "Run ohos/scripts/build-rust-ohos.sh before building the HAP.")
endif()

add_library(arcadia_core SHARED napi_init.cpp)

target_link_libraries(arcadia_core PUBLIC
    ${RUST_STATIC_LIB}
    libace_napi.z.so
)
