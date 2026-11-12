import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { ApiClient, CaptchaData, LoginData } from '../common/api/ApiClient';
import { AuthStore } from '../common/store/AuthStore';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';

@Component
export struct LoginPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State username: string = '';
  @State password: string = '';
  @State captchaId: string = '';
  @State captchaInput: string = '';
  @State captchaHtml: string = '';
  @State loading: boolean = false;
  @State captchaLoading: boolean = false;
  @State errorMsg: string = '';
  @State needCaptcha: boolean = false;
  @State serverUrl: string = AuthStore.getBaseUrl();
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 登录看门狗句柄：后端挂起时强制复位 loading，避免永久停在「登录中…」。 */
  private loginTimer: number = -1;

  aboutToAppear(): void {
    this.refreshCaptcha();
  }

  onThemeRev(): void {
    applyTheme();
  }

  aboutToDisappear(): void {
    this.clearLoginTimer();
  }

  clearLoginTimer(): void {
    if (this.loginTimer !== -1) {
      clearTimeout(this.loginTimer);
      this.loginTimer = -1;
    }
  }

  /**
   * 把 SVG 单独 base64 后塞进 <img> 的 data URL。
   *
   * 为什么不直接内联 SVG：后端 SVG 的颜色值含大量 '#'（如 #2b3a55），
   * 而 loadData 的 data 里 '#' 会被当成内容结束符，后面的内容全部丢失。
   * base64 字符集不含 '#'，因此外层 HTML 里完全没有 '#'，整段内容完整。
   * Web 内核负责解码 <img> 的 data:image/svg+xml;base64 并显示图形。
   *
   * 注意：HarmonyOS 的 Image 组件**明确不支持** SVG 的 base64 字符串
   * （SDK image.d.ts:464），所以只能走 Web 组件，不能用 Image 替代。
   */
  buildCaptchaHtml(svg: string): string {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(svg);
    const b64: string = new util.Base64Helper().encodeToStringSync(bytes);
    return '<!DOCTYPE html><html><head><meta charset="utf-8"></head>' +
      '<body style="margin:0;padding:0;display:flex;align-items:center;' +
      'justify-content:center;background:rgb(240,241,244)">' +
      '<img src="data:image/svg+xml;base64,' + b64 + '" width="180" height="52"></body></html>';
  }

  /**
   * encoding 必须传字符集 'UTF-8'：本机 SDK（@ohos.web.webview.d.ts:3004）
   * 对 encoding 的说明是 "Encoding type. For example: UTF-8"，传 'base64'
   * 并不会被解码，整段 base64 会被当作纯文本显示（即用户看到的那串英文数字）。
   */
  renderCaptcha(): void {
    if (this.captchaHtml.length === 0) {
      return;
    }
    try {
      this.controller.loadData(this.captchaHtml, 'text/html', 'UTF-8');
    } catch (e) {
      // Controller 尚未 attach，等 onControllerAttached 回调再渲染一次。
      Logger.warn('LoginPage', 'loadData before controller attached');
    }
  }

  refreshCaptcha(): void {
    // 输入框里刚改的 IP 要先落盘，否则这次请求仍会打到旧地址。
    // 只在刷新/登录时写一次，避免每敲一个字符都 flush。
    AuthStore.setBaseUrl(this.serverUrl);
    this.captchaLoading = true;
    const oldId: string = this.captchaId;
    ApiClient.getCaptcha(oldId).then((data: CaptchaData) => {
      this.captchaId = data.captchaId;
      this.captchaHtml = this.buildCaptchaHtml(data.svg);
      this.captchaLoading = false;
      // 只清掉「验证码加载失败」这一类旧提示，保留真正的登录错误。
      if (this.errorMsg.indexOf(t('login.captchaLoadFail')) >= 0) {
        this.errorMsg = '';
      }
      this.renderCaptcha();
    }).catch((e: Error) => {
      this.errorMsg = t('login.captchaLoadFail') + e.message;
      this.captchaLoading = false;
      Logger.warn('LoginPage', 'captcha failed: ' + e.message);
    });
  }

  doLogin(): void {
    this.errorMsg = '';
    AuthStore.setBaseUrl(this.serverUrl);
    if (this.username.length === 0 || this.password.length === 0) {
      this.errorMsg = t('login.emptyCred');
      return;
    }
    // 验证码不是每次登录的必填项：后端仅在「该账号连续登录失败 >= 3 次」
    // 才强制校验（FR-AUTH-011）。这里不做前端硬性拦截，与 Web 端一致。
    this.loading = true;
    this.clearLoginTimer();
    // 后端曾出现全局 dead lock（所有请求 30s 后才返回 500），HTTP 层的
    // readTimeout 在部分设备上不一定能打断；这里加一层应用层看门狗，
    // 保证 loading 一定会复位并给出可操作的提示。
    this.loginTimer = setTimeout(() => {
      this.loginTimer = -1;
      if (this.loading) {
        this.loading = false;
        this.errorMsg = t('login.timeout');
      }
    }, 15000);

    ApiClient.login(this.username, this.password, this.captchaId, this.captchaInput.trim())
      .then((data: LoginData) => {
        // 先复位 UI，再写登录态：save 会触发页面切换，不应挡住 loading 复位。
        this.loading = false;
        this.clearLoginTimer();
        AuthStore.save(data.accessToken, data.refreshToken);
      })
      .catch((e: Error) => {
        this.loading = false;
        this.clearLoginTimer();
        this.errorMsg = e.message ?? t('login.fail');
        // 后端触发风控后返回含「验证码」的中文提示，此时清空输入并刷新挑战。
        if (this.errorMsg.indexOf('验证码') >= 0) {
          this.needCaptcha = true;
          this.captchaInput = '';
          this.refreshCaptcha();
        }
      });
  }

  build() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(72)
        .height(72)
        .borderRadius(18)
        .alignSelf(ItemAlign.Center)
        .margin({ top: 56, bottom: 8 })

      Column() {
        Text(t('common.archive'))
          .fontSize(F.display)
          .fontWeight(700)
          .fontColor(C.ink)
          .letterSpacing(-0.5)
        Text(t('common.brandPrefix') + t('common.tagline'))
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .margin({ top: 6 })
      }
      // Column 默认水平居中会让「档案库」相对副标题居中、整块又靠左，
      // 视觉上比输入框偏右一截（歪）。显式左对齐，与副标题 / 输入框同边距线。
      .alignItems(HorizontalAlign.Start)
      .alignSelf(ItemAlign.Start)
      .margin({ top: 72, bottom: 44, left: F.pad })

      Column() {
        TextInput({ placeholder: t('login.serverPh'), text: this.serverUrl })
          .height(48)
          .backgroundColor(C.surfaceAlt)
          .borderRadius(C.radiusSm)
          .padding({ left: 16 })
          .fontSize(F.body)
          .onChange((v: string) => { this.serverUrl = v; })
          .margin({ bottom: 12 })

        TextInput({ placeholder: t('login.userPh') })
          .height(48)
          .backgroundColor(C.surfaceAlt)
          .borderRadius(C.radiusSm)
          .padding({ left: 16 })
          .fontSize(F.body)
          .onChange((v: string) => { this.username = v; })

        TextInput({ placeholder: t('login.pwdPh') })
          .height(48)
          .backgroundColor(C.surfaceAlt)
          .borderRadius(C.radiusSm)
          .padding({ left: 16 })
          .fontSize(F.body)
          .type(InputType.Password)
          .margin({ top: 12 })
          .onChange((v: string) => { this.password = v; })

        Row() {
          Web({ src: '', controller: this.controller })
            .layoutWeight(1)
            .height(48)
            .borderRadius(C.radiusSm)
            .backgroundColor(C.surfaceAlt)
            .javaScriptAccess(false)
            .domStorageAccess(false)
            .onControllerAttached(() => { this.renderCaptcha(); })
          Text(this.captchaLoading ? t('common.loading') : t('common.refresh'))
            .fontSize(F.caption)
            .fontColor(C.accent)
            .padding(12)
            .onClick(() => { this.refreshCaptcha(); })
        }
        .margin({ top: 12 })
        .height(48)

        TextInput({ placeholder: this.needCaptcha ? t('login.captchaPh') : t('login.captchaPhOpt') })
          .height(48)
          .backgroundColor(C.surfaceAlt)
          .borderRadius(C.radiusSm)
          .padding({ left: 16 })
          .fontSize(F.body)
          .margin({ top: 12 })
          .onChange((v: string) => { this.captchaInput = v; })

        Text(t('login.captchaHint'))
          .fontSize(11)
          .fontColor(C.ink3)
          .margin({ top: 8, left: 4 })

        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(F.caption)
            .fontColor(C.danger)
            .margin({ top: 12 })
        }

        Button(this.loading ? t('login.loggingIn') : t('login.loginBtn'))
          .width('100%')
          .height(50)
          .borderRadius(C.radiusSm)
          .backgroundColor(C.accent)
          .fontColor('#FFFFFF')
          .fontSize(F.body)
          .fontWeight(600)
          .margin({ top: 24 })
          .enabled(!this.loading)
          .onClick(() => { this.doLogin(); })
      }
      .padding({ left: F.pad, right: F.pad })

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C.bg)
  }
}
