import {
  ApiClient, TasksData, TaskRecord, CreateExportRequest, CreateImportRequest
} from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, taskStatusName, i18nVars } from '../common/theme/I18n';
import { formatDateTime } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

/**
 * 导入 / 导出任务：
 *  - POST /api/export/tasks、GET /api/export/tasks、GET /api/export/tasks/:no、
 *    GET /api/export/tasks/:no/download、POST /api/export/tasks/:no/cancel（export.cj）；
 *  - POST /api/import/tasks、GET /api/import/tasks（import.cj）。
 * 任务列表二者共用一张表，GET /api/export/tasks 不传 type 即返回全部。
 * 下载端点返回 CSV/JSON 正文（无信封），由 ApiClient.downloadExport 直接取回。
 */
@Component
export struct TasksPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State tasks: TaskRecord[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State showExport: boolean = false;
  @State showImport: boolean = false;
  @State expScope: string = 'full';
  @State expFormat: string = 'csv';
  @State expKeyword: string = '';
  @State expCategory: string = '0';
  @State impSubjectId: string = '';
  @State csvText: string = '';
  @State detailShown: boolean = false;
  @State detailText: string = '';
  @State downloadShown: boolean = false;
  @State downloadText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getTasks().then((d: TasksData) => {
      this.tasks = d.items;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('TasksPage', 'list failed: ' + e.message);
    });
  }

  createExport(): void {
    const body: CreateExportRequest = { scope: this.expScope, format: this.expFormat };
    if (this.expKeyword.trim().length > 0) {
      body.keyword = this.expKeyword.trim();
    }
    if (this.expScope === 'category') {
      const c: number = parseInt(this.expCategory, 10);
      body.category = c > 0 ? c : 0;
    }
    this.busy = true;
    ApiClient.createExportTask(body).then(() => {
      this.busy = false;
      this.tip = t('tasks.exportCreated');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('TasksPage', 'export create failed: ' + e.message);
    });
  }

  createImport(): void {
    if (this.csvText.trim().length === 0) {
      this.tip = t('tasks.pasteCsv');
      return;
    }
    const body: CreateImportRequest = { csv: this.csvText };
    if (this.impSubjectId.trim().length > 0) {
      const s: number = parseInt(this.impSubjectId, 10);
      if (s > 0) {
        body.subjectId = s;
      }
    }
    this.busy = true;
    ApiClient.createImportTask(body).then(() => {
      this.busy = false;
      this.tip = t('tasks.importCreated');
      this.csvText = '';
      DataRefresh.notify();
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('TasksPage', 'import create failed: ' + e.message);
    });
  }

  showDetail(rec: TaskRecord): void {
    ApiClient.getTask(rec.taskNo).then((d: TaskRecord) => {
      this.detailText = t('tasks.detailTask', i18nVars([['no', d.taskNo]]))
        + '\n' + t('tasks.status') + taskStatusName(d.status)
        + '\n' + t('tasks.progress') + d.percent.toString() + '%'
        + t('tasks.progressBody', i18nVars([['done', d.done.toString()], ['total', d.total.toString()], ['failed', d.failed.toString()]]))
        + '\n' + t('tasks.format') + d.format + t('tasks.rows') + d.rows.toString()
        + (d.error.length > 0 ? ('\n' + t('tasks.error') + d.error) : '');
      this.detailShown = true;
    }).catch((e: Error) => {
      this.tip = e.message;
      Logger.warn('TasksPage', 'detail failed: ' + e.message);
    });
  }

  cancel(rec: TaskRecord): void {
    this.busy = true;
    ApiClient.cancelTask(rec.taskNo).then(() => {
      this.busy = false;
      this.tip = t('tasks.canceled');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
    });
  }

  download(rec: TaskRecord): void {
    this.busy = true;
    ApiClient.downloadExport(rec.taskNo).then((text: string) => {
      this.busy = false;
      this.downloadText = text.length > 600
        ? (text.substring(0, 600) + t('tasks.truncated')) : text;
      this.downloadShown = true;
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('TasksPage', 'download failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Button(this.showExport ? t('tasks.collapseExport') : t('tasks.newExport'))
              .layoutWeight(1)
              .height(42)
              .fontSize(F.caption)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .onClick(() => { this.showExport = !this.showExport; })
            Button(this.showImport ? t('tasks.collapseImport') : t('tasks.newImport'))
              .layoutWeight(1)
              .height(42)
              .fontSize(F.caption)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .margin({ left: 8 })
              .onClick(() => { this.showImport = !this.showImport; })
            Button(t('common.refresh'))
              .height(42)
              .fontSize(F.caption)
              .backgroundColor(C.surfaceAlt)
              .fontColor(C.ink)
              .borderRadius(C.radiusSm)
              .margin({ left: 8 })
              .onClick(() => { this.load(); })
          }
          .width('100%')
          .margin({ bottom: 12 })

          if (this.showExport) {
            Column() {
              Text(t('tasks.expScopeLabel')).fontSize(F.caption).fontColor(C.ink3).padding({ bottom: 6 })
              Row() {
                this.chipBtn(t('tasks.full'), this.expScope === 'full', 1)
                this.chipBtn(t('tasks.byCategory'), this.expScope === 'category', 2)
              }
              .width('100%')
              Text(t('field.format')).fontSize(F.caption).fontColor(C.ink3).padding({ top: 10, bottom: 6 })
              Row() {
                this.chipBtn('CSV', this.expFormat === 'csv', 3)
                this.chipBtn('JSON', this.expFormat === 'json', 4)
              }
              .width('100%')
              if (this.expScope === 'category') {
                this.inputRow(t('tasks.catCodeLabel'), t('tasks.catCodePh'), this.expCategory, 1)
              }
              this.inputRow(t('field.keyword'), t('common.optional'), this.expKeyword, 2)
              Button(this.busy ? t('common.creating') : t('common.create'))
                .width('100%')
                .height(42)
                .fontSize(F.body)
                .backgroundColor(C.accent)
                .fontColor('#FFFFFF')
                .borderRadius(C.radiusSm)
                .margin({ top: 12 })
                .enabled(!this.busy)
                .onClick(() => { this.createExport(); })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .margin({ bottom: 12 })
          }

          if (this.showImport) {
            Column() {
              Text(t('tasks.csvHeader') + 'subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark')
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .width('100%')
                .padding({ bottom: 8 })
              TextArea({ placeholder: t('tasks.csvPh'), text: this.csvText })
                .width('100%')
                .height(120)
                .backgroundColor(C.surfaceAlt)
                .borderRadius(C.radiusSm)
                .padding(12)
                .fontSize(F.caption)
                .onChange((v: string) => { this.csvText = v; })
              this.inputRow(t('tasks.impSubjectLabel'), t('tasks.subjectIdPh'), this.impSubjectId, 3)
              Button(this.busy ? t('common.creating') : t('common.create'))
                .width('100%')
                .height(42)
                .fontSize(F.body)
                .backgroundColor(C.accent)
                .fontColor('#FFFFFF')
                .borderRadius(C.radiusSm)
                .margin({ top: 12 })
                .enabled(!this.busy)
                .onClick(() => { this.createImport(); })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .margin({ bottom: 12 })
          }

          if (this.tip.length > 0) {
            Text(this.tip).fontSize(F.caption).fontColor(C.success).width('100%').padding({ bottom: 8 })
          }
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).width('100%').padding({ bottom: 8 })
          }

          if (this.detailShown) {
            this.textPanel(t('tasks.detailTitle'), this.detailText, 1)
          }
          if (this.downloadShown) {
            this.textPanel(t('tasks.exportBodyTitle'), this.downloadText, 2)
          }

          if (this.loading && this.tasks.length === 0) {
            LoadingProgress().margin({ top: 30 })
          } else if (this.tasks.length === 0) {
            Text(t('tasks.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 30 })
          } else {
            ForEach(this.tasks, (task: TaskRecord) => {
              this.taskRow(task)
            }, (task: TaskRecord) => task.taskNo)
          }
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 16, bottom: 32 })
      }
      .width('100%')
      .height('100%')
    }
    .title(t('nav.tasks'))
    .backgroundColor(C.bg)
  }

  chipAction(kind: number): void {
    if (kind === 1) {
      this.expScope = 'full';
    } else if (kind === 2) {
      this.expScope = 'category';
    } else if (kind === 3) {
      this.expFormat = 'csv';
    } else if (kind === 4) {
      this.expFormat = 'json';
    }
  }

  onField(kind: number, v: string): void {
    if (kind === 1) {
      this.expCategory = v;
    } else if (kind === 2) {
      this.expKeyword = v;
    } else if (kind === 3) {
      this.impSubjectId = v;
    }
  }

  closePanel(kind: number): void {
    if (kind === 1) {
      this.detailShown = false;
    } else if (kind === 2) {
      this.downloadShown = false;
    }
  }

  @Builder
  chipBtn(label: string, active: boolean, kind: number) {
    Text(label)
      .fontSize(F.caption)
      .fontColor(active ? '#FFFFFF' : C.ink2)
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(active ? C.accent : C.surfaceAlt)
      .margin({ right: 8 })
      .onClick(() => { this.chipAction(kind); })
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, kind: number) {
    Column() {
      Text(label).fontSize(F.caption).fontColor(C.ink3).padding({ left: 4, bottom: 6 })
      TextInput({ placeholder: placeholder, text: value })
        .width('100%')
        .height(42)
        .backgroundColor(C.surfaceAlt)
        .borderRadius(C.radiusSm)
        .padding({ left: 12 })
        .fontSize(F.body)
        .onChange((v: string) => { this.onField(kind, v); })
    }
    .width('100%')
    .padding({ top: 8 })
  }

  @Builder
  textPanel(titleText: string, bodyText: string, kind: number) {
    Column() {
      Row() {
        Text(titleText).fontSize(F.body).fontWeight(600).fontColor(C.ink).layoutWeight(1)
        Text(t('common.close')).fontSize(F.caption).fontColor(C.accent)
          .onClick(() => { this.closePanel(kind); })
      }
      .width('100%')
      .padding({ bottom: 8 })
      Text(bodyText)
        .fontSize(F.caption)
        .fontColor(C.ink2)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .margin({ bottom: 12 })
  }

  @Builder
  taskRow(task: TaskRecord) {
    Column() {
      Row() {
        Text(task.type === 'import' ? t('tasks.import') : t('tasks.export'))
          .fontSize(11)
          .fontColor(C.accent)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(C.accentSoft)
        Text(taskStatusName(task.status))
          .fontSize(F.caption)
          .fontColor(task.status === 2 ? C.success : (task.status === 3 ? C.danger : C.ink2))
          .margin({ left: 8 })
          .layoutWeight(1)
        Text(task.percent.toString() + '%')
          .fontSize(F.caption)
          .fontColor(C.ink3)
      }
      .width('100%')
      Text(task.taskNo)
        .fontSize(F.caption)
        .fontColor(C.ink)
        .width('100%')
        .padding({ top: 6 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(t('tasks.formatRow', i18nVars([['fmt', task.format], ['rows', task.rows.toString()]]))
        + ' · ' + formatDateTime(task.createdAt))
        .fontSize(11)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ top: 4 })
      if (task.error.length > 0) {
        Text(task.error).fontSize(11).fontColor(C.danger).width('100%').padding({ top: 4 })
      }
      Row() {
        Button(t('tasks.progressBtn'))
          .layoutWeight(1)
          .height(34)
          .fontSize(F.caption)
          .backgroundColor(C.surfaceAlt)
          .fontColor(C.ink)
          .borderRadius(C.radiusSm)
          .onClick(() => { this.showDetail(task); })
        if (task.status === 2 && task.type !== 'import') {
          Button(t('common.download'))
            .layoutWeight(1)
            .height(34)
            .fontSize(F.caption)
            .backgroundColor(C.accentSoft)
            .fontColor(C.accent)
            .borderRadius(C.radiusSm)
            .margin({ left: 8 })
            .onClick(() => { this.download(task); })
        }
        if (task.status === 0 || task.status === 1) {
          Button(t('common.cancel'))
            .layoutWeight(1)
            .height(34)
            .fontSize(F.caption)
            .backgroundColor(C.surfaceAlt)
            .fontColor(C.danger)
            .borderRadius(C.radiusSm)
            .margin({ left: 8 })
            .enabled(!this.busy)
            .onClick(() => { this.cancel(task); })
        }
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .margin({ bottom: 12 })
  }
}
