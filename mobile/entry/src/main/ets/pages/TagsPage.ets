import {
  ApiClient, TagsData, TagStatsData, TagItem, CreateTagRequest,
  BatchTagRequest, BatchTagData, ItemFieldsData, ItemFieldValue
} from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars } from '../common/theme/I18n';
import { Logger } from '../common/utils/Logger';

/**
 * 标签中心：
 *  - 标签库 GET /api/tags?tree=1、统计 GET /api/tags/stats、新建/删除；
 *  - 条目标签编辑 POST /api/items/:id/tags、DELETE /api/items/:id/tags/:tagId；
 *  - 附件标签编辑 POST /api/attachments/batch/tag；
 *  - 条目自定义字段查看 GET /api/items/:id/fields（fielddefs.cj）。
 * 说明：后端没有「列出某条目已挂标签」的只读端点，故条目维度只提供
 * 附加/移除，不做假数据展示。
 */
@Component
export struct TagsPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State tags: TagItem[] = [];
  @State stats: TagStatsData = { total: 0, used: 0, unused: 0, totalUsage: 0, lastUsedAt: '0' };
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State tip: string = '';
  @State busy: boolean = false;
  @State newName: string = '';
  @State selectedTagId: string = '';
  @State confirmTagId: string = '';
  @State itemId: string = '';
  @State attachId: string = '';
  @State fields: ItemFieldValue[] = [];
  @State fieldsShown: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getTags().then((d: TagsData) => {
      this.tags = d.items;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('TagsPage', 'tags failed: ' + e.message);
    });
    ApiClient.getTagStats().then((d: TagStatsData) => {
      this.stats = d;
    }).catch((e: Error) => {
      Logger.warn('TagsPage', 'stats failed: ' + e.message);
    });
  }

  createTag(): void {
    if (this.newName.trim().length === 0) {
      this.tip = t('tags.nameEmpty');
      return;
    }
    const body: CreateTagRequest = { name: this.newName.trim() };
    this.busy = true;
    ApiClient.createTag(body).then(() => {
      this.busy = false;
      this.newName = '';
      this.tip = t('tags.created');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
      Logger.warn('TagsPage', 'create failed: ' + e.message);
    });
  }

  removeTag(id: string): void {
    this.busy = true;
    ApiClient.deleteTag(id).then(() => {
      this.busy = false;
      this.confirmTagId = '';
      if (this.selectedTagId === id) {
        this.selectedTagId = '';
      }
      this.tip = t('tags.deleted');
      this.load();
    }).catch((e: Error) => {
      this.busy = false;
      this.confirmTagId = '';
      this.tip = e.message;
    });
  }

  tagNumber(id: string): number {
    const n: number = parseInt(id, 10);
    return n > 0 ? n : 0;
  }

  attachToItem(): void {
    const tagId: number = this.tagNumber(this.selectedTagId);
    if (this.itemId.trim().length === 0 || tagId === 0) {
      this.tip = t('tags.needItemTag');
      return;
    }
    this.busy = true;
    ApiClient.attachTag(this.itemId.trim(), tagId).then(() => {
      this.busy = false;
      this.tip = t('tags.attached');
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
    });
  }

  detachFromItem(): void {
    const tagId: number = this.tagNumber(this.selectedTagId);
    if (this.itemId.trim().length === 0 || tagId === 0) {
      this.tip = t('tags.needItemTag');
      return;
    }
    this.busy = true;
    ApiClient.detachTag(this.itemId.trim(), this.selectedTagId).then(() => {
      this.busy = false;
      this.tip = t('tags.detached');
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
    });
  }

  batchTag(mode: string): void {
    const tagId: number = this.tagNumber(this.selectedTagId);
    const attId: number = parseInt(this.attachId, 10);
    if (attId <= 0 || tagId === 0) {
      this.tip = t('tags.needAttachTag');
      return;
    }
    const body: BatchTagRequest = { ids: [attId], tagIds: [tagId], mode: mode };
    this.busy = true;
    ApiClient.batchTagAttachments(body).then((d: BatchTagData) => {
    this.busy = false;
    this.tip = mode === 'add' ? t('tags.attachChanged', i18nVars([['n', d.changed.toString()]]))
      : t('tags.detachChanged', i18nVars([['n', d.changed.toString()]]));
    }).catch((e: Error) => {
      this.busy = false;
      this.tip = e.message;
    });
  }

  loadFields(): void {
    if (this.itemId.trim().length === 0) {
      this.tip = t('tags.needItemId');
      return;
    }
    ApiClient.getItemFields(this.itemId.trim()).then((d: ItemFieldsData) => {
      this.fields = d.fields;
      this.fieldsShown = true;
    }).catch((e: Error) => {
      this.tip = e.message;
      Logger.warn('TagsPage', 'fields failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          // 统计
          Row() {
            this.statCell(t('tags.totalLabel'), this.stats.total.toString())
            this.statCell(t('tags.usedLabel'), this.stats.used.toString())
            this.statCell(t('tags.unusedLabel'), this.stats.unused.toString())
            this.statCell(t('tags.usageCount'), this.stats.totalUsage.toString())
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).padding({ bottom: 8 })
          }

          // 新建
          Row() {
            TextInput({ placeholder: t('tags.newPh'), text: this.newName })
              .layoutWeight(1)
              .height(44)
              .backgroundColor(C.surface)
              .borderRadius(C.radiusSm)
              .padding({ left: 14 })
              .onChange((v: string) => { this.newName = v; })
            Button(this.busy ? '…' : t('common.create'))
              .height(44)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .margin({ left: 8 })
              .enabled(!this.busy)
              .onClick(() => { this.createTag(); })
          }
          .width('100%')
          .margin({ bottom: 16 })

          Text(t('tags.library'))
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .padding({ left: 4, bottom: 8 })
          if (this.loading && this.tags.length === 0) {
            LoadingProgress().margin({ top: 20 })
          } else if (this.tags.length === 0) {
            Text(t('tags.empty')).fontSize(F.body).fontColor(C.ink3).margin({ top: 16 })
          } else {
            Column() {
              ForEach(this.tags, (tag: TagItem) => {
                this.tagRow(tag)
              }, (tag: TagItem) => tag.id)
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .clip(true)
          }

          // 条目 / 附件标签编辑
          this.sectionTitle(t('tags.itemSection'))
          Column() {
            this.inputRow(t('field.itemId'), t('common.numericId'), this.itemId, 1)
            Text(t('tags.selectedLabel') + (this.selectedTagId.length > 0 ? this.selectedTagId : t('tags.noneSelected')))
              .fontSize(F.caption)
              .fontColor(C.accent)
              .padding({ top: 6 })
            Row() {
              Button(t('tags.attach'))
                .layoutWeight(1)
                .height(40)
                .fontSize(F.caption)
                .backgroundColor(C.accentSoft)
                .fontColor(C.accent)
                .borderRadius(C.radiusSm)
                .onClick(() => { this.attachToItem(); })
              Button(t('tags.detach'))
                .layoutWeight(1)
                .height(40)
                .fontSize(F.caption)
                .backgroundColor(C.surfaceAlt)
                .fontColor(C.ink)
                .borderRadius(C.radiusSm)
                .margin({ left: 8 })
                .onClick(() => { this.detachFromItem(); })
            }
            .width('100%')
            .margin({ top: 10 })
            Row() {
              Button(t('tags.viewFields'))
                .layoutWeight(1)
                .height(40)
                .fontSize(F.caption)
                .backgroundColor(C.surfaceAlt)
                .fontColor(C.ink)
                .borderRadius(C.radiusSm)
                .margin({ top: 8 })
                .onClick(() => { this.loadFields(); })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          if (this.fieldsShown) {
            this.fieldList()
          }

          this.sectionTitle(t('tags.attachSection'))
          Column() {
            this.inputRow(t('tags.attachIdLabel'), t('common.numericId'), this.attachId, 2)
            Row() {
              Button(t('tags.addTag'))
                .layoutWeight(1)
                .height(40)
                .fontSize(F.caption)
                .backgroundColor(C.accentSoft)
                .fontColor(C.accent)
                .borderRadius(C.radiusSm)
                .onClick(() => { this.batchTag('add'); })
              Button(t('tags.delTag'))
                .layoutWeight(1)
                .height(40)
                .fontSize(F.caption)
                .backgroundColor(C.surfaceAlt)
                .fontColor(C.ink)
                .borderRadius(C.radiusSm)
                .margin({ left: 8 })
                .onClick(() => { this.batchTag('remove'); })
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(C.surface)
          .borderRadius(C.radius)
          .margin({ bottom: 16 })

          if (this.tip.length > 0) {
            Text(this.tip)
              .fontSize(F.caption)
              .fontColor(C.success)
              .width('100%')
              .padding({ bottom: 8 })
          }
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
    .title(t('nav.tags'))
    .backgroundColor(C.bg)
  }

  onField(kind: number, v: string): void {
    if (kind === 1) {
      this.itemId = v;
    } else if (kind === 2) {
      this.attachId = v;
    }
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
  statCell(label: string, value: string) {
    Column() {
      Text(value).fontSize(20).fontWeight(700).fontColor(C.ink)
      Text(label).fontSize(11).fontColor(C.ink3).margin({ top: 2 })
    }
    .layoutWeight(1)
  }

  @Builder
  inputRow(label: string, placeholder: string, value: string, kind: number) {
    Column() {
      Text(label).fontSize(F.caption).fontColor(C.ink3).padding({ left: 4, bottom: 6 })
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
    .padding({ top: 6 })
  }

  @Builder
  tagRow(tag: TagItem) {
    Row() {
      Text(tag.name)
        .fontSize(F.body)
        .fontColor(this.selectedTagId === tag.id ? C.accent : C.ink)
        .fontWeight(this.selectedTagId === tag.id ? 600 : 400)
        .layoutWeight(1)
      Text(t('tags.ref', i18nVars([['n', (tag.usageCount ?? 0).toString()]])))
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .margin({ right: 10 })
      Button(this.confirmTagId === tag.id ? t('item.confirmDelete') : t('common.delete'))
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .margin({ right: 10 })
      Button(this.confirmTagId === tag.id ? t('item.confirmDelete') : t('common.delete'))
        .height(30)
        .fontSize(11)
        .backgroundColor(this.confirmTagId === tag.id ? C.danger : C.surfaceAlt)
        .fontColor(this.confirmTagId === tag.id ? '#FFFFFF' : C.danger)
        .borderRadius(8)
        .enabled(!this.busy)
        .onClick(() => {
          if (this.confirmTagId === tag.id) {
            this.removeTag(tag.id);
          } else {
            this.confirmTagId = tag.id;
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(this.selectedTagId === tag.id ? C.accentSoft : C.surface)
    .stateStyles({ pressed: { opacity: 0.7 } })
    .onClick(() => { this.selectedTagId = tag.id; })
  }

  @Builder
  fieldList() {
    Column() {
      Text(t('tags.customFields'))
        .fontSize(F.caption)
        .fontColor(C.ink3)
        .width('100%')
        .padding({ left: 4, bottom: 8 })
      if (this.fields.length === 0) {
        Text(t('tags.emptyFields')).fontSize(F.body).fontColor(C.ink3).padding(16)
      } else {
        ForEach(this.fields, (f: ItemFieldValue) => {
          Row() {
            Text(f.fieldName).fontSize(F.body).fontColor(C.ink).layoutWeight(1)
            Text(f.value.length > 0 ? f.value : '—').fontSize(F.caption).fontColor(C.ink2)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .borderWidth({ bottom: 1 }).borderColor(C.hairline)
        }, (f: ItemFieldValue) => f.fieldKey)
      }
    }
    .width('100%')
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .clip(true)
    .margin({ bottom: 16 })
  }
}
