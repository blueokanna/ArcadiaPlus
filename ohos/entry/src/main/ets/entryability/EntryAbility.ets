import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { ArcadiaPlusPlugin } from '../plugins/ArcadiaPlusPlugin';

/**
 * UI-process entry point.
 *
 * FlutterAbility owns the engine and the page it renders. The one thing this
 * subclass adds is the bridge plugin: without registration the
 * `com.arcadiaplus/ohos_proxy` channel has no handler and every VPN request
 * from Dart is answered with "not implemented".
 */
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine): void {
    super.configureFlutterEngine(flutterEngine);
    flutterEngine.getPlugins()?.add(new ArcadiaPlusPlugin());
  }
}
