import { common, Want } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t } from '../common/theme/I18n';
import { ABOUT, aboutOrPlaceholder, AboutLink } from '../config/About';
import { Settings } from '../common/store/Settings';
import { Logger } from '../common/utils/Logger';

/**
 * 关于页：产品 / 版本 / 作者 / 简介 / 技术栈 / 外链。
 * 文案全部走 t()，支持 zh-CN / en / fr 三语；外链以隐式 Want
 * （ohos.want.action.viewData）唤起系统默认浏览器，空 href 渲染为「待配置」占位项。
 */
@Component
export struct AboutPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State toast: string = '';
  private toastTimer: number = 0;

  aboutToAppear(): void {
    this.toast = '';
    this.toastTimer = 0;
  }

  aboutToDisappear(): void {
    if (this.toastTimer !== 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = 0;
    }
  }

  onThemeRev(): void {
    applyTheme();
  }

  private openExternal(url: string): void {
    if (url.length === 0) {
      return;
    }
    const ctx = AppStorage.get('context') as common.UIAbilityContext;
    if (ctx === undefined || ctx === null) {
      Logger.warn('AboutPage', 'no UIAbilityContext');
      return;
    }
    const want: Want = { action: 'ohos.want.action.viewData', uri: url };
    ctx.startAbility(want).catch((e: BusinessError) => {
      Logger.warn('AboutPage', 'openExternal failed: ' + e.message);
    });
  }

  private copyText(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.showToast(t('about.copied'));
      }).catch((e: BusinessError) => {
        Logger.warn('AboutPage', 'copy failed: ' + e.message);
      });
    } catch (e) {
      Logger.warn('AboutPage', 'copy failed');
    }
  }

  private showToast(msg: string): void {
    this.toast = msg;
    if (this.toastTimer !== 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = 0;
    }, 1600);
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Scroll() {
          Column() {
            this.headerSection()

            this.sectionTitle(t('about.introTitle'))
            Column() {
              Text(t('about.summary1'))
                .fontSize(F.body)
                .fontColor(C.ink)
                .lineHeight(F.body * 1.6)
              Text(t('about.summary2'))
                .fontSize(F.body)
                .fontColor(C.ink)
                .lineHeight(F.body * 1.6)
                .margin({ top: 12 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)

            this.sectionTitle(t('about.stackTitle'))
            Column() {
              Row() {
                this.stackChip(t('about.stack1'))
                this.stackChip(t('about.stack2'))
              }
              .width('100%')
              Row() {
                this.stackChip(t('about.stack3'))
                this.stackChip(t('about.stack4'))
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(C.surface)
            .borderRadius(C.radius)

            this.sectionTitle(t('about.versionTitle'))
            Column() {
              this.infoRow(t('about.version'), ABOUT.version)
              this.infoRow(t('about.releaseDate'), aboutOrPlaceholder(ABOUT.releaseDate))
              this.infoRow(t('about.license'), ABOUT.license)
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)

            this.sectionTitle(t('about.authorTitle'))
            Column() {
              this.authorRow(t('about.authorName'), aboutOrPlaceholder(ABOUT.authorName))
              this.authorRow(t('about.email'), aboutOrPlaceholder(ABOUT.authorEmail))
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)

            this.sectionTitle(t('about.linksTitle'))
            Column() {
              ForEach(ABOUT.links, (lnk: AboutLink) => {
                this.linkRow(lnk);
              }, (lnk: AboutLink) => lnk.key)
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)

            Text(t('about.configHint'))
              .fontSize(F.caption)
              .fontColor(C.ink3)
              .margin({ top: 14, left: 4, right: 4 })
          }
          .width('100%')
          .padding({ left: F.pad, right: F.pad, top: 16, bottom: 40 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(C.bg)

        if (this.toast.length > 0) {
          Text(this.toast)
            .fontSize(F.body)
            .fontColor('#FFFFFF')
            .backgroundColor('#1A1A1F')
            .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            .borderRadius(20)
            .margin({ bottom: 40 })
        }
      }
      .width('100%')
      .height('100%')
    }
    .title(t('about.eyebrow'))
    .backgroundColor(C.bg)
  }

  private productNameLocalized(): string {
    const lang: string = Settings.lang();
    return lang === 'en' ? ABOUT.productNameEn : (lang === 'fr' ? ABOUT.productNameFr : ABOUT.productName);
  }

  @Builder
  headerSection() {
    Column() {
      Text(this.productNameLocalized())
        .fontSize(F.title)
        .fontColor(C.ink)
        .fontWeight(FontWeight.Bold)
      Text(t('about.tagline'))
        .fontSize(F.body)
        .fontColor(C.ink2)
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 4, bottom: 18 })
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(F.caption)
      .fontColor(C.ink3)
      .padding({ left: 4, bottom: 10, top: 18 })
  }

  @Builder
  stackChip(label: string) {
    Text(label)
      .fontSize(F.caption)
      .fontColor(C.ink2)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(C.surfaceAlt)
      .borderRadius(14)
      .margin({ right: 8, bottom: 8 })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(F.body)
        .fontColor(C.ink3)
        .width(88)
      Text(value)
        .fontSize(F.body)
        .fontColor(C.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  authorRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(F.body)
        .fontColor(C.ink3)
        .width(88)
      Text(value)
        .fontSize(F.body)
        .fontColor(C.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(t('about.copy'))
        .fontSize(F.caption)
        .fontColor(C.accent)
        .padding({ left: 10 })
        .onClick(() => {
          this.copyText(value);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  @Builder
  linkRow(lnk: AboutLink) {
    Row() {
      Column() {
        Text(t(lnk.key))
          .fontSize(F.body)
          .fontColor(lnk.url.length > 0 ? C.ink : C.ink3)
        Text(t(lnk.key + 'Desc'))
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      if (lnk.url.length > 0) {
        Text('›')
          .fontSize(20)
          .fontColor(C.ink3)
      } else {
        Text(t('about.tbd'))
          .fontSize(F.caption)
          .fontColor(C.ink3)
      }
    }
    .width('100%')
    .padding(16)
    .borderWidth({ bottom: 1 })
    .borderColor(C.hairline)
    .stateStyles({ pressed: { opacity: 0.7 } })
    .onClick(() => {
      this.openExternal(lnk.url);
    })
  }
}
