import { ApiClient, ItemsData, ItemQuery } from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars, categoryNameI18n } from '../common/theme/I18n';
import { ArchiveItem, CategoryRef, EditParam } from '../common/models/Models';
import { sensitivityColor, sensitivityLabel, formatDate } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

@Component
export struct ItemsPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @StorageLink('ams_data_version') @Watch('onDataChanged') dataVersion: number = 0;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State category: CategoryRef = { code: 0, name: '' };
  @State items: ArchiveItem[] = [];
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  onDataChanged(): void {
    this.load();
  }

  goCreate(): void {
    const param: EditParam = { mode: 'create', category: this.category.code, subjectId: '' };
    this.navPathStack.pushPath({ name: 'ItemEdit', param: param });
  }

  /**
   * 不传 subjectId —— 后端会按「服务端算出的全部可访问主体」返回条目，
   * 并自动并入家庭授权条目。旧版硬取 subjects[0].id 会漏掉其余主体的数据。
   */
  load(): void {
    this.errorMsg = '';
    this.loading = true;
    const query: ItemQuery = { category: this.category.code, size: 50 };
    ApiClient.getItems(query).then((data: ItemsData) => {
      this.items = data.items;
      this.loading = false;
      this.refreshing = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      this.refreshing = false;
      Logger.warn('ItemsPage', 'load failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Column() {
        // 按钮的 width('100%') 与左右 margin 会互相挤压导致贴边，
        // 改由外层 Column 的 padding 承担左右留白。
        Column() {
          Button(t('items.new'))
            .width('100%')
            .height(44)
            .fontSize(F.body)
            .backgroundColor(C.accentSoft)
            .fontColor(C.accent)
            .borderRadius(C.radiusSm)
            .onClick(() => { this.goCreate(); })
        }
        .width('100%')
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 6 })

        if (this.loading && this.items.length === 0) {
          Column() {
            LoadingProgress().width(28).height(28)
            Text(t('common.loading')).fontSize(F.caption).fontColor(C.ink3).margin({ top: 12 })
          }
          .margin({ top: 60 })
        } else if (this.errorMsg.length > 0 && this.items.length === 0) {
          Column() {
            Text(this.errorMsg).fontColor(C.danger).fontSize(F.body)
            Button(t('common.retry'))
              .height(40)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .fontSize(F.body)
              .borderRadius(C.radiusSm)
              .margin({ top: 16 })
              .onClick(() => { this.load(); })
          }
          .margin({ top: 60 })
          .padding({ left: F.pad, right: F.pad })
        } else if (this.items.length === 0) {
          Text(t('items.empty', i18nVars([['cat', categoryNameI18n(this.category.code)]])))
            .fontColor(C.ink3)
            .fontSize(F.body)
            .margin({ top: 60 })
        } else {
          Refresh({ refreshing: $$this.refreshing }) {
            List() {
              ForEach(this.items, (it: ArchiveItem) => {
                ListItem() {
                  this.itemRow(it)
                }
                .onClick(() => {
                  this.navPathStack.pushPath({ name: 'ItemDetail', param: it });
                })
              }, (it: ArchiveItem) => it.id)
            }
            .width('100%')
            .height('100%')
            .divider({ strokeWidth: 1, color: C.hairline, startMargin: 16, endMargin: 16 })
          }
          .layoutWeight(1)
          .width('100%')
          .onRefreshing(() => { this.load(); })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(C.bg)
    }
    .title(categoryNameI18n(this.category.code))
    .backgroundColor(C.bg)
  }

  @Builder
  itemRow(it: ArchiveItem) {
    Row() {
      Column()
        .width(8).height(8).borderRadius(4)
        .backgroundColor(sensitivityColor(it.sensitivity))
        .margin({ right: 12 })
      Column() {
        Text(it.title)
          .fontSize(F.body)
          .fontWeight(500)
          .fontColor(C.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          if (it.issuer && it.issuer.length > 0) {
            Text(it.issuer)
              .fontSize(F.caption)
              .fontColor(C.ink3)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(t('items.updated') + ' ' + formatDate(it.updatedAt))
            .fontSize(F.caption)
            .fontColor(C.ink3)
        }
        .margin({ top: 4 })
      }
      .layoutWeight(1)
      if (it.shared === true) {
        Text(t('items.shared'))
          .fontSize(11)
          .fontColor(C.accent)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor(C.accentSoft)
          .margin({ right: 6 })
      }
      Text(sensitivityLabel(it.sensitivity))
        .fontSize(11)
        .fontColor(sensitivityColor(it.sensitivity))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
        .backgroundColor(C.surfaceAlt)
    }
    .width('100%')
    .padding({ left: F.pad, right: F.pad, top: 14, bottom: 14 })
    .backgroundColor(C.surface)
  }
}
