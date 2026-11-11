import { ApiClient, StatusBody } from '../common/api/ApiClient';
import { C, F } from '../common/theme/Theme';
import { ArchiveItem, EditParam, categoryName } from '../common/models/Models';
import {
  sensitivityColor, sensitivityLabel, statusLabel, statusColor,
  nextStatus, nextStatusLabel, formatDate
} from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

@Component
export struct ItemDetailPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @StorageLink('ams_data_version') @Watch('onDataChanged') dataVersion: number = 0;
  @Prop item: ArchiveItem = {} as ArchiveItem;
  @State full: ArchiveItem = {} as ArchiveItem;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State confirmingDelete: boolean = false;
  @State deleting: boolean = false;
  @State busy: boolean = false;

  /** 用普通方法而非 get 访问器：ArkUI 状态变换器会整段丢弃 @Component 上的 get。 */
  currentItem(): ArchiveItem {
    return this.full.id ? this.full : this.item;
  }

  aboutToAppear(): void {
    this.load();
  }

  onDataChanged(): void {
    this.load();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getItem(this.item.id).then((d: ArchiveItem) => {
      this.full = d;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('ItemDetailPage', 'detail failed: ' + e.message);
    });
  }

  goEdit(): void {
    const cur: ArchiveItem = this.currentItem();
    const param: EditParam = {
      mode: 'edit',
      category: cur.category,
      subjectId: cur.subjectId,
      item: cur
    };
    this.navPathStack.pushPath({ name: 'ItemEdit', param: param });
  }

  /** 状态流转：草稿→正常→已归档，已归档可撤回为正常；带乐观锁版本。 */
  doTransition(): void {
    const cur: ArchiveItem = this.currentItem();
    const body: StatusBody = { status: nextStatus(cur.status), version: cur.version };
    this.busy = true;
    ApiClient.setItemStatus(cur.id, body).then(() => {
      this.busy = false;
      // @Watch 会触发 load() 重新拉取详情（version 已变）。
      DataRefresh.notify();
    }).catch((e: Error) => {
      this.busy = false;
      this.errorMsg = e.message;
      Logger.warn('ItemDetailPage', 'transition failed: ' + e.message);
    });
  }

  doClone(): void {
    const cur: ArchiveItem = this.currentItem();
    this.busy = true;
    ApiClient.cloneItem(cur.id).then((newId: string) => {
      this.busy = false;
      DataRefresh.notify();
      ApiClient.getItem(newId).then((item: ArchiveItem) => {
        this.navPathStack.pushPath({ name: 'ItemDetail', param: item });
      }).catch((e: Error) => {
        Logger.warn('ItemDetailPage', 'clone detail failed: ' + e.message);
      });
    }).catch((e: Error) => {
      this.busy = false;
      this.errorMsg = e.message;
      Logger.warn('ItemDetailPage', 'clone failed: ' + e.message);
    });
  }

  doDelete(): void {
    const cur: ArchiveItem = this.currentItem();
    this.deleting = true;
    ApiClient.deleteItem(cur.id, cur.version).then(() => {
      this.deleting = false;
      this.confirmingDelete = false;
      DataRefresh.notify();
      this.navPathStack.pop();
    }).catch((e: Error) => {
      this.deleting = false;
      this.confirmingDelete = false;
      this.errorMsg = e.message;
      Logger.warn('ItemDetailPage', 'delete failed: ' + e.message);
    });
  }

  @Builder
  field(label: string, value: string) {
    Row() {
      Text(label).fontSize(F.caption).fontColor(C.ink3).width(84)
      Text(value).fontSize(F.body).fontColor(C.ink).layoutWeight(1).fontWeight(400)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .borderWidth({ bottom: 1 }).borderColor(C.hairline)
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column() {
            if (this.loading) {
              LoadingProgress().margin({ top: 40 })
            } else {
              Text(this.currentItem().title)
                .fontSize(F.title).fontWeight(700).fontColor(C.ink)
                .margin({ top: 8, bottom: 4 })
              Row() {
                Text(categoryName(this.currentItem().category))
                  .fontSize(F.caption).fontColor(C.accent)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(8).backgroundColor(C.accentSoft)
                Text(sensitivityLabel(this.currentItem().sensitivity) + '敏感')
                  .fontSize(F.caption).fontColor(sensitivityColor(this.currentItem().sensitivity))
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(8).backgroundColor(C.surfaceAlt)
                Text(statusLabel(this.currentItem().status))
                  .fontSize(F.caption).fontColor(statusColor(this.currentItem().status))
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(8).backgroundColor(C.surfaceAlt)
              }
              .margin({ bottom: 16 })

              this.field('签发机构', this.currentItem().issuer ?? '—')
              this.field('签发日期', this.currentItem().issuedDate ?? '—')
              this.field('到期时间', this.currentItem().expiresAt ?? '—')
              this.field('更新时间', formatDate(this.currentItem().updatedAt))
              this.field('备注', this.currentItem().remark ?? '—')

              if (this.errorMsg.length > 0) {
                Text(this.errorMsg)
                  .fontSize(F.caption)
                  .fontColor(C.danger)
                  .margin({ top: 12 })
              }
            }
          }
          .padding({ left: F.pad, right: F.pad, top: 8, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)

        // 底部操作栏：拆两行，避免四个按钮挤在一行贴边
        Column() {
          Row() {
            Button('编辑')
              .layoutWeight(1)
              .height(42)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .enabled(!this.busy)
              .onClick(() => { this.goEdit(); })
            Button('克隆')
              .layoutWeight(1)
              .height(42)
              .fontSize(F.body)
              .backgroundColor(C.surfaceAlt)
              .fontColor(C.ink)
              .borderRadius(C.radiusSm)
              .margin({ left: 12 })
              .enabled(!this.busy)
              .onClick(() => { this.doClone(); })
          }
          .width('100%')

          Row() {
            Button(nextStatusLabel(this.currentItem().status))
              .layoutWeight(1)
              .height(42)
              .fontSize(F.body)
              .backgroundColor(C.accentSoft)
              .fontColor(C.accent)
              .borderRadius(C.radiusSm)
              .enabled(!this.busy)
              .onClick(() => { this.doTransition(); })
            Button(this.confirmingDelete ? '确认删除' : '删除')
              .layoutWeight(1)
              .height(42)
              .fontSize(F.body)
              .backgroundColor(this.confirmingDelete ? C.danger : C.surfaceAlt)
              .fontColor(this.confirmingDelete ? '#FFFFFF' : C.danger)
              .borderRadius(C.radiusSm)
              .margin({ left: 12 })
              .enabled(!this.deleting && !this.busy)
              .onClick(() => {
                if (this.confirmingDelete) {
                  this.doDelete();
                } else {
                  this.confirmingDelete = true;
                }
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Row() {
            Text('当前状态：' + statusLabel(this.currentItem().status))
              .fontSize(F.caption)
              .fontColor(statusColor(this.currentItem().status))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ top: 10 })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 20 })
        .backgroundColor(C.surface)
      }
      .width('100%')
      .height('100%')
    }
    .title('条目详情')
    .backgroundColor(C.bg)
  }
}
