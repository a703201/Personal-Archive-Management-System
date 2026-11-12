import { ApiClient, MeData, ChangePasswordBody } from '../common/api/ApiClient';
import { AuthStore } from '../common/store/AuthStore';
import { Settings } from '../common/store/Settings';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';
import { ABOUT, aboutOrPlaceholder } from '../config/About';

@Component
export struct SettingsPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @StorageLink('ams_dark') darkOn: boolean = false;
  @StorageLink('ams_large') largeOn: boolean = false;
  @StorageLink('ams_lang') lang: string = 'zh-CN';
  @State me: MeData = { id: 0, username: '', nickname: '', email: '', phone: '', status: 0, perms: [] };
  @State serverUrl: string = AuthStore.getBaseUrl();
  @State savedTip: string = '';
  @State loadingMe: boolean = false;
  @State errorMsg: string = '';
  @State showPassword: boolean = false;
  @State oldPwd: string = '';
  @State newPwd: string = '';
  @State pwdBusy: boolean = false;
  @State pwdTip: string = '';

  aboutToAppear(): void {
    this.loadMe();
  }

  onThemeRev(): void {
    applyTheme();
  }

  goFeature(name: string): void {
    this.navPathStack.pushPath({ name: name });
  }

  loadMe(): void {
    this.loadingMe = true;
    ApiClient.getMe().then((d: MeData) => {
      this.me = d;
      this.loadingMe = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loadingMe = false;
      Logger.warn('SettingsPage', 'me failed: ' + e.message);
    });
  }

  saveServer(): void {
    AuthStore.setBaseUrl(this.serverUrl);
    this.serverUrl = AuthStore.getBaseUrl();
    this.savedTip = t('settings.saved');
  }

  goRecycleBin(): void {
    this.navPathStack.pushPath({ name: 'RecycleBin' });
  }

  goAbout(): void {
    this.navPathStack.pushPath({ name: 'About' });
  }

  changePassword(): void {
    this.pwdTip = '';
    if (this.oldPwd.length === 0 || this.newPwd.length === 0) {
      this.pwdTip = t('settings.pwdEmpty');
      return;
    }
    const body: ChangePasswordBody = {
      oldPassword: this.oldPwd,
      newPassword: this.newPwd
    };
    this.pwdBusy = true;
    ApiClient.changePassword(body).then(() => {
      this.pwdBusy = false;
      this.oldPwd = '';
      this.newPwd = '';
      this.pwdTip = t('settings.pwdChanged');
    }).catch((e: Error) => {
      this.pwdBusy = false;
      this.pwdTip = e.message;
      Logger.warn('SettingsPage', 'changePassword failed: ' + e.message);
    });
  }

  doLogout(): void {
    // 本地优先：无论服务端注销是否成功，都清空本机登录态。
    ApiClient.logout().then(() => {
      AuthStore.clear();
    }).catch((e: Error) => {
      Logger.warn('SettingsPage', 'logout failed: ' + e.message);
      AuthStore.clear();
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          // 账号
          Text(t('settings.account'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            if (this.loadingMe) {
              Row() {
                LoadingProgress().width(20).height(20)
                Text(t('common.loading')).fontSize(F.caption).fontColor(C.ink3).margin({ left: 10 })
              }
              .padding(16)
            } else {
              this.infoRow(t('settings.username'), aboutOrPlaceholder(this.me.username))
              this.infoRow(t('settings.nickname'), aboutOrPlaceholder(this.me.nickname))
              this.infoRow(t('settings.email'), aboutOrPlaceholder(this.me.email))
              this.infoRow(t('settings.phone'), aboutOrPlaceholder(this.me.phone))
            }
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 24 })

          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(F.caption)
              .fontColor(C.danger)
              .padding({ left: 4, bottom: 8 })
          }

          // 外观：深色模式 / 三语 / 大字模式（AppStorage + preferences 持久化）
          Text(t('settings.appearance'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            Row() {
              Column() {
                Text(t('settings.dark')).fontSize(F.body).fontColor(C.ink)
                Text(t('settings.darkDesc')).fontSize(F.caption).fontColor(C.ink3).margin({ top: 2 })
              }
              .layoutWeight(1)
              Button(this.darkOn ? t('settings.on') : t('settings.off'))
                .height(32)
                .fontSize(F.caption)
                .backgroundColor(this.darkOn ? C.accent : C.surfaceAlt)
                .fontColor(this.darkOn ? '#FFFFFF' : C.ink2)
                .borderRadius(C.radiusSm)
                .onClick(() => { Settings.setDark(!this.darkOn); })
            }
            .width('100%')
            .padding(16)

            Row() {
              Column() {
                Text(t('settings.large')).fontSize(F.body).fontColor(C.ink)
                Text(t('settings.largeDesc')).fontSize(F.caption).fontColor(C.ink3).margin({ top: 2 })
              }
              .layoutWeight(1)
              Button(this.largeOn ? t('settings.on') : t('settings.off'))
                .height(32)
                .fontSize(F.caption)
                .backgroundColor(this.largeOn ? C.accent : C.surfaceAlt)
                .fontColor(this.largeOn ? '#FFFFFF' : C.ink2)
                .borderRadius(C.radiusSm)
                .onClick(() => { Settings.setLarge(!this.largeOn); })
            }
            .width('100%')
            .padding(16)
            .borderWidth({ top: 1 }).borderColor(C.hairline)

            Column() {
              Text(t('settings.lang')).fontSize(F.body).fontColor(C.ink)
              Row() {
                this.langBtn('简体中文', 'zh-CN')
                this.langBtn('English', 'en')
                this.langBtn('Français', 'fr')
              }
              .width('100%')
              .margin({ top: 10 })
            }
            .width('100%')
            .padding(16)
            .borderWidth({ top: 1 }).borderColor(C.hairline)
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 24 })

          // 功能入口：补完的高级能力
          Text(t('settings.features'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            this.featureRow(t('nav.subjects'), 'Subjects')
            this.featureRow(t('nav.tags'), 'Tags')
            this.featureRow(t('nav.share'), 'ShareLinks')
            this.featureRow(t('nav.templates'), 'Templates')
            this.featureRow(t('nav.system'), 'System')
            this.featureRow(t('nav.family'), 'Family')
            this.featureRow(t('nav.tasks'), 'Tasks')
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .clip(true)
          .margin({ bottom: 24 })

          // 安全：修改登录口令（折叠，避免设置页过长）
          Text(t('settings.security'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            Row() {
              Text(t('settings.password'))
                .fontSize(F.body)
                .fontColor(C.ink)
                .layoutWeight(1)
              Text(this.showPassword ? t('common.collapse') : t('common.expand'))
                .fontSize(F.caption)
                .fontColor(C.accent)
            }
            .width('100%')
            .padding(16)
            .onClick(() => { this.showPassword = !this.showPassword; })

            if (this.showPassword) {
              Column() {
                TextInput({ placeholder: t('settings.oldPwdPh'), text: this.oldPwd })
                  .height(44)
                  .backgroundColor(C.surfaceAlt)
                  .borderRadius(C.radiusSm)
                  .padding({ left: 14 })
                  .fontSize(F.body)
                  .type(InputType.Password)
                  .onChange((v: string) => { this.oldPwd = v; })
                TextInput({ placeholder: t('settings.newPwdPh'), text: this.newPwd })
                  .height(44)
                  .backgroundColor(C.surfaceAlt)
                  .borderRadius(C.radiusSm)
                  .padding({ left: 14 })
                  .fontSize(F.body)
                  .type(InputType.Password)
                  .margin({ top: 10 })
                  .onChange((v: string) => { this.newPwd = v; })
                Row() {
                  if (this.pwdTip.length > 0) {
                    Text(this.pwdTip)
                      .fontSize(F.caption)
                      .fontColor(this.pwdTip === t('settings.pwdChanged') ? C.success : C.danger)
                      .layoutWeight(1)
                  } else {
                    Text(t('settings.sessionWarn'))
                      .fontSize(F.caption)
                      .fontColor(C.ink3)
                      .layoutWeight(1)
                  }
                  Button(this.pwdBusy ? t('common.saving') : t('common.save'))
                    .height(34)
                    .fontSize(F.caption)
                    .backgroundColor(C.accent)
                    .fontColor('#FFFFFF')
                    .borderRadius(C.radiusSm)
                    .enabled(!this.pwdBusy)
                    .onClick(() => { this.changePassword(); })
                }
                .width('100%')
                .margin({ top: 12 })
              }
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 16 })
            }
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 24 })

          // 服务
          Text(t('settings.service'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            Text(t('settings.server'))
              .fontSize(F.body)
              .fontColor(C.ink)
              .padding({ left: 16, right: 16, top: 14 })
            TextInput({ placeholder: t('settings.serverPh'), text: this.serverUrl })
              .height(44)
              .backgroundColor(C.surfaceAlt)
              .borderRadius(C.radiusSm)
              .padding({ left: 12 })
              .fontSize(F.body)
              .margin({ left: 16, right: 16, top: 8 })
              .onChange((v: string) => {
                this.serverUrl = v;
                this.savedTip = '';
              })
            Row() {
              if (this.savedTip.length > 0) {
                Text(this.savedTip).fontSize(F.caption).fontColor(C.success).layoutWeight(1)
              } else {
                Text(t('settings.saveHint'))
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                  .layoutWeight(1)
              }
              Button(t('common.save'))
                .height(34)
                .fontSize(F.caption)
                .backgroundColor(C.accent)
                .fontColor('#FFFFFF')
                .borderRadius(C.radiusSm)
                .onClick(() => { this.saveServer(); })
            }
            .padding({ left: 16, right: 16, top: 12, bottom: 14 })
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 24 })

          // 功能入口（全宽圆角卡片 + 标签 + 右箭头）
          Text(t('settings.data'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Row() {
            Text(t('settings.recycle'))
              .fontSize(F.body)
              .fontColor(C.ink)
              .layoutWeight(1)
            Text('›').fontSize(20).fontColor(C.ink3)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .stateStyles({ pressed: { opacity: 0.7 } })
          .onClick(() => { this.goRecycleBin(); })
          .margin({ bottom: 24 })

          // 关于（点击进入独立关于页）
          Text(t('settings.about'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Row() {
            Column() {
              Text(ABOUT.productName)
                .fontSize(F.body)
                .fontColor(C.ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(t('about.version') + ' ' + ABOUT.version)
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            Text('›').fontSize(20).fontColor(C.ink3)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .stateStyles({ pressed: { opacity: 0.7 } })
          .onClick(() => { this.goAbout(); })
          .margin({ bottom: 24 })

          Button(t('settings.logout'))
            .width('100%')
            .height(48)
            .fontSize(F.body)
            .backgroundColor(C.surface)
            .fontColor(C.danger)
            .borderRadius(C.radius)
            .onClick(() => { this.doLogout(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('settings.title'))
    .backgroundColor(C.bg)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(F.body).fontColor(C.ink3).width(88)
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
  langBtn(label: string, code: string) {
    Text(label)
      .fontSize(F.caption)
      .fontColor(this.lang === code ? '#FFFFFF' : C.ink2)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.lang === code ? C.accent : C.surfaceAlt)
      .margin({ right: 8 })
      .onClick(() => { Settings.setLang(code); })
  }

  @Builder
  featureRow(label: string, name: string) {
    Row() {
      Text(label)
        .fontSize(F.body)
        .fontColor(C.ink)
        .layoutWeight(1)
      Text('›').fontSize(20).fontColor(C.ink3)
    }
    .width('100%')
    .padding(16)
    .borderWidth({ bottom: 1 }).borderColor(C.hairline)
    .stateStyles({ pressed: { opacity: 0.7 } })
    .onClick(() => { this.goFeature(name); })
  }
}
