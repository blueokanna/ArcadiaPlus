import { FlutterPlugin, MethodChannel, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';

const TAG = 'ArcadiaPlusPlugin';
const DOMAIN = 0x0000;
const BUNDLE_NAME = 'com.blueokanna.arcadiaplus';
const VPN_ABILITY = 'ArcadiaPlusVpnAbility';

const STATUS_EVENT = 'com.arcadiaplus.VPN_STATUS';
const COMMAND_EVENT = 'com.arcadiaplus.VPN_COMMAND';

/** How long a start may take before the UI gives up waiting for the
 * extension's status event. Generous on purpose: the first start shows the
 * system's VPN authorization dialog, and that is the user's to answer. */
const START_TIMEOUT_MS = 60000;
/** Stopping is a local teardown; it has no dialog to wait for. */
const STOP_TIMEOUT_MS = 10000;

interface StartOptions {
  mode: string;
  configPath: string;
  geoipPath?: string;
  logPath?: string;
}

/**
 * Bridges the `com.arcadiaplus/ohos_proxy` channel to the HarmonyOS VPN stack.
 *
 * This class lives in the UI process and owns no data path: it starts and
 * stops the `VpnExtensionAbility`, forwards the staged engine paths, and
 * mirrors the extension's status events so `isVpnRunning` reports what the
 * extension actually said. The tunnel, the engine and the packet path all
 * live in the extension process — see `ArcadiaPlusVpnAbility`.
 */
export class ArcadiaPlusPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private running = false;
  private pendingStart: ((success: boolean, error: string) => void) | null = null;
  private pendingStop: ((success: boolean, error: string) => void) | null = null;
  private startTimer = -1;
  private stopTimer = -1;

  onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.arcadiaplus/ohos_proxy');

    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        this.handleMethodCall(call, result);
      },
    });

    this.subscribeStatus();
    hilog.info(DOMAIN, TAG, 'ArcadiaPlus plugin attached to engine');
  }

  onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    if (this.subscriber !== null) {
      commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = null;
    }
    hilog.info(DOMAIN, TAG, 'ArcadiaPlus plugin detached from engine');
  }

  private handleMethodCall(call: MethodCall, result: MethodResult): void {
    hilog.info(DOMAIN, TAG, 'Method call: %{public}s', call.method);

    switch (call.method) {
      case 'startVpn':
        this.startVpn(call, result);
        break;
      case 'stopVpn':
        this.stopVpn(result);
        break;
      case 'isVpnRunning':
        result.success(this.running);
        break;
      case 'setProxyMode':
        this.setProxyMode(call, result);
        break;
      case 'getDeviceInfo':
        this.getDeviceInfo(result);
        break;
      default:
        result.notImplemented();
    }
  }

  private startVpn(call: MethodCall, result: MethodResult): void {
    if (this.running) {
      result.success({ success: true } as Record<string, Object>);
      return;
    }

    if (this.pendingStart !== null) {
      result.success({
        success: false,
        error: 'a VPN start is already in flight',
      } as Record<string, Object>);
      return;
    }

    const arguments_ = call.arguments as Record<string, Object> | undefined;
    const configPath = arguments_?.configPath?.toString() ?? '';
    if (configPath.length === 0) {
      result.success({
        success: false,
        error: 'no engine config path was provided to the VPN start request',
      } as Record<string, Object>);
      return;
    }

    const options: StartOptions = {
      mode: arguments_?.mode?.toString() ?? 'rule',
      configPath: configPath,
    };
    const geoipPath = arguments_?.geoipPath?.toString();
    if (geoipPath !== undefined && geoipPath.length > 0) {
      options.geoipPath = geoipPath;
    }
    const logPath = arguments_?.logPath?.toString();
    if (logPath !== undefined && logPath.length > 0) {
      options.logPath = logPath;
    }

    this.pendingStart = (success: boolean, error: string) => {
      result.success({ success: success, error: error } as Record<string, Object>);
    };

    const want: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY,
      parameters: {
        mode: options.mode,
        configPath: options.configPath,
        geoipPath: options.geoipPath ?? '',
        logPath: options.logPath ?? '',
      },
    };

    vpnExtension.startVpnExtensionAbility(want).then(() => {
      hilog.info(DOMAIN, TAG, 'startVpnExtensionAbility accepted');
    }).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'startVpnExtensionAbility refused: %{public}s', error.message);
      this.settleStart(false, `the system refused the VPN start: ${error.message}`);
    });

    this.startTimer = setTimeout(() => {
      this.startTimer = -1;
      this.settleStart(false, 'timed out waiting for the VPN extension to report ready');
    }, START_TIMEOUT_MS);
  }

  private stopVpn(result: MethodResult): void {
    if (!this.running) {
      result.success({ success: true } as Record<string, Object>);
      return;
    }

    if (this.pendingStop !== null) {
      result.success({
        success: false,
        error: 'a VPN stop is already in flight',
      } as Record<string, Object>);
      return;
    }

    this.pendingStop = (success: boolean, error: string) => {
      result.success({ success: success, error: error } as Record<string, Object>);
    };

    const want: Want = {
      deviceId: '',
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY,
    };
    vpnExtension.stopVpnExtensionAbility(want).then(() => {
      hilog.info(DOMAIN, TAG, 'stopVpnExtensionAbility accepted');
    }).catch((error: Error) => {
      hilog.error(DOMAIN, TAG, 'stopVpnExtensionAbility refused: %{public}s', error.message);
      this.settleStop(false, `the system refused the VPN stop: ${error.message}`);
    });

    this.stopTimer = setTimeout(() => {
      this.stopTimer = -1;
      this.settleStop(false, 'timed out waiting for the VPN extension to stop');
    }, STOP_TIMEOUT_MS);
  }

  private setProxyMode(call: MethodCall, result: MethodResult): void {
    const arguments_ = call.arguments as Record<string, Object> | undefined;
    const mode = arguments_?.mode?.toString() ?? 'rule';
    commonEventManager.publish(
      COMMAND_EVENT,
      { parameters: { command: 'set-mode', mode: mode } },
      (error) => {
        if (error) {
          hilog.error(DOMAIN, TAG, 'mode command failed: %{public}s', JSON.stringify(error));
          result.success(false);
          return;
        }
        result.success(this.running);
      },
    );
  }

  private subscribeStatus(): void {
    commonEventManager.createSubscriber(
      { events: [STATUS_EVENT] },
      (error, subscriber) => {
        if (error) {
          hilog.error(DOMAIN, TAG, 'status subscriber failed: %{public}s', JSON.stringify(error));
          return;
        }
        this.subscriber = subscriber;
        subscriber.on(STATUS_EVENT, (data: commonEventManager.CommonEventData) => {
          const parameters = data.parameters as Record<string, Object> | undefined;
          const state = parameters?.state?.toString() ?? '';
          const detail = parameters?.error?.toString() ?? '';
          if (state === 'started') {
            this.running = true;
            this.settleStart(true, '');
          } else if (state === 'failed') {
            this.running = false;
            this.settleStart(false, detail);
          } else if (state === 'stopped') {
            this.running = false;
            this.settleStop(true, '');
          }
          hilog.info(DOMAIN, TAG, 'VPN state: %{public}s', state);
        });
      },
    );
  }

  private settleStart(success: boolean, error: string): void {
    if (this.startTimer !== -1) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
    const pending = this.pendingStart;
    this.pendingStart = null;
    if (pending !== null) {
      pending(success, error);
    }
  }

  private settleStop(success: boolean, error: string): void {
    if (this.stopTimer !== -1) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    const pending = this.pendingStop;
    this.pendingStop = null;
    if (pending !== null) {
      pending(success, error);
    }
  }

  private getDeviceInfo(result: MethodResult): void {
    try {
      const info: Record<string, string> = {
        brand: deviceInfo.brand,
        manufacturer: deviceInfo.manufacture,
        model: deviceInfo.productModel,
        device: deviceInfo.deviceType,
        display: deviceInfo.displayVersion,
        osFullName: deviceInfo.osFullName,
        sdkApiVersion: deviceInfo.sdkApiVersion.toString(),
      };

      hilog.info(DOMAIN, TAG, 'Device info: %{public}s', JSON.stringify(info));
      result.success(info);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to get device info: %{public}s', JSON.stringify(error));
      result.error('DEVICE_INFO_ERROR', 'Failed to get device info', error);
    }
  }
}
