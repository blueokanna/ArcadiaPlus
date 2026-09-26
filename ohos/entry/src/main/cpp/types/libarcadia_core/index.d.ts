/**
 * Entry points of the ArcadiaPlus engine for the VPN extension process.
 *
 * These functions are implemented in `napi_init.cpp` (NAPI wrapper) on top of
 * the Rust crate in `rust/src/ohos_ffi.rs`; the integer codes each returns are
 * documented there (`0` is success, negative names the failed stage).
 */
export const startVpn: (
  configPath: string,
  geoipPath: string,
  logPath: string,
  tunFd: number,
  protectProcess: boolean
) => number;
export const stopVpn: () => number;
export const setProxyMode: (mode: string) => number;
export const setProtectCallback: (callback: (fd: number) => void) => number;
