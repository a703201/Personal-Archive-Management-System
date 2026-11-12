import {
  ApiClient, TemplatesData, ItemTemplate, ApplyTemplateRequest, ApplyTemplateData, SubjectsData
} from '../common/api/ApiClient';
import { Subject } from '../common/models/Models';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars, categoryNameI18n, statusNameI18n } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

/** 条目模板：GET /api/item-templates、POST /api/item-templates/:id/apply（itemtemplates.cj）。 */
@Component
export struct TemplatesPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State templates: ItemTemplate[] = [];
  @State subjects: Subject[] = [];
  @State subjectIndex: number = 0;
  @State count: string = '1';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State applyId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getTemplates().then((d: TemplatesData) => {
      this.templates = d.items;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('TemplatesPage', 'list failed: ' + e.message);
    });
    ApiClient.getSubjects().then((d: SubjectsData) => {
      this.subjects = d.subjects;
    }).catch((e: Error) => {
      Logger.warn('TemplatesPage', 'subjects failed: ' + e.message);
    });
  }

  currentSubjectName(): string {
    if (this.subjects.length === 0) {
      return t('common.noSubject');
    }
    return this.subjects[this.subjectIndex].name;
  }

  currentSubjectId(): number {
    if (this.subjects.length === 0) {
      return 0;
    }
    const n: number = parseInt(this.subjects[this.subjectIndex].id, 10);
    return n > 0 ? n : 0;
  }

  nextSubject(): void {
    if (this.subjects.length === 0) {
      return;
    }
    this.subjectIndex = (this.subjectIndex + 1) % this.subjects.length;
  }

  apply(tpl: ItemTemplate): void {
    const sid: number = this.currentSubjectId();
    if (sid <= 0) {
      this.tip = t('tpl.noAvailableSubject');
      return;
    }
    const n: number = parseInt(this.count, 10);
    const cnt: number = n > 0 ? n : 1;
    const body: ApplyTemplateRequest = { subjectId: sid, count: cnt };
    this.applyId = tpl.id;
    this.busy = true;
    ApiClient.applyTemplate(tpl.id, body).then((d: ApplyTemplateData) => {
      this.busy = false;
      this.applyId = '';
      this.tip = t('tpl.applied', i18nVars([['n', d.created.toString()]]));
      DataRefresh.notify();
    }).catch((e: Error) => {
      this.busy = false;
      this.applyId = '';
      this.tip = e.message;
      Logger.warn('TemplatesPage', 'apply failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Column() {
              Text(t('tpl.targetSubject')).fontSize(F.caption).fontColor(C.ink3)
              Text(this.currentSubjectName()).fontSize(F.body).fontColor(C.ink)
            }
            .layoutWeight(1)
            Text(t('item.switch')).fontSize(F.caption).fontColor(C.accent)
              .onClick(() => { this.nextSubject(); })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 8 })

          Row() {
            Text(t('tpl.countLabel')).fontSize(F.body).fontColor(C.ink).layoutWeight(1)
            TextInput({ placeholder: '1', text: this.count })
              .width(80)
              .height(40)
              .backgroundColor(C.surfaceAlt)
              .borderRadius(C.radiusSm)
              .padding({ left: 12 })
              .fontSize(F.body)
              .type(InputType.Number)
              .onChange((v: string) => { this.count = v; })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          if (this.tip.length > 0) {
            Text(this.tip).fontSize(F.caption).fontColor(C.success).padding({ bottom: 8 })
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).padding({ bottom: 8 })
          }

          if (this.loading && this.templates.length === 0) {
            LoadingProgress().margin({ top: 30 })
          } else if (this.templates.length === 0) {
            Text(t('tpl.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 30 })
          } else {
            ForEach(this.templates, (tpl: ItemTemplate) => {
              this.templateRow(tpl)
            }, (tpl: ItemTemplate) => tpl.id)
          }

          Button(t('common.refresh'))
            .width('100%')
            .height(44)
            .fontSize(F.body)
            .backgroundColor(C.surfaceAlt)
            .fontColor(C.ink)
            .borderRadius(C.radiusSm)
            .margin({ top: 16 })
            .onClick(() => { this.load(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('nav.templates'))
    .backgroundColor(C.bg)
  }

  @Builder
  templateRow(tpl: ItemTemplate) {
    Column() {
      Row() {
        Text(tpl.name)
          .fontSize(F.body)
          .fontWeight(600)
          .fontColor(C.ink)
          .layoutWeight(1)
        Text(categoryNameI18n(tpl.category))
          .fontSize(F.caption)
          .fontColor(C.accent)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(C.accentSoft)
      }
      .width('100%')
      Text(t('tpl.titleTpl') + tpl.title)
        .fontSize(F.caption)
        .fontColor(C.ink2)
        .width('100%')
        .padding({ top: 6 })
      Text(statusNameI18n(tpl.status) + t('tpl.sensInline') + tpl.sensitivity.toString()
        + (tpl.expiresOffsetDays > 0 ? t('tpl.validityInline', i18nVars([['d', tpl.expiresOffsetDays.toString()]])) : ''))
        .fontSize(11)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
      if (tpl.issuer.length > 0) {
        Text(t('tpl.issuerLabel') + tpl.issuer)
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .width('100%')
          .padding({ top: 4 })
      }
      if (tpl.remark.length > 0) {
        Text(tpl.remark)
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .width('100%')
          .padding({ top: 4 })
      }
      Button(this.applyId === tpl.id ? t('tpl.applying') : t('tpl.apply'))
        .width('100%')
        .height(38)
        .fontSize(F.caption)
        .backgroundColor(C.accentSoft)
        .fontColor(C.accent)
        .borderRadius(C.radiusSm)
        .margin({ top: 10 })
        .enabled(!this.busy)
        .onClick(() => { this.apply(tpl); })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .margin({ bottom: 12 })
  }
}
