import { fileIo, picker } from '@kit.CoreFileKit';
import {
  ApiClient, AttachmentsData, AttachmentItem, DownloadData, UploadData, UploadAttachmentParams
} from '../common/api/ApiClient';
import { ArchiveItem } from '../common/models/Models';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';

/**
 * 附件：列表 GET /api/attachments?itemId=、预览 GET /api/attachments/:id/download、
 * 单次上传 POST /api/attachments（原始字节体，attachments.cj）。
 * 分片上传契约复杂，按需求只做单次上传。
 * 预览：光栅图用 Image 的 data:image/<subType>;base64 渲染（SDK 明确支持，SVG 除外）；
 * 其它格式如实提示暂不提供在线预览，并展示 OCR 文本（若有）。
 */
@Component
export struct AttachmentsPage {
  @Prop item: ArchiveItem = {} as ArchiveItem;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State atts: AttachmentItem[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State previewShown: boolean = false;
  @State previewUri: string = '';
  @State previewMeta: string = '';
  @State previewText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getAttachments(this.item.id).then((d: AttachmentsData) => {
      this.atts = d.attachments;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('AttachmentsPage', 'list failed: ' + e.message);
    });
  }

  sizeText(n: number): string {
    if (n < 1024) {
      return n.toString() + ' B';
    }
    if (n < 1048576) {
      return (n / 1024).toFixed(1) + ' KB';
    }
    return (n / 1048576).toFixed(1) + ' MB';
  }

  /** 生成 Image 可识别的 data URI；非光栅图返回空串。 */
  imageUri(a: AttachmentItem, b64: string): string {
    let mime: string = a.mimeType;
    if (mime.length === 0 || !mime.startsWith('image/')) {
      const ext: string = a.fileExt.toLowerCase();
      if (ext === 'jpg' || ext === 'jpeg' || ext === 'png' || ext === 'webp'
        || ext === 'gif' || ext === 'bmp') {
        mime = 'image/' + (ext === 'jpg' ? 'jpeg' : ext);
      } else {
        return '';
      }
    }
    if (mime === 'image/svg+xml') {
      return '';
    }
    return 'data:' + mime + ';base64,' + b64;
  }

  preview(a: AttachmentItem): void {
    this.busy = true;
    ApiClient.getAttachmentDownload(a.id).then((d: DownloadData) => {
      this.busy = false;
      this.previewUri = this.imageUri(a, d.base64);
      this.previewMeta = t('attach.fetched') + this.sizeText(d.size) + ' · ' + a.mimeType
        + ' · ' + t('attach.downloads', i18nVars([['n', a.downloadCount.toString()]]));
      this.previewText = a.ocrText.length > 0 ? (t('attach.ocrTextLabel') + a.ocrText) : '';
      this.previewShown = true;
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('AttachmentsPage', 'download failed: ' + e.message);
    });
  }

  async pickAndUpload(): Promise<void> {
    this.busy = true;
    this.tip = '';
    // getContext() 已废弃，改用 UIContext.getHostContext()（官方替代）。
    const hostCtx = this.getUIContext().getHostContext();
    if (hostCtx === undefined) {
      this.busy = false;
      this.tip = t('attach.noContext');
      return;
    }
    const docPicker = new picker.DocumentViewPicker(hostCtx);
    let fd: number = -1;
    try {
      const uris: string[] = await docPicker.select();
      if (uris.length === 0) {
        this.busy = false;
        return;
      }
      const uri: string = uris[0];
      let fileName: string = uri.substring(uri.lastIndexOf('/') + 1);
      try {
        fileName = decodeURIComponent(fileName);
      } catch (e) {}
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      fd = f.fd;
      const st = fileIo.statSync(fd);
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fileIo.readSync(fd, buf);
      const dot: number = fileName.lastIndexOf('.');
      const title: string = dot > 0 ? fileName.substring(0, dot) : fileName;
      const params: UploadAttachmentParams = {
        fileName: fileName,
        title: title,
        category: 10,
        itemId: this.item.id,
        subjectId: '',
        data: buf
      };
      const r: UploadData = await ApiClient.uploadAttachment(params);
      this.tip = t('attach.uploaded', i18nVars([['name', fileName], ['id', r.id.toString()]]))
        + (r.dedupHit ? t('attach.dedup') : '') + '）';
      this.busy = false;
      this.load();
    } catch (e) {
      this.busy = false;
      this.tip = (e as Error).message;
      Logger.warn('AttachmentsPage', 'upload failed: ' + (e as Error).message);
    } finally {
      if (fd >= 0) {
        try {
          fileIo.closeSync(fd);
        } catch (e2) {}
      }
    }
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Button(this.busy ? t('common.processing') : t('attach.upload'))
              .layoutWeight(1)
              .height(44)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .enabled(!this.busy)
              .onClick(() => { this.pickAndUpload(); })
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

          Text(t('attach.itemLabel') + (this.item.title.length > 0 ? this.item.title : this.item.id))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .width('100%')
            .padding({ left: 4, bottom: 4 })
          Text(t('attach.hint'))
            .fontSize(11)
            .fontColor(C.ink3)
            .width('100%')
            .padding({ left: 4, bottom: 8 })

          if (this.tip.length > 0) {
            Text(this.tip).fontSize(F.caption).fontColor(C.success).width('100%').padding({ bottom: 8 })
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).width('100%').padding({ bottom: 8 })
          }

          if (this.previewShown) {
            Column() {
              Row() {
                Text(t('common.preview')).fontSize(F.body).fontWeight(600).fontColor(C.ink).layoutWeight(1)
                Text(t('common.close')).fontSize(F.caption).fontColor(C.accent)
                  .onClick(() => { this.previewShown = false; })
              }
              .width('100%')
              .padding({ bottom: 8 })
              if (this.previewUri.length > 0) {
                Image(this.previewUri)
                  .width('100%')
                  .height(220)
                  .objectFit(ImageFit.Contain)
                  .backgroundColor(C.surfaceAlt)
                  .borderRadius(C.radiusSm)
              } else {
                Text(t('attach.noPreview'))
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                  .width('100%')
                  .padding({ top: 8, bottom: 8 })
              }
              Text(this.previewMeta)
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .width('100%')
                .padding({ top: 8 })
              if (this.previewText.length > 0) {
                Text(this.previewText)
                  .fontSize(F.caption)
                  .fontColor(C.ink2)
                  .width('100%')
                  .padding({ top: 6 })
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .margin({ bottom: 12 })
          }

          if (this.loading && this.atts.length === 0) {
            LoadingProgress().margin({ top: 30 })
          } else if (this.atts.length === 0) {
            Text(t('attach.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 40 })
          } else {
            ForEach(this.atts, (a: AttachmentItem) => {
              this.attachmentRow(a)
            }, (a: AttachmentItem) => a.id.toString())
          }
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('nav.attachments'))
    .backgroundColor(C.bg)
  }

  @Builder
  attachmentRow(a: AttachmentItem) {
    Column() {
      Row() {
        Text(a.title)
          .fontSize(F.body)
          .fontWeight(600)
          .fontColor(C.ink)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sizeText(a.fileSize))
          .fontSize(F.caption)
          .fontColor(C.ink3)
      }
      .width('100%')
      Text('.' + a.fileExt + ' · ' + a.mimeType + ' · ' + t('attach.versions', i18nVars([['n', a.versionCount.toString()]])))
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
      if (a.summary.length > 0) {
        Text(a.summary).fontSize(F.caption).fontColor(C.ink2).width('100%').padding({ top: 4 })
      }
      if (a.ocrText.length > 0) {
        Text(t('attach.ocrLabel') + a.ocrText)
          .fontSize(F.caption)
          .fontColor(C.ink2)
          .width('100%')
          .padding({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Button(t('attach.previewDownload'))
        .width('100%')
        .height(36)
        .fontSize(F.caption)
        .backgroundColor(C.accentSoft)
        .fontColor(C.accent)
        .borderRadius(C.radiusSm)
        .margin({ top: 10 })
        .onClick(() => { this.preview(a); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .margin({ bottom: 12 })
  }
}
