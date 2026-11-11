import { ApiClient, SearchData } from '../common/api/ApiClient';
import { C, F } from '../common/theme/Theme';
import { ArchiveItem, CATEGORIES, CategoryRef } from '../common/models/Models';
import { sensitivityColor, sensitivityLabel, statusLabel, statusColor } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

@Component
export struct SearchPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @State query: string = '';
  @State results: ArchiveItem[] = [];
  @State searched: boolean = false;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errorMsg: string = '';
  @State category: number = 0;
  @State nextCursor: string = '';
  @State hasMore: boolean = false;

  doSearch(): void {
    if (this.query.trim().length === 0) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    this.nextCursor = '';
    this.hasMore = false;
    ApiClient.search(this.query.trim(), this.category).then((d: SearchData) => {
      this.results = d.items;
      this.nextCursor = d.nextCursor ?? '';
      this.hasMore = d.hasMore;
      this.searched = true;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('SearchPage', 'search failed: ' + e.message);
    });
  }

  /** 按后端返回的 nextCursor 追加下一页，而不是重复第一页。 */
  loadMore(): void {
    if (this.nextCursor.length === 0 || this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    ApiClient.search(this.query.trim(), this.category, this.nextCursor).then((d: SearchData) => {
      const merged: ArchiveItem[] = this.results.slice();
      for (let i = 0; i < d.items.length; i++) {
        merged.push(d.items[i]);
      }
      this.results = merged;
      this.nextCursor = d.nextCursor ?? '';
      this.hasMore = d.hasMore;
      this.loadingMore = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loadingMore = false;
      Logger.warn('SearchPage', 'loadMore failed: ' + e.message);
    });
  }

  pickCategory(code: number): void {
    this.category = code;
    if (this.searched) {
      this.doSearch();
    }
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          TextInput({ placeholder: '搜索档案、证件、条目…', text: this.query })
            .layoutWeight(1)
            .height(44)
            .backgroundColor(C.surfaceAlt)
            .borderRadius(C.radiusSm)
            .padding({ left: 16 })
            .onChange((v: string) => { this.query = v; })
            .onSubmit(() => { this.doSearch(); })
          Button('搜索')
            .height(44)
            .borderRadius(C.radiusSm)
            .backgroundColor(C.accent)
            .fontColor('#FFFFFF')
            .onClick(() => { this.doSearch(); })
            .margin({ left: 8 })
        }
        .padding({ left: F.pad, right: F.pad, top: 12, bottom: 8 })

        // 分类筛选（横向滚动，0 = 全部）
        Scroll() {
          Row() {
            Text('全部')
              .fontSize(F.caption)
              .fontColor(this.category === 0 ? '#FFFFFF' : C.ink2)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.category === 0 ? C.accent : C.surface)
              .margin({ right: 8 })
              .onClick(() => { this.pickCategory(0); })
            ForEach(CATEGORIES, (cat: CategoryRef) => {
              Text(cat.name)
                .fontSize(F.caption)
                .fontColor(this.category === cat.code ? '#FFFFFF' : C.ink2)
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(16)
                .backgroundColor(this.category === cat.code ? C.accent : C.surface)
                .margin({ right: 8 })
                .onClick(() => { this.pickCategory(cat.code); })
            }, (cat: CategoryRef) => cat.code.toString())
          }
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .padding({ left: F.pad, right: F.pad, bottom: 10 })

        if (this.loading) {
          LoadingProgress().margin({ top: 40 })
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text(this.errorMsg).fontSize(F.body).fontColor(C.danger)
            Button('重试')
              .height(40)
              .fontSize(F.body)
              .backgroundColor(C.accent)
              .fontColor('#FFFFFF')
              .borderRadius(C.radiusSm)
              .margin({ top: 16 })
              .onClick(() => { this.doSearch(); })
          }
          .margin({ top: 60 })
        } else if (this.searched && this.results.length === 0) {
          Text('未找到相关条目').fontColor(C.ink3).margin({ top: 60 })
        } else if (!this.searched) {
          Text('输入关键词开始搜索').fontColor(C.ink3).margin({ top: 60 })
        } else {
          List() {
            ForEach(this.results, (it: ArchiveItem) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(it.title).fontSize(F.body).fontWeight(500).fontColor(C.ink)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Row() {
                      Text(statusLabel(it.status)).fontSize(11).fontColor(statusColor(it.status))
                      if (it.issuer && it.issuer.length > 0) {
                        Text(' · ' + it.issuer)
                          .fontSize(F.caption)
                          .fontColor(C.ink3)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                    }
                    .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  Text(sensitivityLabel(it.sensitivity)).fontSize(11)
                    .fontColor(sensitivityColor(it.sensitivity))
                    .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                    .borderRadius(8).backgroundColor(C.surfaceAlt)
                }
                .width('100%').padding({ left: F.pad, right: F.pad, top: 14, bottom: 14 })
                .backgroundColor(C.surface)
              }
              .onClick(() => {
                this.navPathStack.pushPath({ name: 'ItemDetail', param: it });
              })
            }, (it: ArchiveItem) => it.id)

            if (this.hasMore && this.nextCursor.length > 0) {
              ListItem() {
                Row() {
                  if (this.loadingMore) {
                    LoadingProgress().width(20).height(20).margin({ right: 8 })
                  }
                  Text(this.loadingMore ? '加载中…' : '加载更多')
                    .fontSize(F.caption)
                    .fontColor(C.accent)
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
                .onClick(() => { this.loadMore(); })
              }
            }
          }
          .width('100%').layoutWeight(1)
          .divider({ strokeWidth: 1, color: C.hairline, startMargin: 16, endMargin: 16 })
        }
      }
      .width('100%').height('100%').backgroundColor(C.bg)
    }
    .title('搜索')
    .backgroundColor(C.bg)
  }
}
