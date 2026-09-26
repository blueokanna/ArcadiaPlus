import path from 'path';
import { appTasks } from '@ohos/hvigor-ohos-plugin';

declare const require: (id: string) => any;

let flutterPlugin: any;
try {
  flutterPlugin = require('flutter-hvigor-plugin').flutterHvigorPlugin;
} catch {
  flutterPlugin = undefined;
}

export default {
  system: appTasks,
  plugins:
    typeof flutterPlugin === 'function' ? [flutterPlugin(path.dirname(__dirname))] : [],
};
