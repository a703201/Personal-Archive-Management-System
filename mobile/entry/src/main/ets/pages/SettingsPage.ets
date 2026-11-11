import { ApiClient, MeData, ChangePasswordBody } from '../common/api/ApiClient';
import { AuthStore } from '../common/store/AuthStore';
import { C, F } from '../common/theme/Theme';
import { Logger } from '../common/utils/Logger';
import { ABOUT, aboutOrPlaceholder } from '../config/About';

@Component
export struct SettingsPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
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
    this.savedTip = '已保存';
  }

  goRecycleBin(): void {
    this.navPathStack.pushPath({ name: 'RecycleBin' });
  }

  changePassword(): void {
    this.pwdTip = '';
    if (this.oldPwd.length === 0 || this.newPwd.length === 0) {
      this.pwdTip = '请输入原口令与新口令';
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
      this.pwdTip = '口令已修改';
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
          Text('账号')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            if (this.loadingMe) {
              Row() {
                LoadingProgress().width(20).height(20)
                Text('加载中…').fontSize(F.caption).fontColor(C.ink3).margin({ left: 10 })
              }
              .padding(16)
            } else {
              this.infoRow('用户名', aboutOrPlaceholder(this.me.username))
              this.infoRow('昵称', aboutOrPlaceholder(this.me.nickname))
              this.infoRow('邮箱', aboutOrPlaceholder(this.me.email))
              this.infoRow('手机号', aboutOrPlaceholder(this.me.phone))
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

          // 安全：修改登录口令（折叠，避免设置页过长）
          Text('安全')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            Row() {
              Text('修改口令')
                .fontSize(F.body)
                .fontColor(C.ink)
                .layoutWeight(1)
              Text(this.showPassword ? '收起' : '展开')
                .fontSize(F.caption)
                .fontColor(C.accent)
            }
            .width('100%')
            .padding(16)
            .onClick(() => { this.showPassword = !this.showPassword; })

            if (this.showPassword) {
              Column() {
                TextInput({ placeholder: '原口令', text: this.oldPwd })
                  .height(44)
                  .backgroundColor(C.surfaceAlt)
                  .borderRadius(C.radiusSm)
                  .padding({ left: 14 })
                  .fontSize(F.body)
                  .type(InputType.Password)
                  .onChange((v: string) => { this.oldPwd = v; })
                TextInput({ placeholder: '新口令', text: this.newPwd })
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
                      .fontColor(this.pwdTip === '口令已修改' ? C.success : C.danger)
                      .layoutWeight(1)
                  } else {
                    Text('修改后其它会话可能失效')
                      .fontSize(F.caption)
                      .fontColor(C.ink3)
                      .layoutWeight(1)
                  }
                  Button(this.pwdBusy ? '保存中…' : '保存')
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
          Text('服务')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            Text('服务器地址')
              .fontSize(F.body)
              .fontColor(C.ink)
              .padding({ left: 16, right: 16, top: 14 })
            TextInput({ placeholder: 'IP 或域名', text: this.serverUrl })
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
                Text('修改后保存，下次请求生效')
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                  .layoutWeight(1)
              }
              Button('保存')
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
          Text('数据')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Row() {
            Text('回收站')
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

          // 关于
          Text('关于')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 10 })
          Column() {
            this.infoRow('产品', ABOUT.productName)
            this.infoRow('版本', ABOUT.version)
            this.infoRow('作者', aboutOrPlaceholder(ABOUT.authorName))
            this.infoRow('联系邮箱', aboutOrPlaceholder(ABOUT.authorEmail))
            this.infoRow('许可证', ABOUT.license)
          }
          .width('100%')
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 24 })

          Button('退出登录')
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
    .title('设置')
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
}
