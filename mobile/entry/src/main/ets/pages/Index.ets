import { LoginPage } from './LoginPage';
import { HomePage } from './HomePage';
import { ItemsPage } from './ItemsPage';
import { ItemDetailPage } from './ItemDetailPage';
import { SearchPage } from './SearchPage';
import { SettingsPage } from './SettingsPage';
import { RecycleBinPage } from './RecycleBinPage';
import { ItemEditPage } from './ItemEditPage';
import { NotificationsPage } from './NotificationsPage';
import { SubjectsPage } from './SubjectsPage';
import { TagsPage } from './TagsPage';
import { ShareLinksPage } from './ShareLinksPage';
import { TemplatesPage } from './TemplatesPage';
import { ItemVersionsPage } from './ItemVersionsPage';
import { SystemPage } from './SystemPage';
import { FamilyPage } from './FamilyPage';
import { AttachmentsPage } from './AttachmentsPage';
import { TasksPage } from './TasksPage';
import { AboutPage } from './AboutPage';
import { ArchiveItem, CategoryRef, EditParam } from '../common/models/Models';
import { C, applyTheme } from '../common/theme/Theme';

@Entry
@Component
struct Index {
  @StorageLink('ams_logged_in') isLoggedIn: boolean = false;
  @StorageLink('ams_safe_top') safeTop: number = 0;
  @StorageLink('ams_safe_bottom') safeBottom: number = 0;
  @StorageLink('ams_theme_rev') @Watch('onThemeRev') themeRev: number = 0;
  @Provide('navPathStack') navPathStack: NavPathStack = new NavPathStack();

  onThemeRev(): void {
    applyTheme();
  }

  @Builder
  pageMap(name: string, param: Object) {
    if (name === 'Items') {
      ItemsPage({ category: param as CategoryRef });
    } else if (name === 'ItemDetail') {
      ItemDetailPage({ item: param as ArchiveItem });
    } else if (name === 'Search') {
      SearchPage();
    } else if (name === 'Settings') {
      SettingsPage();
    } else if (name === 'RecycleBin') {
      RecycleBinPage();
    } else if (name === 'ItemEdit') {
      ItemEditPage({ param: param as EditParam });
    } else if (name === 'Notifications') {
      NotificationsPage();
    } else if (name === 'Subjects') {
      SubjectsPage();
    } else if (name === 'Tags') {
      TagsPage();
    } else if (name === 'ShareLinks') {
      ShareLinksPage();
    } else if (name === 'Templates') {
      TemplatesPage();
    } else if (name === 'ItemVersions') {
      ItemVersionsPage({ item: param as ArchiveItem });
    } else if (name === 'System') {
      SystemPage();
    } else if (name === 'Family') {
      FamilyPage();
    } else if (name === 'Attachments') {
      AttachmentsPage({ item: param as ArchiveItem });
    } else if (name === 'Tasks') {
      TasksPage();
    } else if (name === 'About') {
      AboutPage();
    }
  }

  build() {
    Column() {
      if (!this.isLoggedIn) {
        LoginPage();
      } else {
        Navigation(this.navPathStack) {
          HomePage()
        }
        .navDestination(this.pageMap)
        // 首页由 HomePage 自己渲染「档案库」大标题，隐藏 Navigation 的重复标题栏。
        // NavDestination 有独立的 hideTitleBar，子页面的返回栏不受影响。
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C.bg)
    // 全屏沉浸下背景铺满整屏，内容避开状态栏与底部手势区。
    // safeTop/safeBottom 是 px 原值，用带单位字符串让 ArkUI 按物理像素解释。
    .padding({ top: this.safeTop + 'px', bottom: this.safeBottom + 'px' })
  }
}
