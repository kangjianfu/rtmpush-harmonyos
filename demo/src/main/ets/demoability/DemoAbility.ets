import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';

export default class DemoAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
    });
  }
}
