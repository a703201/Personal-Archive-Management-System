import { ApiClient, NotificationsData, NotificationItem } from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t } from '../common/theme/I18n';
import { formatDateTime } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

@Component
export struct NotificationsPage {
  @StorageLink('ams_data_version') @Watch('onDataChanged') dataVersion: number = 0;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State items: NotificationItem[] = [];
  @State onlyUnread: boolean = false;
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State errorMsg: string = '';
  @State busyId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  onDataChanged(): void {
    this.load();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getNotifications(this.onlyUnread).then((d: NotificationsData) => {
      this.items = d.items;
      this.loading = false;
      this.refreshing = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      this.refreshing = false;
      Logger.warn('NotificationsPage', 'load failed: ' + e.message);
    });
  }

  /** is_read 后端可能给 't'/'f'、'true' 或布尔，统一判定。 */
  isUnread(n: NotificationItem): boolean {
    const v: string | boolean = n.is_read;
    if (typeof v === 'boolean') {
      return !v;
    }
    return v !== 't' && v !== 'true' && v !== '1';
  }

  isImportant(n: NotificationItem): boolean {
    return Number(n.priority) >= 2;
  }

  timeOf(n: NotificationItem): string {
    return formatDateTime(Number(n.created_at_ms));
  }

  switchFilter(unreadOnly: boolean): void {
    this.onlyUnread = unreadOnly;
    this.load();
  }

  markRead(n: NotificationItem): void {
    this.busyId = n.id;
    ApiClient.markNotificationRead(n.id).then(() => {
      this.busyId = '';
      DataRefresh.notify();
    }).catch((e: Error) => {
      this.busyId = '';
      this.errorMsg = e.message;
      Logger.warn('NotificationsPage', 'markRead failed: ' + e.message);
    });
  }

  markAllRead(): void {
    ApiClient.markAllNotificationsRead().then(() => {
      DataRefresh.notify();
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      Logger.warn('NotificationsPage', 'markAllRead failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text(t('common.all'))
            .fontSize(F.caption)
            .fontColor(!this.onlyUnread ? '#FFFFFF' : C.ink2)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(!this.onlyUnread ? C.accent : C.surface)
            .margin({ right: 8 })
            .onClick(() => { this.switchFilter(false); })
          Text(t('notify.unreadOnly'))
            .fontSize(F.caption)
            .fontColor(this.onlyUnread ? '#FFFFFF' : C.ink2)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor(this.onlyUnread ? C.accent : C.surface)
          Blank()
          Text(t('notify.markAllRead'))
            .fontSize(F.caption)
            .fontColor(C.accent)
            .onClick(() => { this.markAllRead(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 12 })

        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(F.caption)
            .fontColor(C.danger)
            .padding({ left: F.pad, right: F.pad, bottom: 8 })
        }

        if (this.loading && this.items.length === 0) {
          LoadingProgress().width(28).height(28).margin({ top: 60 })
        } else if (this.items.length === 0) {
          Text(t('notify.empty'))
            .fontSize(F.body)
            .fontColor(C.ink3)
            .margin({ top: 60 })
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            List() {
              ForEach(this.items, (n: NotificationItem) => {
                ListItem() {
                  Column() {
                    Row() {
                      if (this.isUnread(n)) {
                        Column()
                          .width(7).height(7).borderRadius(4)
                          .backgroundColor(C.accent)
                          .margin({ right: 8 })
                      }
                      Text(n.title)
                        .fontSize(F.body)
                        .fontWeight(this.isUnread(n) ? 600 : 400)
                        .fontColor(C.ink)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.isImportant(n)) {
                        Text(t('notify.important'))
                          .fontSize(11)
                          .fontColor(C.danger)
                          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                          .borderRadius(8)
                          .backgroundColor(C.surfaceAlt)
                      }
                    }
                    .width('100%')
                    Text(n.body)
                      .fontSize(F.caption)
                      .fontColor(C.ink2)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 8 })
                    Row() {
                      Text(this.timeOf(n))
                        .fontSize(11)
                        .fontColor(C.ink3)
                        .layoutWeight(1)
                      if (this.isUnread(n)) {
                        Text(this.busyId === n.id ? t('common.processing') : t('notify.markRead'))
                          .fontSize(F.caption)
                          .fontColor(C.accent)
                          .onClick(() => { this.markRead(n); })
                      }
                    }
                    .width('100%')
                    .margin({ top: 10 })
                  }
                  .width('100%')
                  .padding(16)
                  .backgroundColor(C.surface)
                }
              }, (n: NotificationItem) => n.id)
            }
            .width('100%')
            .height('100%')
            .divider({ strokeWidth: 1, color: C.hairline, startMargin: 16, endMargin: 16 })
          }
          .layoutWeight(1)
          .width('100%')
          .onRefreshing(() => { this.load(); })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C.bg)
    }
    .title(t('notify.title'))
    .backgroundColor(C.bg)
  }
}
