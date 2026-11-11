import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AuthStore } from '../common/store/AuthStore';
import { Logger } from '../common/utils/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('context', this.context);
    // 同步从 preferences 恢复登录态与服务器地址，之后 Index 才能直接显示首页。
    AuthStore.init(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Logger.error('EntryAbility', 'loadContent failed: ' + err.message);
      }
    });

    // 全屏沉浸：内容区延伸到状态栏/导航栏，系统栏透明、图标用深色（浅色主题）。
    // 同时把系统避让区高度换算成 vp 存 AppStorage，由 Index 根容器做 padding，
    // 这样背景铺满整屏、内容又不会顶到状态栏文字。
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch(() => {});
      const props: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#FF1A1A1F',
        navigationBarContentColor: '#FF1A1A1F'
      };
      win.setWindowSystemBarProperties(props).catch(() => {});
      const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 保留 px 原值；UI 侧用 'XXpx' 字符串给 padding，避免已废弃的全局 px2vp。
      AppStorage.setOrCreate('ams_safe_top', area.topRect.height);
      AppStorage.setOrCreate('ams_safe_bottom', area.bottomRect.height);
    } catch (e) {
      // 某些设备/窗口模式拿不到主窗口时降级为非沉浸，不影响功能。
      AppStorage.setOrCreate('ams_safe_top', 0);
      AppStorage.setOrCreate('ams_safe_bottom', 0);
      Logger.warn('EntryAbility', 'immersive setup skipped');
    }
  }
}
