import { FlutterPlugin, MethodChannel, MethodCall, MethodResult } from '@aspect/flutter_ohos';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';

const TAG = 'ArcadiaPlusPlugin';
const DOMAIN = 0x0000;

/**
 * ArcadiaPlus Flutter Plugin for HarmonyOS NEXT
 *
 * Bridges the `com.arcadiaplus/ohos_proxy` method channel to native OHOS APIs.
 * VPN control is deliberately unimplemented: every VPN method answers with
 * `OHOS_VPN_UNSUPPORTED` so the Dart side can report a real reason instead of
 * pretending the tunnel came up.
 */
export class ArcadiaPlusPlugin implements FlutterPlugin {
  private channel: MethodChannel | null = null;

  onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'com.arcadiaplus/ohos_proxy');
    
    this.channel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        this.handleMethodCall(call, result);
      }
    });
    
    hilog.info(DOMAIN, TAG, 'ArcadiaPlus plugin attached to engine');
  }

  onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    hilog.info(DOMAIN, TAG, 'ArcadiaPlus plugin detached from engine');
  }

  private handleMethodCall(call: MethodCall, result: MethodResult): void {
    hilog.info(DOMAIN, TAG, 'Method call: %{public}s', call.method);
    
    switch (call.method) {
      case 'startVpn':
        this.unsupportedVpnOperation(result);
        break;
      case 'stopVpn':
        this.unsupportedVpnOperation(result);
        break;
      case 'isVpnRunning':
        result.success(false);
        break;
      case 'setProxyMode':
        this.unsupportedVpnOperation(result);
        break;
      case 'getDeviceInfo':
        this.getDeviceInfo(result);
        break;
      default:
        result.notImplemented();
    }
  }

  private unsupportedVpnOperation(result: MethodResult): void {
    result.error(
      'OHOS_VPN_UNSUPPORTED',
      'HarmonyOS NEXT VPN integration is not implemented',
      null
    );
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
        sdkApiVersion: deviceInfo.sdkApiVersion.toString()
      };
      
      hilog.info(DOMAIN, TAG, 'Device info: %{public}s', JSON.stringify(info));
      result.success(info);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to get device info: %{public}s', JSON.stringify(error));
      result.error('DEVICE_INFO_ERROR', 'Failed to get device info', error);
    }
  }
}
