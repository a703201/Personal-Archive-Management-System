import {
  ApiClient, SubjectWriteRequest, SubjectUpdateRequest, SubjectsData
} from '../common/api/ApiClient';
import { Subject } from '../common/models/Models';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars } from '../common/theme/I18n';
import { formatDate } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

/** 主体管理：列表 / 新建 / 编辑 / 软删除（routes/subjects.cj）。 */
@Component
export struct SubjectsPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State subjects: Subject[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State busy: boolean = false;
  @State showForm: boolean = false;
  @State editing: boolean = false;
  @State editId: string = '';
  @State editVersion: number = 0;
  @State name: string = '';
  @State alias: string = '';
  @State relation: number = 0;
  @State summary: string = '';
  @State confirmId: string = '';
  @State tip: string = '';
  @State relations: number[] = [0, 1, 2, 3, 4];

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getSubjects().then((d: SubjectsData) => {
      this.subjects = d.subjects;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('SubjectsPage', 'list failed: ' + e.message);
    });
  }

  relationLabel(code: number): string {
    switch (code) {
      case 0: return t('rel.0');
      case 1: return t('rel.1');
      case 2: return t('rel.2');
      case 3: return t('rel.3');
      default: return t('common.other');
    }
  }

  openCreate(): void {
    this.editing = false;
    this.editId = '';
    this.editVersion = 0;
    this.name = '';
    this.alias = '';
    this.relation = 0;
    this.summary = '';
    this.tip = '';
    this.showForm = true;
  }

  openEdit(s: Subject): void {
    this.editing = true;
    this.editId = s.id;
    this.editVersion = s.version ?? 0;
    this.name = s.name;
    this.alias = s.alias ?? '';
    this.relation = s.relation ?? 0;
    this.summary = s.summary ?? '';
    this.tip = '';
    this.showForm = true;
  }

  onFailed(e: Error): void {
    this.busy = false;
    this.tip = e.message;
    Logger.warn('SubjectsPage', 'save failed: ' + e.message);
  }

  onSaved(): void {
    this.busy = false;
    this.showForm = false;
    this.tip = '';
    DataRefresh.notify();
    this.load();
  }

  save(): void {
    this.tip = '';
    if (this.name.trim().length === 0) {
      this.tip = t('subj.nameEmpty');
      return;
    }
    this.busy = true;
    if (this.editing) {
      const body: SubjectUpdateRequest = {
        version: this.editVersion,
        name: this.name.trim(),
        alias: this.alias.trim(),
        relation: this.relation,
        summary: this.summary.trim()
      };
      ApiClient.updateSubject(this.editId, body).then(() => {
        this.onSaved();
      }).catch((e: Error) => {
        this.onFailed(e);
      });
    } else {
      const body: SubjectWriteRequest = {
        name: this.name.trim(),
        alias: this.alias.trim(),
        relation: this.relation,
        summary: this.summary.trim()
      };
      ApiClient.createSubject(body).then(() => {
        this.onSaved();
      }).catch((e: Error) => {
        this.onFailed(e);
      });
    }
  }

  remove(s: Subject): void {
    this.busy = true;
    ApiClient.deleteSubject(s.id).then((n: number) => {
      this.busy = false;
      this.confirmId = '';
      this.tip = n > 0 ? t('subj.deletedMany', i18nVars([['n', n.toString()]])) : t('subj.deleted');
      DataRefresh.notify();
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.confirmId = '';
      this.tip = e.message;
      Logger.warn('SubjectsPage', 'delete failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Button(t('subj.new'))
            .height(44)
            .fontSize(F.body)
            .backgroundColor(C.accent)
            .fontColor('#FFFFFF')
            .borderRadius(C.radiusSm)
            .onClick(() => { this.openCreate(); })
          Button(t('common.refresh'))
            .height(44)
            .fontSize(F.body)
            .backgroundColor(C.surfaceAlt)
            .fontColor(C.ink)
            .borderRadius(C.radiusSm)
            .margin({ left: 10 })
            .onClick(() => { this.load(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 8 })

        if (this.showForm) {
          Column() {
            Text(this.editing ? t('subj.editTitle') : t('subj.newTitle'))
              .fontSize(F.body)
              .fontWeight(600)
              .fontColor(C.ink)
              .padding({ bottom: 8 })
            this.inputRow(t('field.name'), t('subj.namePh'), this.name, 1)
            this.inputRow(t('field.alias'), t('common.optional'), this.alias, 2)
            this.inputRow(t('field.summary'), t('common.optional'), this.summary, 3)

            Text(t('field.relation'))
              .fontSize(F.caption)
              .fontColor(C.ink3)
              .padding({ left: 4, top: 12, bottom: 8 })
            Row() {
              ForEach(this.relations, (r: number) => {
                Text(this.relationLabel(r))
                  .fontSize(F.caption)
                  .fontColor(this.relation === r ? '#FFFFFF' : C.ink2)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor(this.relation === r ? C.accent : C.surface)
                  .margin({ right: 8 })
                  .onClick(() => { this.relation = r; })
              }, (r: number) => r.toString())
            }
            .width('100%')

            if (this.tip.length > 0) {
              Text(this.tip)
                .fontSize(F.caption)
                .fontColor(C.danger)
                .padding({ top: 10 })
            }
            Row() {
              Button(t('common.cancel'))
                .layoutWeight(1)
                .height(42)
                .fontSize(F.body)
                .backgroundColor(C.surfaceAlt)
                .fontColor(C.ink)
                .borderRadius(C.radiusSm)
                .onClick(() => { this.showForm = false; })
              Button(this.busy ? t('common.saving') : t('common.save'))
                .layoutWeight(1)
                .height(42)
                .fontSize(F.body)
                .backgroundColor(C.accent)
                .fontColor('#FFFFFF')
                .borderRadius(C.radiusSm)
                .margin({ left: 10 })
                .enabled(!this.busy)
                .onClick(() => { this.save(); })
            }
            .width('100%')
            .padding({ top: 14 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ left: F.pad, right: F.pad, bottom: 12 })
        }

        if (this.tip.length > 0 && !this.showForm) {
          Text(this.tip)
            .fontSize(F.caption)
            .fontColor(C.success)
            .padding({ left: F.pad, right: F.pad, bottom: 6 })
        }

        if (this.loading && this.subjects.length === 0) {
          LoadingProgress().margin({ top: 40 })
        } else if (this.errorMsg.length > 0 && this.subjects.length === 0) {
          Column() {
            Text(this.errorMsg).fontSize(F.body).fontColor(C.danger)
            Button(t('common.retry'))
              .height(40)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .margin({ top: 16 })
              .onClick(() => { this.load(); })
          }
          .margin({ top: 60 })
        } else if (this.subjects.length === 0) {
          Text(t('common.noSubject')).fontSize(F.body).fontColor(C.ink3).margin({ top: 60 })
        } else {
          List() {
            ForEach(this.subjects, (s: Subject) => {
              ListItem() {
                this.subjectRow(s)
              }
            }, (s: Subject) => s.id)
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
    .title(t('nav.subjects'))
    .backgroundColor(C.bg)
  }

  /** @Builder 不传函数参数，改由字段号分发。 */
  onField(kind: number, v: string): void {
    if (kind === 1) {
      this.name = v;
    } else if (kind === 2) {
      this.alias = v;
    } else if (kind === 3) {
      this.summary = v;
    }
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, kind: number) {
    Column() {
      Text(label)
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .padding({ left: 4, bottom: 6 })
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
    .padding({ top: 8 })
  }

  @Builder
  subjectRow(s: Subject) {
    Column() {
      Row() {
        Column() {
          Row() {
            Text(s.name)
              .fontSize(F.body)
              .fontWeight(600)
              .fontColor(C.ink)
            if (s.isPrimary === true) {
              Text(t('rel.0'))
                .fontSize(11)
                .fontColor(C.accent)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
                .backgroundColor(C.accentSoft)
                .margin({ left: 8 })
            }
          }
          Text(this.relationLabel(s.relation ?? 0)
            + (s.alias !== undefined && s.alias.length > 0 ? ' · ' + s.alias : '')
            + (s.summary !== undefined && s.summary.length > 0 ? ' · ' + s.summary : ''))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        Text(t('common.updatedPrefix') + formatDate(s.updatedAt))
          .fontSize(11)
          .fontColor(C.ink3)
      }
      .width('100%')

      Row() {
        Button(t('common.edit'))
          .height(32)
          .fontSize(F.caption)
          .backgroundColor(C.accentSoft)
          .fontColor(C.accent)
          .borderRadius(C.radiusSm)
          .onClick(() => { this.openEdit(s); })
        Button(this.confirmId === s.id ? t('item.confirmDelete') : t('common.delete'))
          .height(32)
          .fontSize(F.caption)
          .backgroundColor(this.confirmId === s.id ? C.danger : C.surfaceAlt)
          .fontColor(this.confirmId === s.id ? '#FFFFFF' : C.danger)
          .borderRadius(C.radiusSm)
          .margin({ left: 10 })
          .enabled(!this.busy)
          .onClick(() => {
            if (this.confirmId === s.id) {
              this.remove(s);
            } else {
              this.confirmId = s.id;
            }
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(C.surface)
  }
}
