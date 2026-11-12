import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志封装（业务代码不直接调用 console / hilog）。
 * 域号 0x0000 为本地调试域，正式发布前可按规范替换。
 */
export class Logger {
  static DOMAIN: number = 0x0000;
  static TAG: string = 'AMS';

  static info(scope: string, msg: string): void {
    hilog.info(Logger.DOMAIN, Logger.TAG, '[%{public}s] %{public}s', scope, msg);
  }

  static warn(scope: string, msg: string): void {
    hilog.warn(Logger.DOMAIN, Logger.TAG, '[%{public}s] %{public}s', scope, msg);
  }

  static error(scope: string, msg: string): void {
    hilog.error(Logger.DOMAIN, Logger.TAG, '[%{public}s] %{public}s', scope, msg);
  }
}
