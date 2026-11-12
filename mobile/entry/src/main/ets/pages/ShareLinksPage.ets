import {
  ApiClient, ShareLinksData, ShareLinkItem, CreateShareLinkRequest, CreateShareLinkData
} from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars } from '../common/theme/I18n';
import { formatDateTime } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

/** 共享链接：GET/POST /api/share-links、DELETE /api/share-links/:id（share.cj）。 */
@Component
export struct ShareLinksPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State links: ShareLinkItem[] = [];
  @State total: number = 0;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State showCreate: boolean = false;
  @State itemId: string = '';
  @State hours: string = '72';
  @State maxFails: string = '5';
  @State password: string = '';
  @State created: CreateShareLinkData = {
    id: '', token: '', url: '', protected: false, maxFails: 0, expiresAt: 0
  };
  @State createdShown: boolean = false;
  @State confirmId: string = '';

  aboutToAppear(): void {
    try {
      const last: string | undefined = AppStorage.get<string>('ams_last_item_id');
      if (last !== undefined) {
        this.itemId = last;
      }
    } catch (e) {}
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getShareLinks().then((d: ShareLinksData) => {
      this.links = d.items;
      this.total = d.total;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('ShareLinksPage', 'list failed: ' + e.message);
    });
  }

  numberOr(text: string, dflt: number): number {
    const n: number = parseInt(text, 10);
    return n > 0 ? n : dflt;
  }

  createLink(): void {
    const iid: number = this.numberOr(this.itemId.trim(), 0);
    if (iid <= 0) {
      this.tip = t('share.needItemId');
      return;
    }
    const body: CreateShareLinkRequest = {
      itemId: iid,
      expiresInHours: this.numberOr(this.hours, 72),
      maxFails: this.numberOr(this.maxFails, 5)
    };
    if (this.password.trim().length > 0) {
      body.password = this.password.trim();
    }
    this.busy = true;
    ApiClient.createShareLink(body).then((d: CreateShareLinkData) => {
      this.busy = false;
      this.created = d;
      this.createdShown = true;
      this.tip = t('share.createdTip');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('ShareLinksPage', 'create failed: ' + e.message);
    });
  }

  revoke(id: string): void {
    this.busy = true;
    ApiClient.revokeShareLink(id).then(() => {
      this.busy = false;
      this.confirmId = '';
      this.tip = t('share.revokedTip');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.confirmId = '';
      this.tip = e.message;
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Button(this.showCreate ? t('share.collapseCreate') : t('share.create'))
              .layoutWeight(1)
              .height(44)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .onClick(() => { this.showCreate = !this.showCreate; })
            Button(t('common.refresh'))
              .height(44)
              .fontSize(F.body)
              .backgroundColor(C.surfaceAlt)
              .fontColor(C.ink)
              .borderRadius(C.radiusSm)
              .margin({ left: 8 })
              .onClick(() => { this.load(); })
          }
          .width('100%')
          .margin({ bottom: 12 })

          if (this.showCreate) {
            Column() {
              this.inputRow(t('field.itemId'), t('common.numericId'), this.itemId, 1)
              this.inputRow(t('field.expiresHours'), t('share.defHours'), this.hours, 2)
              this.inputRow(t('share.maxFails'), t('share.defFails'), this.maxFails, 3)
              this.inputRow(t('field.password'), t('share.pwdOptDesc'), this.password, 4)
              Button(this.busy ? t('common.creating') : t('common.create'))
                .width('100%')
                .height(44)
                .fontSize(F.body)
                .backgroundColor(C.accent)
                .fontColor('#FFFFFF')
                .borderRadius(C.radiusSm)
                .margin({ top: 12 })
                .enabled(!this.busy)
                .onClick(() => { this.createLink(); })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .margin({ bottom: 12 })
          }

          if (this.createdShown) {
            Column() {
              Text(t('share.newLinkHint'))
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .padding({ bottom: 6 })
              Text(this.created.url)
                .fontSize(F.body)
                .fontColor(C.accent)
                .width('100%')
              Text(t('share.token') + this.created.token)
                .fontSize(F.caption)
                .fontColor(C.ink2)
                .width('100%')
                .padding({ top: 4 })
              Text(t('share.expiry') + formatDateTime(this.created.expiresAt)
                + (this.created.protected ? ' · ' + t('share.protected') : ''))
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .width('100%')
                .padding({ top: 4 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.accentSoft)
            .borderRadius(C.radius)
            .margin({ bottom: 12 })
          }

          if (this.tip.length > 0) {
            Text(this.tip).fontSize(F.caption).fontColor(C.success).padding({ bottom: 8 })
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).padding({ bottom: 8 })
          }

          Text(t('share.total', i18nVars([['n', this.total.toString()]])))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .width('100%')
            .padding({ left: 4, bottom: 8 })

          if (this.loading && this.links.length === 0) {
            LoadingProgress().margin({ top: 30 })
          } else if (this.links.length === 0) {
            Text(t('share.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 30 })
          } else {
            Column() {
              ForEach(this.links, (l: ShareLinkItem) => {
                this.linkRow(l)
              }, (l: ShareLinkItem) => l.id)
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .clip(true)
          }
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('nav.share'))
    .backgroundColor(C.bg)
  }

  onField(kind: number, v: string): void {
    if (kind === 1) {
      this.itemId = v;
    } else if (kind === 2) {
      this.hours = v;
    } else if (kind === 3) {
      this.maxFails = v;
    } else if (kind === 4) {
      this.password = v;
    }
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, kind: number) {
    Column() {
      Text(label).fontSize(F.caption).fontColor(C.ink3).padding({ left: 4, bottom: 6 })
      TextInput({ placeholder: placeholder, text: value })
        .width('100%')
        .height(44)
        .backgroundColor(C.surfaceAlt)
        .borderRadius(C.radiusSm)
        .padding({ left: 14 })
        .fontSize(F.body)
        .onChange((v: string) => { this.onField(kind, v); })
    }
    .width('100%')
    .padding({ top: 6 })
  }

  @Builder
  linkRow(l: ShareLinkItem) {
    Column() {
      Row() {
        Text(l.itemId.length > 0 ? (t('item.entry') + ' ' + l.itemId) : t('share.link'))
          .fontSize(F.body)
          .fontWeight(600)
          .fontColor(C.ink)
          .layoutWeight(1)
        Text(l.revoked ? t('share.revoked') : (l.expired ? t('share.expired') : t('share.valid')))
          .fontSize(F.caption)
          .fontColor(l.revoked ? C.danger : (l.expired ? C.warn : C.success))
      }
      .width('100%')
        Text(t('share.tokenInline') + l.token)
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(t('share.linkMeta', i18nVars([['views', l.viewCount.toString()], ['fails', l.failCount.toString()]]))
        + formatDateTime(l.expiresAt))
        .fontSize(11)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
      if (!l.revoked) {
        Row() {
          Button(this.confirmId === l.id ? t('share.confirmRevoke') : t('share.revoke'))
            .height(32)
            .fontSize(F.caption)
            .backgroundColor(this.confirmId === l.id ? C.danger : C.surfaceAlt)
            .fontColor(this.confirmId === l.id ? '#FFFFFF' : C.danger)
            .borderRadius(C.radiusSm)
            .enabled(!this.busy)
            .onClick(() => {
              if (this.confirmId === l.id) {
                this.revoke(l.id);
              } else {
                this.confirmId = l.id;
              }
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(16)
    .borderWidth({ bottom: 1 }).borderColor(C.hairline)
  }
}
