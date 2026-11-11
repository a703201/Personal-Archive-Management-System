import { ApiClient, OverviewData, SubjectsData, RecentItem } from '../common/api/ApiClient';
import { C, F } from '../common/theme/Theme';
import { CATEGORIES, CategoryRef, ArchiveItem, categoryName, Subject } from '../common/models/Models';
import { formatDate } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

@Component
export struct HomePage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @StorageLink('ams_data_version') @Watch('onDataChanged') dataVersion: number = 0;
  @State subjects: Subject[] = [];
  @State overview: OverviewData = { total: 0, categories: [], recent: [], unreadNotifications: 0 };
  @State loading: boolean = false;
  @State refreshing: boolean = false;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  onDataChanged(): void {
    this.load();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getOverview().then((data: OverviewData) => {
      this.overview = data;
      this.loading = false;
      this.refreshing = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      this.refreshing = false;
      Logger.warn('HomePage', 'overview failed: ' + e.message);
    });
    ApiClient.getSubjects().then((data: SubjectsData) => {
      this.subjects = data.subjects;
    }).catch((e: Error) => {
      Logger.warn('HomePage', 'subjects failed: ' + e.message);
    });
  }

  /** 普通方法而非 get 访问器：ArkUI 状态变换器会整段丢弃 @Component 上的 get。 */
  countOf(code: number): number {
    for (let i = 0; i < this.overview.categories.length; i++) {
      if (this.overview.categories[i].category === code) {
        return this.overview.categories[i].count;
      }
    }
    return 0;
  }

  goCategory(cat: CategoryRef): void {
    this.navPathStack.pushPath({ name: 'Items', param: cat });
  }

  goSearch(): void {
    this.navPathStack.pushPath({ name: 'Search' });
  }

  goSettings(): void {
    this.navPathStack.pushPath({ name: 'Settings' });
  }

  goNotifications(): void {
    this.navPathStack.pushPath({ name: 'Notifications' });
  }

  goRecent(id: number): void {
    ApiClient.getItem(id.toString()).then((item: ArchiveItem) => {
      this.navPathStack.pushPath({ name: 'ItemDetail', param: item });
    }).catch((e: Error) => {
      Logger.warn('HomePage', 'recent detail failed: ' + e.message);
    });
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('档案库')
            .fontSize(F.display)
            .fontWeight(700)
            .fontColor(C.ink)
            .letterSpacing(-0.5)
          Text(this.subjects.length > 0 ? `已管理 ${this.subjects.length} 位主体` : '个人档案随身管理')
            .fontSize(F.caption)
            .fontColor(C.ink3)
            .margin({ top: 4 })
        }
        // Column 默认水平居中；显式左对齐，与下方卡片网格保持同一边距线。
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .alignSelf(ItemAlign.Center)
        Text('设置')
          .fontSize(F.body)
          .fontColor(C.accent)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .onClick(() => { this.goSettings(); })
      }
      .padding({ left: F.pad, right: F.pad, top: 28, bottom: 16 })

      Row() {
        Text('搜索档案、证件、条目…')
          .fontSize(F.body)
          .fontColor(C.ink3)
          .layoutWeight(1)
      }
      .height(48)
      .padding({ left: 16 })
      .margin({ left: F.pad, right: F.pad, bottom: 16 })
      .backgroundColor(C.surface)
      .borderRadius(C.radiusSm)
      .stateStyles({ pressed: { opacity: 0.7 } })
      .onClick(() => { this.goSearch(); })

      if (this.errorMsg.length > 0) {
        Row() {
          Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).layoutWeight(1)
          Text('重试').fontSize(F.caption).fontColor(C.accent)
            .onClick(() => { this.load(); })
        }
        .padding({ left: F.pad, right: F.pad, bottom: 8 })
      }

      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            // 概览卡
            Row() {
              Column() {
                Text('档案条目')
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                Text(this.overview.total.toString())
                  .fontSize(30)
                  .fontWeight(700)
                  .fontColor(C.ink)
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              Column() {
                Text('未读提醒')
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                Text(this.overview.unreadNotifications.toString())
                  .fontSize(30)
                  .fontWeight(700)
                  .fontColor(this.overview.unreadNotifications > 0 ? C.warn : C.ink)
                  .margin({ top: 4 })
                Text('点击查看 ›')
                  .fontSize(11)
                  .fontColor(C.accent)
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .onClick(() => { this.goNotifications(); })
              Column() {
                Text('主体')
                  .fontSize(F.caption)
                  .fontColor(C.ink3)
                Text(this.subjects.length.toString())
                  .fontSize(30)
                  .fontWeight(700)
                  .fontColor(C.ink)
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
            }
            .width('100%')
            .padding(20)
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .margin({ bottom: 20 })

            if (this.overview.recent.length > 0) {
              Text('最近更新')
                .width('100%')
                .textAlign(TextAlign.Start)
                .fontSize(F.body)
                .fontWeight(600)
                .fontColor(C.ink)
                .padding({ left: 4, bottom: 10 })
              Column() {
                ForEach(this.overview.recent, (rec: RecentItem) => {
                  Row() {
                    Column() {
                      Text(rec.title)
                        .fontSize(F.body)
                        .fontColor(C.ink)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(categoryName(rec.category) + ' · ' + formatDate(rec.updatedAt))
                        .fontSize(F.caption)
                        .fontColor(C.ink3)
                        .margin({ top: 4 })
                    }
                    .layoutWeight(1)
                    Text('›').fontSize(20).fontColor(C.ink3)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                  .backgroundColor(C.surface)
                  .stateStyles({ pressed: { opacity: 0.7 } })
                  .onClick(() => { this.goRecent(rec.id); })
                }, (rec: RecentItem) => rec.id.toString())
              }
              .width('100%')
              .borderRadius(C.radius)
              .clip(true)
              .margin({ bottom: 20 })
            }

            Text('分类')
              .width('100%')
              .textAlign(TextAlign.Start)
              .fontSize(F.body)
              .fontWeight(600)
              .fontColor(C.ink)
              .padding({ left: 4, bottom: 16 })

            List({ space: 16 }) {
              ForEach(CATEGORIES, (cat: CategoryRef) => {
                ListItem() {
                  this.categoryCard(cat)
                }
              }, (cat: CategoryRef) => cat.code.toString())
            }
            .width('100%')
            .lanes(2)
          }
          .padding({ left: F.pad, right: F.pad, bottom: 32 })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        // 隐藏右侧常驻的灰色滚动条，保持首页干净。
        .scrollBar(BarState.Off)
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => { this.load(); })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C.bg)
  }

  @Builder
  categoryCard(cat: CategoryRef) {
    Row() {
      Text(cat.name.substring(0, 1))
        .fontSize(17)
        .fontWeight(600)
        .fontColor(C.accent)
        .width(36)
        .height(36)
        .borderRadius(9)
        .backgroundColor(C.accentSoft)
        .textAlign(TextAlign.Center)
      Column() {
        Text(cat.name)
          // 明确占满父宽，textOverflow 才按可用宽度省略；配合略小的字号，
          // 让「个人基本信息」这类 6 字名称不再被截成「个人基本…」。
          .width('100%')
          .fontSize(14)
          .fontWeight(500)
          .fontColor(C.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.countOf(cat.code) + ' 条')
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .margin({ top: 6 })
      }
      .layoutWeight(1)
      .margin({ left: 10 })
      .alignSelf(ItemAlign.Center)
    }
    .width('100%')
    .backgroundColor(C.surface)
    .borderRadius(C.radius)
    .padding({ left: 14, right: 14, top: 18, bottom: 18 })
    .stateStyles({ pressed: { opacity: 0.7 } })
    .onClick(() => { this.goCategory(cat); })
  }
}
