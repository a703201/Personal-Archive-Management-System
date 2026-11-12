import { ApiClient, VersionsData, ItemVersion } from '../common/api/ApiClient';
import { ArchiveItem } from '../common/models/Models';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars } from '../common/theme/I18n';
import { formatDateTime } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

interface VersionSnapshot {
  title?: string;
  issuer?: string;
  remark?: string;
  sensitivity?: number;
  issuedDate?: string;
  expiresAt?: string;
}

/** 条目历史版本：GET /api/items/:id/versions、POST .../versions/:vid/restore（items.cj）。 */
@Component
export struct ItemVersionsPage {
  @Prop item: ArchiveItem = {} as ArchiveItem;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State versions: ItemVersion[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State confirmVid: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getItemVersions(this.item.id).then((d: VersionsData) => {
      this.versions = d.versions;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('ItemVersionsPage', 'list failed: ' + e.message);
    });
  }

  /** 把快照 JSON 解析成人类可读摘要；失败时回退原始串前若干字符。 */
  snapshotSummary(v: ItemVersion): string {
    try {
      const snap = JSON.parse(v.snapshot) as VersionSnapshot;
      const parts: string[] = [];
      if (snap.title !== undefined && snap.title.length > 0) {
        parts.push(snap.title);
      }
      if (snap.issuer !== undefined && snap.issuer.length > 0) {
        parts.push(snap.issuer);
      }
      if (snap.issuedDate !== undefined && snap.issuedDate.length > 0) {
        parts.push(snap.issuedDate);
      }
      if (parts.length > 0) {
        return parts.join(' · ');
      }
    } catch (e) {}
    return v.snapshot.length > 80 ? (v.snapshot.substring(0, 80) + '…') : v.snapshot;
  }

  restore(v: ItemVersion): void {
    this.busy = true;
    ApiClient.restoreItemVersion(this.item.id, v.id).then((from: number) => {
      this.busy = false;
      this.confirmVid = '';
      this.tip = t('versions.rolled', i18nVars([['n', from.toString()]]));
      DataRefresh.notify();
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.confirmVid = '';
      this.tip = e.message;
      Logger.warn('ItemVersionsPage', 'restore failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text(this.item.title.length > 0 ? this.item.title : t('item.entry'))
            .fontSize(F.body)
            .fontColor(C.ink)
            .layoutWeight(1)
          Button(t('common.refresh'))
            .height(38)
            .fontSize(F.caption)
            .backgroundColor(C.surfaceAlt)
            .fontColor(C.ink)
            .borderRadius(C.radiusSm)
            .onClick(() => { this.load(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 8 })

        if (this.tip.length > 0) {
          Text(this.tip).fontSize(F.caption).fontColor(C.success)
            .padding({ left: F.pad, right: F.pad, bottom: 6 })
        }
        if (this.errorMsg.length > 0) {
          Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger)
            .padding({ left: F.pad, right: F.pad, bottom: 6 })
        }

        if (this.loading && this.versions.length === 0) {
          LoadingProgress().margin({ top: 40 })
        } else if (this.versions.length === 0) {
          Text(t('versions.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 60 })
        } else {
          List() {
            ForEach(this.versions, (v: ItemVersion) => {
              ListItem() {
                this.versionRow(v)
              }
            }, (v: ItemVersion) => v.id)
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
    .title(t('nav.versions'))
    .backgroundColor(C.bg)
  }

  @Builder
  versionRow(v: ItemVersion) {
    Column() {
      Row() {
        Text(t('versions.version', i18nVars([['n', v.version.toString()]])))
          .fontSize(F.body)
          .fontWeight(600)
          .fontColor(C.ink)
          .layoutWeight(1)
        Text(formatDateTime(v.changedAt))
          .fontSize(F.caption)
          .fontColor(C.ink3)
      }
      .width('100%')
      Text(this.snapshotSummary(v))
        .fontSize(F.caption)
        .fontColor(C.ink2)
        .width('100%')
        .padding({ top: 6 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(t('versions.operator', i18nVars([['name', v.changedBy]])))
        .fontSize(11)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
      Row() {
        Button(this.confirmVid === v.id ? t('versions.confirmRollback') : t('versions.rollback'))
          .height(32)
          .fontSize(F.caption)
          .backgroundColor(this.confirmVid === v.id ? C.danger : C.accentSoft)
          .fontColor(this.confirmVid === v.id ? '#FFFFFF' : C.accent)
          .borderRadius(C.radiusSm)
          .enabled(!this.busy)
          .onClick(() => {
            if (this.confirmVid === v.id) {
              this.restore(v);
            } else {
              this.confirmVid = v.id;
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
  }
}
