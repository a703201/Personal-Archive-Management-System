import {
  ApiClient, FamilyGroupsData, FamilyGroup, FamilyMembersData, FamilyMember,
  SharedItemsData
} from '../common/api/ApiClient';
import { ArchiveItem } from '../common/models/Models';
import { C, F, applyTheme } from '../common/theme/Theme';
import { t, i18nVars, categoryNameI18n, statusNameI18n } from '../common/theme/I18n';
import { formatDate, sensitivityColor, sensitivityLabel } from '../common/utils/Format';
import { Logger } from '../common/utils/Logger';

/** 家庭组只读视图：/api/family/groups、/:id/members、/shared-items（family.cj）。 */
@Component
export struct FamilyPage {
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @State groups: FamilyGroup[] = [];
  @State members: FamilyMember[] = [];
  @State expandedGroup: string = '';
  @State shared: ArchiveItem[] = [];
  @State sharedTotal: number = 0;
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State detail: ArchiveItem = {} as ArchiveItem;
  @State detailShown: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  onThemeRev(): void {
    applyTheme();
  }

  load(): void {
    this.loading = true;
    this.errorMsg = '';
    ApiClient.getFamilyGroups().then((d: FamilyGroupsData) => {
      this.groups = d.items;
      this.loading = false;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      this.loading = false;
      Logger.warn('FamilyPage', 'groups failed: ' + e.message);
    });
    ApiClient.getSharedItems().then((d: SharedItemsData) => {
      this.shared = d.items;
      this.sharedTotal = d.total;
    }).catch((e: Error) => {
      Logger.warn('FamilyPage', 'shared failed: ' + e.message);
    });
  }

  toggleGroup(g: FamilyGroup): void {
    if (this.expandedGroup === g.groupId) {
      this.expandedGroup = '';
      return;
    }
    this.expandedGroup = g.groupId;
    this.members = [];
    ApiClient.getFamilyMembers(g.groupId).then((d: FamilyMembersData) => {
      this.members = d.items;
    }).catch((e: Error) => {
      Logger.warn('FamilyPage', 'members failed: ' + e.message);
    });
  }

  showDetail(it: ArchiveItem): void {
    ApiClient.getSharedItem(it.id).then((d: ArchiveItem) => {
      this.detail = d;
      this.detailShown = true;
    }).catch((e: Error) => {
      this.errorMsg = e.message;
      Logger.warn('FamilyPage', 'shared detail failed: ' + e.message);
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          if (this.errorMsg.length > 0) {
            Text(this.errorMsg).fontSize(F.caption).fontColor(C.danger).padding({ bottom: 8 })
          }

          this.sectionTitle(t('family.groupsSection'))
          if (this.loading && this.groups.length === 0) {
            LoadingProgress().margin({ top: 20 })
          } else if (this.groups.length === 0) {
            Text(t('family.emptyGroups')).fontSize(F.body).fontColor(C.ink3).margin({ top: 16 })
          } else {
            ForEach(this.groups, (g: FamilyGroup) => {
              Column() {
                Row() {
                  Column() {
                    Text(g.name).fontSize(F.body).fontWeight(600).fontColor(C.ink)
                    Text(t('family.myRole', i18nVars([['role', g.myRole], ['n', g.memberCount.toString()]])))
                      .fontSize(F.caption)
                      .fontColor(C.ink3)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  Text(this.expandedGroup === g.groupId ? t('common.collapse') : t('common.expand'))
                    .fontSize(F.caption)
                    .fontColor(C.accent)
                }
                .width('100%')
                .padding(16)
                .stateStyles({ pressed: { opacity: 0.7 } })
                .onClick(() => { this.toggleGroup(g); })

                if (this.expandedGroup === g.groupId) {
                  Column() {
                    if (this.members.length === 0) {
                      Text(t('family.emptyMembers')).fontSize(F.caption).fontColor(C.ink3).padding(16)
                    } else {
                      ForEach(this.members, (m: FamilyMember) => {
                        Row() {
                          Column() {
                            Text(m.nickname.length > 0 ? m.nickname : m.username)
                              .fontSize(F.body).fontColor(C.ink)
                            Text('@' + m.username + ' · ' + t('family.joined') + ' ' + formatDate(m.joinedAt))
                              .fontSize(F.caption).fontColor(C.ink3).margin({ top: 2 })
                          }
                          .layoutWeight(1)
                          Text(m.role).fontSize(F.caption).fontColor(C.accent)
                        }
                        .width('100%')
                        .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                        .borderWidth({ bottom: 1 }).borderColor(C.hairline)
                      }, (m: FamilyMember) => m.userId)
                    }
                  }
                  .width('100%')
                  .backgroundColor(C.surfaceAlt)
                }
              }
              .width('100%')
              .backgroundColor(C.surface)
              .borderRadius(C.radius)
              .clip(true)
              .margin({ bottom: 10 })
            }, (g: FamilyGroup) => g.groupId)
          }

          this.sectionTitle(t('family.sharedSection', i18nVars([['n', this.sharedTotal.toString()]])))
          if (this.shared.length === 0) {
            Text(t('family.emptyShared')).fontSize(F.body).fontColor(C.ink3).margin({ top: 16 })
          } else {
            Column() {
              ForEach(this.shared, (it: ArchiveItem) => {
                this.sharedRow(it)
              }, (it: ArchiveItem) => it.id)
            }
            .width('100%')
            .backgroundColor(C.surface)
            .borderRadius(C.radius)
            .clip(true)
          }

          if (this.detailShown) {
            Column() {
              Row() {
                Text(t('family.detailTitle')).fontSize(F.body).fontWeight(600).fontColor(C.ink).layoutWeight(1)
                Text(t('common.close')).fontSize(F.caption).fontColor(C.accent)
                  .onClick(() => { this.detailShown = false; })
              }
              .width('100%')
              .padding({ bottom: 8 })
              Text(this.detail.title.length > 0 ? this.detail.title : '—')
                .fontSize(F.body).fontColor(C.ink).width('100%')
              Text(categoryNameI18n(this.detail.category) + ' · ' + statusNameI18n(this.detail.status))
                .fontSize(F.caption).fontColor(C.ink3).width('100%').padding({ top: 4 })
              Text(t('family.issuerLabel') + (this.detail.issuer ?? '—'))
                .fontSize(F.caption).fontColor(C.ink2).width('100%').padding({ top: 4 })
              Text(t('family.remarkLabel') + (this.detail.remark ?? '—'))
                .fontSize(F.caption).fontColor(C.ink2).width('100%').padding({ top: 4 })
              Text(t('family.updatedLabel') + formatDate(this.detail.updatedAt))
                .fontSize(F.caption).fontColor(C.ink3).width('100%').padding({ top: 4 })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(C.accentSoft)
            .borderRadius(C.radius)
            .margin({ top: 12 })
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
    .title(t('nav.family'))
    .backgroundColor(C.bg)
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
  sharedRow(it: ArchiveItem) {
    Row() {
      Column() {
        Text(it.title)
          .fontSize(F.body)
          .fontColor(C.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(categoryNameI18n(it.category) + ' · ' + statusNameI18n(it.status)
          + ' · ' + t('common.updatedPrefix') + formatDate(it.updatedAt))
          .fontSize(F.caption)
          .fontColor(C.ink3)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      Text(sensitivityLabel(it.sensitivity))
        .fontSize(11)
        .fontColor(sensitivityColor(it.sensitivity))
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(8)
        .backgroundColor(C.surfaceAlt)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderWidth({ bottom: 1 }).borderColor(C.hairline)
    .stateStyles({ pressed: { opacity: 0.7 } })
    .onClick(() => { this.showDetail(it); })
  }
}
