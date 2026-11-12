import { ApiClient, SearchData } from '../common/api/ApiClient';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, categoryNameI18n } from '../common/theme/I18n';
import { ArchiveItem, CATEGORIES, CategoryRef, HighlightSegment } from '../common/models/Models';
import { sensitivityColor, sensitivityLabel, statusLabel, statusColor } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

@Component
export struct SearchPage {
  @Consume('navPathStack') navPathStack: NavPathStack;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
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

  onThemeRev(): void {
    applyTheme();
  }

  /** 取 /api/search 返回的 title 高亮片段；无则空数组。 */
  titleSegments(it: ArchiveItem): HighlightSegment[] {
    if (it.highlight !== undefined && it.highlight.title !== undefined) {
      return it.highlight.title;
    }
    return [];
  }

  issuerSegments(it: ArchiveItem): HighlightSegment[] {
    if (it.highlight !== undefined && it.highlight.issuer !== undefined) {
      return it.highlight.issuer;
    }
    return [];
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          TextInput({ placeholder: t('common.searchPh'), text: this.query })
            .layoutWeight(1)
            .height(44)
            .backgroundColor(C.surfaceAlt)
            .borderRadius(C.radiusSm)
            .padding({ left: 16 })
            .onChange((v: string) => { this.query = v; })
            .onSubmit(() => { this.doSearch(); })
          Button(t('common.search'))
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
            Text(t('common.all'))
              .fontSize(F.caption)
              .fontColor(this.category === 0 ? '#FFFFFF' : C.ink2)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(16)
              .backgroundColor(this.category === 0 ? C.accent : C.surface)
              .margin({ right: 8 })
              .onClick(() => { this.pickCategory(0); })
            ForEach(CATEGORIES, (cat: CategoryRef) => {
              Text(categoryNameI18n(cat.code))
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
            Button(t('common.retry'))
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
          Text(t('search.notFound')).fontColor(C.ink3).margin({ top: 60 })
        } else if (!this.searched) {
          Text(t('search.start')).fontColor(C.ink3).margin({ top: 60 })
        } else {
          List() {
            ForEach(this.results, (it: ArchiveItem) => {
              ListItem() {
                Row() {
                  Column() {
                    if (this.titleSegments(it).length > 0) {
                      this.highlightLine(this.titleSegments(it), F.body)
                    } else {
                      Text(it.title).fontSize(F.body).fontWeight(500).fontColor(C.ink)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    Row() {
                      Text(statusLabel(it.status)).fontSize(11).fontColor(statusColor(it.status))
                      if (this.issuerSegments(it).length > 0) {
                        this.highlightLine(this.issuerSegments(it), F.caption)
                      } else if (it.issuer && it.issuer.length > 0) {
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
                  Text(this.loadingMore ? t('common.loading') : t('search.more'))
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
    .title(t('common.search'))
    .backgroundColor(C.bg)
  }

  /**
   * 渲染后端 SearchHighlighter 的分段高亮：hit=true 用强调色加粗 + 底色，
   * 其余用普通色。全程 Text + 样式，不用 Web 组件、不做 v-html。
   */
  @Builder
  highlightLine(segs: HighlightSegment[], size: number) {
    Row() {
      ForEach(segs, (seg: HighlightSegment) => {
        Text(seg.text)
          .fontSize(size)
          .fontWeight(seg.hit ? 700 : 400)
          .fontColor(seg.hit ? C.warn : C.ink)
          .backgroundColor(seg.hit ? C.accentSoft : '#00000000')
      }, (seg: HighlightSegment, idx: number) => idx.toString())
    }
    .alignItems(VerticalAlign.Center)
  }
}
