/**
 * 跨页面刷新信号。
 * 写入成功后发一次通知，列表 / 首页 / 回收站通过
 * @StorageLink + @Watch 自动重新拉取，避免返回后看到陈旧数据。
 */
export class DataRefresh {
  static KEY: string = 'ams_data_version';

  static notify(): void {
    AppStorage.setOrCreate(DataRefresh.KEY, Date.now());
  }
}
