import { common, Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import arcadiaCore from 'libarcadia_core.so';

const TAG = 'ArcadiaPlusVpnAbility';
const DOMAIN = 0x0000;

const STATUS_EVENT = 'com.arcadiaplus.VPN_STATUS';
const COMMAND_EVENT = 'com.arcadiaplus.VPN_COMMAND';

const TUN_ADDRESS = '198.18.0.1';
const TUN_PREFIX = 16;
const TUN_DNS = '198.18.0.2';
const TUN_MTU = 1500;

const TUN_V6_ADDRESS = 'fd7a:115c:a1e0:1::1';
const TUN_V6_PREFIX = 64;
const TUN_V6_DNS = 'fd7a:115c:a1e0:1::2';

/**
 * The VPN data path for HarmonyOS.
 *
 * The engine runs *here*, in the extension process, for two reasons that
 * cannot be worked around from the UI process: `vpnConnection.create()` is the
 * only way to obtain the tun fd, and `vpnConnection.protect()` (or
 * `protectProcessNet` on API 22+) is the only way to keep the engine's own
 * dials out of the tunnel it just installed. The UI process stages everything
 * this process needs — engine config, GeoIP database, log path — in the shared
 * sandbox and passes the paths in the start request; results travel back as
 * common events, because that is the IPC both processes can see.
 */
export default class ArcadiaPlusVpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | null = null;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private running = false;

  onCreate(want: Want): void {
    const parameters = want.parameters as Record<string, Object> | undefined;
    this.startTunnel(parameters)
      .then(() => {
        this.running = true;
        this.publishStatus('started', '');
      })
      .catch((error: Error) => {
        hilog.error(DOMAIN, TAG, 'VPN start failed: %{public}s', error.message);
        this.publishStatus('failed', error.message);
      });
    this.subscribeCommands();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
    try {
      arcadiaCore.stopVpn();
      arcadiaCore.setProtectCallback();
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Engine stop failed: %{public}s', JSON.stringify(error));
    }
    if (this.subscriber !== null) {
      commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = null;
    }
    if (this.vpnConnection !== null) {
      this.vpnConnection.destroy().then(() => {
        hilog.info(DOMAIN, TAG, 'VPN connection destroyed');
      });
      this.vpnConnection = null;
    }
    this.running = false;
    this.publishStatus('stopped', '');
  }

  private async startTunnel(parameters: Record<string, Object> | undefined): Promise<void> {
    const configPath = parameters?.configPath?.toString() ?? '';
    if (configPath.length === 0) {
      throw new Error('the start request carried no engine config path');
    }
    const geoipPath = parameters?.geoipPath?.toString() ?? '';
    const logPath = parameters?.logPath?.toString() ?? '';
    const mode = parameters?.mode?.toString() ?? 'rule';

    const connection = vpnExtension.createVpnConnection(this.context);
    this.vpnConnection = connection;

    let processProtected = false;
    try {
      const dynamic = connection as ESObject;
      if (typeof dynamic.protectProcessNet === 'function') {
        await dynamic.protectProcessNet();
        processProtected = true;
        hilog.info(DOMAIN, TAG, 'protectProcessNet applied');
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'protectProcessNet unavailable: %{public}s', JSON.stringify(error));
    }

    if (!processProtected) {
      arcadiaCore.setProtectCallback((fd: number) => {
        if (this.vpnConnection !== null) {
          this.vpnConnection.protect(fd).catch((error: Error) => {
            hilog.error(DOMAIN, TAG, 'protect(%{public}d) failed: %{public}s', fd, error.message);
          });
        }
      });
    }

    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [
        {
          address: { address: TUN_ADDRESS, family: 1 },
          prefixLength: TUN_PREFIX,
        },
        {
          address: { address: TUN_V6_ADDRESS, family: 2 },
          prefixLength: TUN_V6_PREFIX,
        },
      ],

      routes: [
        {
          interface: 'vpn-tun',
          destination: {
            address: { address: '0.0.0.0', family: 1 },
            prefixLength: 0,
          },
          gateway: {
            address: { address: TUN_ADDRESS, family: 1 },
            prefixLength: TUN_PREFIX,
          },
          hasGateway: false,
          isDefaultRoute: true,
        },
        {
          interface: 'vpn-tun',
          destination: {
            address: { address: '::', family: 2 },
            prefixLength: 0,
          },
          gateway: {
            address: { address: TUN_V6_ADDRESS, family: 2 },
            prefixLength: TUN_V6_PREFIX,
          },
          hasGateway: false,
          isDefaultRoute: true,
        },
      ],
      mtu: TUN_MTU,
      dnsAddresses: [TUN_DNS, TUN_V6_DNS],
      isIPv4Accepted: true,
      isIPv6Accepted: true,
    };

    const tunFd = await connection.create(vpnConfig);
    hilog.info(DOMAIN, TAG, 'tun fd acquired: %{public}d', tunFd);

    const started = arcadiaCore.startVpn(configPath, geoipPath, logPath, tunFd, processProtected);
    if (started !== 0) {
      // The engine refused; hand the adapter straight back instead of leaving
      // a tunnel that carries nothing.
      await connection.destroy();
      this.vpnConnection = null;
      throw new Error(`engine refused to start (code ${started})`);
    }

    arcadiaCore.setProxyMode(mode);
  }

  /** Mode switches arrive as events: the extension owns the routing mode of
   * its own engine instance, and restarting the tunnel for one setting would
   * drop every connection the user has open. */
  private subscribeCommands(): void {
    commonEventManager.createSubscriber(
      { events: [COMMAND_EVENT] },
      (error, subscriber) => {
        if (error) {
          hilog.error(DOMAIN, TAG, 'command subscriber failed: %{public}s', JSON.stringify(error));
          return;
        }
        this.subscriber = subscriber;
        subscriber.on(COMMAND_EVENT, (data: commonEventManager.CommonEventData) => {
          const parameters = data.parameters as Record<string, Object> | undefined;
          const command = parameters?.command?.toString() ?? '';
          if (command === 'set-mode' && this.running) {
            const mode = parameters?.mode?.toString() ?? 'rule';
            arcadiaCore.setProxyMode(mode);
            hilog.info(DOMAIN, TAG, 'proxy mode switched to %{public}s', mode);
          }
        });
      },
    );
  }

  private publishStatus(state: string, error: string): void {
    commonEventManager.publish(
      STATUS_EVENT,
      { parameters: { state: state, error: error } },
      (publishError) => {
        if (publishError) {
          hilog.error(DOMAIN, TAG, 'status publish failed: %{public}s', JSON.stringify(publishError));
        }
      },
    );
  }
}
