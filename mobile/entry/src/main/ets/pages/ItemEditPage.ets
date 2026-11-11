import { ApiClient, ItemWriteRequest, ItemUpdateRequest, SubjectsData } from '../common/api/ApiClient';
import { C, F } from '../common/theme/Theme';
import { ArchiveItem, EditParam, Subject, categoryName } from '../common/models/Models';
import { Logger } from '../common/utils/Logger';
import { DataRefresh } from '../common/store/DataRefresh';

@Component
export struct ItemEditPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @State param: EditParam = { mode: 'create', category: 0, subjectId: '' };
  @State itemId: string = '';
  @State version: number = 0;
  @State title: string = '';
  @State issuer: string = '';
  @State issuedDate: string = '';
  @State expiresAt: string = '';
  @State remark: string = '';
  @State sensitivity: number = 1;
  @State subjects: Subject[] = [];
  @State subjectIndex: number = 0;
  @State subjectId: string = '';
  @State saving: boolean = false;
  @State errorMsg: string = '';
  @State levels: number[] = [1, 2, 3];

  aboutToAppear(): void {
    const item: ArchiveItem | undefined = this.param.item;
    if (this.param.mode === 'edit' && item !== undefined) {
      this.itemId = item.id;
      this.version = item.version;
      this.title = item.title;
      this.issuer = item.issuer ?? '';
      this.issuedDate = item.issuedDate ?? '';
      this.expiresAt = item.expiresAt ?? '';
      this.remark = item.remark ?? '';
      this.sensitivity = item.sensitivity;
      this.subjectId = item.subjectId;
    } else {
      this.loadSubjects();
    }
  }

  loadSubjects(): void {
    ApiClient.getSubjects().then((d: SubjectsData) => {
      this.subjects = d.subjects;
      if (d.subjects.length > 0) {
        this.subjectIndex = 0;
        this.subjectId = d.subjects[0].id;
      }
    }).catch((e: Error) => {
      Logger.warn('ItemEditPage', 'subjects failed: ' + e.message);
    });
  }

  nextSubject(): void {
    if (this.subjects.length === 0) {
      return;
    }
    const next: number = (this.subjectIndex + 1) % this.subjects.length;
    this.subjectIndex = next;
    this.subjectId = this.subjects[next].id;
  }

  /** 后端只接受 YYYY-MM-DD 或空串，先做形状检查避免无谓的 400。 */
  validDate(s: string): boolean {
    if (s.length === 0) {
      return true;
    }
    if (s.length !== 10) {
      return false;
    }
    return s.charAt(4) === '-' && s.charAt(7) === '-';
  }

  currentSubjectName(): string {
    if (this.subjects.length === 0) {
      return '暂无主体，请先在网页端创建';
    }
    if (this.subjectIndex < this.subjects.length) {
      return this.subjects[this.subjectIndex].name;
    }
    return this.subjects[0].name;
  }

  onSaved(): void {
    this.saving = false;
    DataRefresh.notify();
    this.navPathStack.pop();
  }

  onFailed(e: Error): void {
    this.saving = false;
    this.errorMsg = e.message;
    Logger.warn('ItemEditPage', 'save failed: ' + e.message);
  }

  save(): void {
    this.errorMsg = '';
    if (this.title.trim().length === 0) {
      this.errorMsg = '标题不能为空';
      return;
    }
    if (!this.validDate(this.issuedDate.trim()) || !this.validDate(this.expiresAt.trim())) {
      this.errorMsg = '日期格式应为 YYYY-MM-DD';
      return;
    }
    if (this.param.mode === 'create' && this.subjectId.length === 0) {
      this.errorMsg = '暂无主体，请先在网页端创建主体';
      return;
    }
    this.saving = true;
    if (this.param.mode === 'edit') {
      const body: ItemUpdateRequest = {
        version: this.version,
        title: this.title.trim(),
        sensitivity: this.sensitivity,
        issuedDate: this.issuedDate.trim(),
        expiresAt: this.expiresAt.trim(),
        issuer: this.issuer.trim(),
        remark: this.remark.trim()
      };
      ApiClient.updateItem(this.itemId, body).then(() => {
        this.onSaved();
      }).catch((e: Error) => {
        this.onFailed(e);
      });
    } else {
      const body: ItemWriteRequest = {
        subjectId: this.subjectId,
        category: this.param.category,
        title: this.title.trim(),
        // 后端 status：0 草稿 / 1 正常 / 2 已归档。移动端没有草稿箱入口，
        // 新建直接落成「正常」，避免条目创建后在列表里显示为草稿。
        status: 1,
        sensitivity: this.sensitivity,
        issuedDate: this.issuedDate.trim(),
        expiresAt: this.expiresAt.trim(),
        issuer: this.issuer.trim(),
        remark: this.remark.trim()
      };
      ApiClient.createItem(body).then(() => {
        this.onSaved();
      }).catch((e: Error) => {
        this.onFailed(e);
      });
    }
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column() {
            this.inputRow('标题', '条目名称', this.title, 1)
            this.inputRow('签发机构', '选填', this.issuer, 2)
            this.inputRow('签发日期', 'YYYY-MM-DD，选填', this.issuedDate, 3)
            this.inputRow('到期时间', 'YYYY-MM-DD，选填', this.expiresAt, 4)
            this.inputRow('备注', '选填', this.remark, 5)

            Text('分类')
              .fontSize(F.caption)
              .fontColor(C.ink3)
              .padding({ left: 4, top: 16, bottom: 8 })
            Row() {
              Text(categoryName(this.param.category))
                .fontSize(F.body)
                .fontColor(C.ink)
            }
            .width('100%')
            .padding(14)
            .backgroundColor(C.surface)
            .borderRadius(C.radiusSm)

            if (this.param.mode === 'create') {
              Text('所属主体')
                .fontSize(F.caption)
                .fontColor(C.ink3)
                .padding({ left: 4, top: 16, bottom: 8 })
              Row() {
                Text(this.currentSubjectName())
                  .fontSize(F.body)
                  .fontColor(C.ink)
                  .layoutWeight(1)
                Text('切换').fontSize(F.caption).fontColor(C.accent)
              }
              .width('100%')
              .padding(14)
              .backgroundColor(C.surface)
              .borderRadius(C.radiusSm)
              .onClick(() => { this.nextSubject(); })
            }

            Text('敏感度')
              .fontSize(F.caption)
              .fontColor(C.ink3)
              .padding({ left: 4, top: 16, bottom: 8 })
            Row() {
              ForEach(this.levels, (level: number) => {
                Button(level === 1 ? '一般' : (level === 2 ? '较敏感' : '高敏感'))
                  .layoutWeight(1)
                  .height(38)
                  .fontSize(F.caption)
                  .backgroundColor(this.sensitivity === level ? C.accent : C.surface)
                  .fontColor(this.sensitivity === level ? '#FFFFFF' : C.ink2)
                  .borderRadius(C.radiusSm)
                  .margin({ right: level < 3 ? 8 : 0 })
                  .onClick(() => { this.sensitivity = level; })
              }, (level: number) => level.toString())
            }
            .width('100%')

            if (this.errorMsg.length > 0) {
              Text(this.errorMsg)
                .fontSize(F.caption)
                .fontColor(C.danger)
                .padding({ left: 4, top: 16 })
            }
          }
          .width('100%')
          .padding({ left: F.pad, right: F.pad, top: 8, bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)

        // 同 ItemsPage：左右留白交给外层 Column，避免 width('100%') 把 margin 挤掉。
        Column() {
          Button(this.saving ? '保存中…' : '保存')
            .width('100%')
            .height(48)
            .fontSize(F.body)
            .fontWeight(600)
            .backgroundColor(C.accent)
            .fontColor('#FFFFFF')
            .borderRadius(C.radiusSm)
            .enabled(!this.saving)
            .onClick(() => { this.save(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 20 })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.param.mode === 'edit' ? '编辑条目' : '新建条目')
    .backgroundColor(C.bg)
  }

  /** @Builder 不传函数参数，改由字段号分发，规避 ArkTS 构建期限制。 */
  onField(kind: number, v: string): void {
    if (kind === 1) {
      this.title = v;
    } else if (kind === 2) {
      this.issuer = v;
    } else if (kind === 3) {
      this.issuedDate = v;
    } else if (kind === 4) {
      this.expiresAt = v;
    } else if (kind === 5) {
      this.remark = v;
    }
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, kind: number) {
    Column() {
      Text(label)
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .padding({ left: 4, bottom: 8 })
      TextInput({ placeholder: placeholder, text: value })
        .width('100%')
        .height(46)
        .backgroundColor(C.surface)
        .borderRadius(C.radiusSm)
        .padding({ left: 14 })
        .fontSize(F.body)
        .onChange((v: string) => { this.onField(kind, v); })
    }
    .width('100%')
    .padding({ top: 12 })
  }
}
