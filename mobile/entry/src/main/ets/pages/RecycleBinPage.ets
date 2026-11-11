import { ApiClient, RecycleBinData } from '../common/api/ApiClient';
import { C, F } from '../common/theme/Theme';
import { ArchiveItem, categoryName } from '../common/models/Models';
import { formatDate } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

@Component
export struct RecycleBinPage {
  @StorageLink('ams_data_version') @Watch('onDataChanged') dataVersion: number = 0;
  @State items: ArchiveItem[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State busyId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onDataChanged(): void {
    this.load();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getRecycleBin().then((d: RecycleBinData) => {
      this.items = d.items;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('RecycleBinPage', 'load failed: ' + e.message);
    });
  }

  restore(it: ArchiveItem): void {
    this.busyId = it.id;
    ApiClient.restoreItem(it.id).then(() => {
      this.busyId = '';
      this.load();
    }).catch((e: Error) => {
      this.busyId = '';
      this.errorMsg = e.message;
      Logger.warn('RecycleBinPage', 'restore failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading && this.items.length === 0) {
          LoadingProgress().width(28).height(28).margin({ top: 60 })
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text(this.errorMsg).fontSize(F.body).fontColor(C.danger)
            Button('重试')
              .height(40)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .margin({ top: 16 })
              .onClick(() => { this.load(); })
          }
          .margin({ top: 60 })
        } else if (this.items.length === 0) {
          Text('暂无回收站条目')
            .fontSize(F.body)
            .fontColor(C.ink3)
            .margin({ top: 60 })
        } else {
          List() {
            ForEach(this.items, (it: ArchiveItem) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(it.title)
                      .fontSize(F.body)
                      .fontColor(C.ink)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(categoryName(it.category) + ' · ' + formatDate(it.updatedAt))
                      .fontSize(F.caption)
                      .fontColor(C.ink3)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  Button(this.busyId === it.id ? '恢复中…' : '恢复')
                    .height(32)
                    .fontSize(F.caption)
                    .backgroundColor(C.accentSoft)
                    .fontColor(C.accent)
                    .borderRadius(C.radiusSm)
                    .enabled(this.busyId.length === 0)
                    .onClick(() => { this.restore(it); })
                }
                .width('100%')
                .padding({ left: F.pad, right: F.pad, top: 12, bottom: 12 })
                .backgroundColor(C.surface)
              }
            }, (it: ArchiveItem) => it.id)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 1, color: C.hairline, startMargin: 16, endMargin: 16 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C.bg)
    }
    .title('回收站')
    .backgroundColor(C.bg)
  }
}
