import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos';

let storage = LocalStorage.getShared();
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS';

/**
 * Hosts the Flutter surface. The view id is published by FlutterAbility into
 * the shared LocalStorage, so the page renders the engine that ability owns.
 */
@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;
  @LocalStorageLink('viewId') viewId: string = '';

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS);
    return true;
  }
}
