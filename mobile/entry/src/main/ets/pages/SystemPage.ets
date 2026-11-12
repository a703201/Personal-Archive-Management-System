import {
  ApiClient, HealthData, SetupStatusData, BrandingData, LocalesData
} from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';

/**
 * 系统运维只读视图。system.cj / admin.cj 里的 /api/admin/* 读端点一律需要
 * system:admin / cfg:read（高权限），不在此越权调用；这里只用无需高权限的
 * 公开只读端点：/api/health、/api/setup/status、/api/branding、/api/i18n/locales。
 */
@Component
export struct SystemPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State health: HealthData = { status: '' };
  @State setup: SetupStatusData = {
    initialized: false,
    database: { host: '', port: '', name: '', user: '', configured: false },
    mail: { enabled: false, host: '', port: '', user: '', fromAddr: '', secure: '' }
  };
  @State branding: BrandingData = { brandName: '', logoUrl: '', notice: '', footerText: '', icpNo: '' };
  @State locales: LocalesData = { default: '', supported: [] };
  @State loading: boolean = false;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getHealth().then((d: HealthData) => {
      this.health = d;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      Logger.warn('SystemPage', 'health failed: ' + e.message);
    });
    ApiClient.getSetupStatus().then((d: SetupStatusData) => {
      this.setup = d;
    }).catch((e: Error) => {
      Logger.warn('SystemPage', 'setup failed: ' + e.message);
    });
    ApiClient.getBranding().then((d: BrandingData) => {
      this.branding = d;
    }).catch((e: Error) => {
      Logger.warn('SystemPage', 'branding failed: ' + e.message);
    });
    ApiClient.getLocales().then((d: LocalesData) => {
      this.locales = d;
      this.loading = false;
    }).catch((e: Error) => {
      this.loading = false;
      Logger.warn('SystemPage', 'locales failed: ' + e.message);
    });
  }

  joined(list: string[]): string {
    let out: string = '';
    for (let i = 0; i < list.length; i++) {
      if (i > 0) {
        out = out + ' / ';
      }
      out = out + list[i];
    }
    return out.length > 0 ? out : '—';
  }

  dbText(): string {
    const db: string = this.setup.database.host + ':' + this.setup.database.port
      + ' / ' + this.setup.database.name;
    return db + '（' + (this.setup.database.configured ? t('sys.configured') : t('sys.defaultVal')) + '）';
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          if (this.loading) {
            LoadingProgress().margin({ top: 30 })
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).padding({ bottom: 8 })
          }

          this.sectionTitle(t('sys.health'))
          Column() {
            Row() {
              Text(t('sys.serviceStatus')).fontSize(F.body).fontColor(C.ink3).width(96)
              Text(this.health.status.length > 0 ? this.health.status : '—')
                .fontSize(F.body)
                .fontColor(this.health.status === 'ok' ? C.success : C.ink)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          this.sectionTitle(t('sys.info'))
          Column() {
            this.infoRow(t('sys.init'), this.setup.initialized ? t('sys.done') : t('sys.undone'))
            this.infoRow(t('sys.database'), this.dbText())
            this.infoRow(t('sys.dbUser'), this.setup.database.user.length > 0 ? this.setup.database.user : '—')
            this.infoRow(t('sys.mail'), this.setup.mail.enabled ? t('sys.enabled') : t('sys.disabled'))
            this.infoRow(t('sys.mailHost'), this.setup.mail.host.length > 0 ? this.setup.mail.host : '—')
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          this.sectionTitle(t('sys.brand'))
          Column() {
            this.infoRow(t('field.name'), this.branding.brandName.length > 0 ? this.branding.brandName : '—')
            this.infoRow(t('sys.notice'), this.branding.notice.length > 0 ? this.branding.notice : '—')
            this.infoRow(t('sys.footer'), this.branding.footerText.length > 0 ? this.branding.footerText : '—')
            this.infoRow(t('sys.icp'), this.branding.icpNo.length > 0 ? this.branding.icpNo : '—')
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          this.sectionTitle(t('sys.i18n'))
          Column() {
            this.infoRow(t('sys.defaultLang'), this.locales.default.length > 0 ? this.locales.default : '—')
            this.infoRow(t('sys.supportedLang'), this.joined(this.locales.supported))
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          Text(t('sys.note'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .width('100%')
            .padding({ left: 4, bottom: 12 })

          Button(t('common.refresh'))
            .width('100%')
            .height(44)
            .fontSize(F.body)
            .backgroundColor(C.surfaceAlt)
            .fontColor(C.ink)
            .borderRadius(C.radiusSm)
            .onClick(() => { this.load(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('nav.system'))
    .backgroundColor(C.bg)
  }

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(F.caption)
      .fontColor(C.ink3)
      .width('100%')
      .padding({ left: 4, bottom: 8 })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(F.body).fontColor(C.ink3).width(96)
      Text(value)
        .fontSize(F.body)
        .fontColor(C.ink)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .borderWidth({ bottom: 1 }).borderColor(C.hairline)
  }
}
