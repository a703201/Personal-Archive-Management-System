import { http } from '@kit.NetworkKit';
import { AuthStore } from '../store/AuthStore';
import { CacheStore } from '../store/CacheStore';
import { Subject, ArchiveItem } from '../models/Models';
import { Fingerprint } from '../crypto/Fingerprint';
import { t, i18nVars } from '../theme/I18n';

// 后端地址不再硬编码：默认本地 8080，登录页/设置页可手动修改并持久化（见 AuthStore）。

// ---------------------------------------------------------------
// 响应数据结构（与 packages/ams-api/src/routes/*.cj 的真实契约对齐）
// ---------------------------------------------------------------

export interface CaptchaData {
  captchaId: string;
  svg: string;
  expiresAt: number;
}

export interface LoginData {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export interface SubjectsData {
  subjects: Subject[];
  total: number;
}

export interface ItemsData {
  items: ArchiveItem[];
  total: number;
  page: number;
  size: number;
}

export interface SearchData {
  items: ArchiveItem[];
  hasMore: boolean;
  size: number;
  /** 后端字段名是 nextCursor（不是 cursor），用于下一页游标。 */
  nextCursor: string;
}

/** GET /api/items/:id 返回的是 {"item":{...}} 包装，不是裸条目。 */
export interface ItemDetailData {
  item: ArchiveItem;
}

export interface MeData {
  id: number;
  username: string;
  nickname: string;
  email: string;
  phone: string;
  status: number;
  perms: string[];
}

export interface CategoryCount {
  category: number;
  count: number;
}

export interface RecentItem {
  id: number;
  category: number;
  title: string;
  updatedAt: number;
}

export interface OverviewData {
  total: number;
  categories: CategoryCount[];
  recent: RecentItem[];
  unreadNotifications: number;
}

export interface RecycleBinData {
  items: ArchiveItem[];
  total: number;
}

export interface CreateItemData {
  id: string;
}

/** 各写接口的确认包（字段随路由不同，全部可选）。 */
export interface AckData {
  updated?: boolean;
  deleted?: boolean;
  restored?: boolean;
  loggedOut?: boolean;
  read?: boolean;
}

export interface CloneData {
  id: string;
  sourceId: string;
}

/** GET /api/notifications 的行字段（DB 列名，is_read 可能是 't'/'f' 或布尔）。 */
export interface NotificationItem {
  id: string;
  category: string;
  title: string;
  body: string;
  link?: string;
  priority: number;
  is_read: string | boolean;
  created_at_ms: number;
}

export interface NotificationsData {
  items: NotificationItem[];
  total: number;
}

// ---------------------------------------------------------------
// 请求参数结构（ArkTS 严格模式：对象字面量必须有显式接口）
// ---------------------------------------------------------------

export interface ItemQuery {
  category: number;
  subjectId?: string;
  page?: number;
  size?: number;
}

export interface ItemWriteRequest {
  subjectId: string;
  category: number;
  title: string;
  status: number;
  sensitivity: number;
  issuedDate: string;
  expiresAt: string;
  issuer: string;
  remark: string;
}

export interface ItemUpdateRequest {
  version: number;
  title: string;
  sensitivity: number;
  issuedDate: string;
  expiresAt: string;
  issuer: string;
  remark: string;
}

interface LoginRequest {
  username: string;
  password: string;
  captchaId: string;
  captchaCode: string;
}

/** POST /api/items/:id/status：目标状态 + 乐观锁版本。 */
export interface StatusBody {
  status: number;
  version: number;
}

/** POST /api/me/password：原口令 + 新口令。 */
export interface ChangePasswordBody {
  oldPassword: string;
  newPassword: string;
}

/** 空的 POST 请求体（部分路由不读 body，但带一个 {} 更稳妥）。 */
interface EmptyBody {
  _?: string;
}

/** DELETE /api/items/:id 后端强制解析 JSON body，必须带 version。 */
interface VersionBody {
  version: number;
}

/** POST /api/auth/refresh 的请求体。 */
interface RefreshRequest {
  refreshToken: string;
}

interface ApiEnvelope {
  code: string;
  message: string;
  data: Object;
}

// ---------------------------------------------------------------
// 主体管理（routes/subjects.cj）
// ---------------------------------------------------------------
export interface SubjectWriteRequest {
  name: string;
  alias?: string;
  relation?: number;
  summary?: string;
}

/** PUT /api/subjects/:id：version 必填（乐观锁），name 省略时沿用原值。 */
export interface SubjectUpdateRequest {
  version: number;
  name?: string;
  alias?: string;
  relation?: number;
  summary?: string;
}

export interface CreateSubjectData {
  id: string;
}

export interface DeleteSubjectData {
  deleted: boolean;
  orphanItems: number;
}

// ---------------------------------------------------------------
// 标签（routes/management.cj · 字段（routes/fielddefs.cj）
// ---------------------------------------------------------------
export interface TagItem {
  id: string;
  name: string;
  color?: string;
  category?: number;
  usageCount?: number;
  parentId?: string;
  depth?: number;
  childCount?: number;
  lastUsedAt?: string;
}

export interface TagsData {
  items: TagItem[];
  total: number;
  maxDepth?: number;
}

export interface TagStatsData {
  total: number;
  used: number;
  unused: number;
  totalUsage: number;
  lastUsedAt: string;
}

export interface CreateTagRequest {
  name: string;
  color?: string;
  category?: number;
  parentId?: number;
}

export interface CreateTagData {
  id: number;
}

export interface TagIdBody {
  tagId: number;
}

export interface FieldDefItem {
  id?: string;
  fieldKey: string;
  fieldName: string;
  category?: number;
  dataType: number;
  sensitivity?: number;
}

export interface FieldDefsData {
  fields: FieldDefItem[];
}

export interface ItemFieldValue {
  fieldDefId: number;
  fieldKey: string;
  fieldName: string;
  dataType: number;
  sensitivity: number;
  value: string;
}

export interface ItemFieldsData {
  itemId: number;
  category: number;
  fields: ItemFieldValue[];
}

// ---------------------------------------------------------------
// 共享链接（routes/share.cj）
// ---------------------------------------------------------------
export interface ShareLinkItem {
  id: string;
  token: string;
  itemId: string;
  revoked: boolean;
  expired: boolean;
  viewCount: number;
  failCount: number;
  expiresAt: number;
  createdAt: number;
  lastAccessAt: number;
}

export interface ShareLinksData {
  total: number;
  items: ShareLinkItem[];
}

export interface CreateShareLinkRequest {
  itemId: number;
  expiresInHours?: number;
  maxFails?: number;
  /** 技术凭据，术语用「密码」。 */
  password?: string;
}

export interface CreateShareLinkData {
  id: string;
  token: string;
  url: string;
  protected: boolean;
  maxFails: number;
  expiresAt: number;
}

// ---------------------------------------------------------------
// 条目模板（routes/itemtemplates.cj）
// ---------------------------------------------------------------
export interface ItemTemplate {
  id: string;
  name: string;
  category: number;
  title: string;
  status: number;
  sensitivity: number;
  issuer: string;
  remark: string;
  expiresOffsetDays: number;
  extra: string;
  updatedAt: number;
}

export interface TemplatesData {
  items: ItemTemplate[];
}

export interface ApplyTemplateRequest {
  subjectId: number;
  count: number;
}

export interface ApplyTemplateData {
  created: number;
  ids: string[];
}

// ---------------------------------------------------------------
// 历史版本（routes/items.cj）
// ---------------------------------------------------------------
export interface ItemVersion {
  id: string;
  version: number;
  snapshot: string;
  changedBy: string;
  changedAt: number;
}

export interface VersionsData {
  versions: ItemVersion[];
}

export interface RestoreVersionData {
  restored: boolean;
  fromVersion: number;
}

// ---------------------------------------------------------------
// 系统信息（公开只读端点：auth / setup / branding / i18n）
// ---------------------------------------------------------------
export interface HealthData {
  status: string;
}

export interface SetupDb {
  host: string;
  port: string;
  name: string;
  user: string;
  configured: boolean;
}

export interface SetupMail {
  enabled: boolean;
  host: string;
  port: string;
  user: string;
  fromAddr: string;
  secure: string;
}

export interface SetupStatusData {
  initialized: boolean;
  database: SetupDb;
  mail: SetupMail;
}

export interface BrandingData {
  brandName: string;
  logoUrl: string;
  notice: string;
  footerText: string;
  icpNo: string;
}

export interface LocalesData {
  default: string;
  supported: string[];
}

// ---------------------------------------------------------------
// 家庭组（routes/family.cj）
// ---------------------------------------------------------------
export interface FamilyGroup {
  groupId: string;
  name: string;
  ownerId: string;
  myRole: string;
  memberCount: number;
  createdAt: number;
}

export interface FamilyGroupsData {
  items: FamilyGroup[];
}

export interface FamilyMember {
  userId: string;
  nickname: string;
  username: string;
  role: string;
  joinedAt: number;
  invitedBy: string;
}

export interface FamilyMembersData {
  items: FamilyMember[];
}

export interface SharedItemsData {
  total: number;
  page: number;
  size: number;
  items: ArchiveItem[];
}

// ---------------------------------------------------------------
// 附件（routes/attachments.cj）
// ---------------------------------------------------------------
export interface AttachmentItem {
  id: number;
  subjectId: number;
  itemId: number;
  category: number;
  title: string;
  currentVersionId: number;
  versionCount: number;
  fileSize: number;
  fileExt: string;
  mimeType: string;
  status: number;
  downloadCount: number;
  summary: string;
  keywords: string;
  ocrText: string;
  ocrStatus: number;
  ocrEngine: string;
  mediaError: string;
}

export interface AttachmentsData {
  attachments: AttachmentItem[];
}

/** GET /api/attachments/:id/download：正文是 base64 字符串。 */
export interface DownloadData {
  id: number;
  size: number;
  base64: string;
}

export interface UploadData {
  id: number;
  dedupHit: boolean;
  status: number;
}

// ---------------------------------------------------------------
// 导入 / 导出任务（routes/import.cj、routes/export.cj）
// ---------------------------------------------------------------
export interface TaskRecord {
  id: string;
  taskNo: string;
  type: string;
  status: number;
  total: number;
  done: number;
  failed: number;
  percent: number;
  format: string;
  rows: number;
  expiresAt: number;
  error: string;
  createdAt: number;
  updatedAt: number;
}

export interface TasksData {
  total: number;
  items: TaskRecord[];
}

/** status 0 待处理 / 1 运行中 / 2 成功 / 3 失败 / 4 已取消 / 5 已过期。 */
export interface CreateExportRequest {
  scope: string;
  itemId?: number;
  category?: number;
  status?: number;
  keyword?: string;
  format: string;
  includeHighSensitivity?: boolean;
  confirmToken?: string;
}

export interface CreateExportData {
  taskNo: string;
  status: number;
  scope: string;
  format: string;
  expiresInDays: number;
}

export interface CreateImportRequest {
  csv: string;
  subjectId?: number;
}

export interface CreateImportData {
  taskNo: string;
  status: number;
}

/** POST /api/attachments/batch/tag：批量给附件加/删标签。 */
export interface BatchTagRequest {
  ids: number[];
  tagIds: number[];
  mode: string;
}

export interface BatchTagData {
  attachments: number;
  tags: number;
  changed: number;
  mode: string;
}

/** 单次上传的入参（元数据走 query，内容走原始字节体）。 */
export interface UploadAttachmentParams {
  fileName: string;
  title: string;
  category: number;
  itemId: string;
  subjectId: string;
  data: ArrayBuffer;
}

export class ApiClient {
  static authExpired(): string {
    return t('api.authExpired');
  }

  /** 并发 401 共享同一个刷新 Promise：refreshToken 是一次性的，重复刷新会触发后端重放检测并吊销全部会话。 */
  private static refreshPromise: Promise<boolean> | null = null;

  static tryRefresh(): Promise<boolean> {
    if (ApiClient.refreshPromise !== null) {
      return ApiClient.refreshPromise;
    }
    const p: Promise<boolean> = ApiClient.doRefresh();
    ApiClient.refreshPromise = p;
    p.then(() => {
      ApiClient.refreshPromise = null;
    }).catch(() => {
      ApiClient.refreshPromise = null;
    });
    return p;
  }

  /**
   * accessToken 只有 30 分钟（后端 accessTtlSeconds=1800）。
   * 用一次性 refreshToken 换一对新令牌，并立刻落盘 —— 否则重启后又退回到旧令牌。
   */
  private static async doRefresh(): Promise<boolean> {
    const oldRefresh: string = AuthStore.refresh();
    if (oldRefresh.length === 0) {
      return false;
    }
    const body: RefreshRequest = { refreshToken: oldRefresh };
    const req = http.createHttp();
    try {
      const resp = await req.request(AuthStore.getBaseUrl() + '/api/auth/refresh', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: JSON.stringify(body),
        connectTimeout: 10000,
        readTimeout: 10000
      });
      if (resp.responseCode !== 200) {
        return false;
      }
      const raw: string = resp.result as string;
      const env = JSON.parse(raw) as ApiEnvelope;
      const d = env.data as LoginData;
      if (d.accessToken === undefined || d.accessToken.length === 0) {
        return false;
      }
      AuthStore.save(d.accessToken, d.refreshToken);
      return true;
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /**
   * 统一请求入口。
   *
   * - 401（已登录请求）→ 先自动刷新令牌并重试一次；刷新失败才清空登录态，
   *   Index 的 @StorageLink 自动切回登录页。这是移动端「长期登录」的关键。
   * - cacheable=true 的 GET 成功时写 AppStorage 缓存，网络失败时回退缓存（离线可读）；
   * - 缓存键由 Fingerprint 对 path 生成，与历史版本一致。
   */
  static async request<T>(
    method: http.RequestMethod,
    path: string,
    body?: Object,
    auth: boolean = true,
    cacheable: boolean = false,
    retried: boolean = false
  ): Promise<T> {
    const req = http.createHttp();
    const cacheKey: string = 'ams_cache_' + Fingerprint.fingerprint(path);
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (auth) {
      const t: string = AuthStore.token();
      if (t.length > 0) {
        headers['Authorization'] = 'Bearer ' + t;
      }
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 10000,
      usingCache: false,
      priority: 1
    };
    if (body !== undefined) {
      options.extraData = JSON.stringify(body);
    }
    try {
      const resp = await req.request(AuthStore.getBaseUrl() + path, options);
      const code: number = resp.responseCode;
      const raw: string = resp.result as string;
      if (code === 401 && auth) {
        const refreshed: boolean = await ApiClient.tryRefresh();
        if (refreshed && !retried) {
          // 新令牌已由 AuthStore.save 落盘，递归一次重放原请求。
          return await ApiClient.request<T>(method, path, body, auth, cacheable, true);
        }
        AuthStore.clear();
        throw new Error(ApiClient.authExpired());
      }
      if (code < 200 || code >= 300) {
        let msg: string = t('api.reqFail', i18nVars([['code', code.toString()]]));
        try {
          const env = JSON.parse(raw) as ApiEnvelope;
          if (typeof env.message === 'string' && env.message.length > 0) {
            msg = env.message;
          }
        } catch (e) {}
        throw new Error(msg);
      }
      const env = JSON.parse(raw) as ApiEnvelope;
      if (cacheable) {
        CacheStore.put(cacheKey, raw);
      }
      return env.data as T;
    } catch (e) {
      const msg: string = (e as Error).message;
      if (cacheable && msg !== ApiClient.authExpired()) {
        const cached: string | undefined = CacheStore.get(cacheKey);
        if (cached !== undefined && cached.length > 0) {
          try {
            const env = JSON.parse(cached) as ApiEnvelope;
            return env.data as T;
          } catch (e2) {}
        }
      }
      throw new Error(msg);
    } finally {
      req.destroy();
    }
  }

  /**
   * 刷新时带 old=<上一个 captchaId>，后端会作废旧挑战（与 Web 端一致）。
   * 不带 old 会让旧挑战残留到自然过期，浪费 CaptchaStore 配额。
   */
  static getCaptcha(oldId: string = ''): Promise<CaptchaData> {
    const path: string = oldId.length > 0
      ? '/api/auth/captcha?old=' + encodeURIComponent(oldId)
      : '/api/auth/captcha';
    return ApiClient.request<CaptchaData>(http.RequestMethod.GET, path, undefined, false);
  }

  static login(
    username: string,
    password: string,
    captchaId: string,
    captchaCode: string
  ): Promise<LoginData> {
    const body: LoginRequest = {
      username: username,
      password: password,
      captchaId: captchaId,
      captchaCode: captchaCode
    };
    return ApiClient.request<LoginData>(http.RequestMethod.POST, '/api/auth/login', body, false);
  }

  static logout(): Promise<AckData> {
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/auth/logout');
  }

  static getMe(): Promise<MeData> {
    return ApiClient.request<MeData>(http.RequestMethod.GET, '/api/me', undefined, true, true);
  }

  static getOverview(): Promise<OverviewData> {
    return ApiClient.request<OverviewData>(http.RequestMethod.GET, '/api/overview', undefined, true, true);
  }

  static getSubjects(): Promise<SubjectsData> {
    return ApiClient.request<SubjectsData>(http.RequestMethod.GET, '/api/subjects', undefined, true, true);
  }

  /**
   * 列表查询。subjectId 是**可选**收窄条件，不传即返回服务端算出的
   * 全部可访问主体条目（含家庭授权），切勿硬传第一个主体。
   */
  static getItems(params: ItemQuery): Promise<ItemsData> {
    let qs: string = '?category=' + encodeURIComponent(params.category.toString());
    const subjectId: string = params.subjectId ?? '';
    if (subjectId.length > 0) {
      qs = qs + '&subjectId=' + encodeURIComponent(subjectId);
    }
    const page: number = params.page ?? 1;
    const size: number = params.size ?? 50;
    qs = qs + '&page=' + page.toString() + '&size=' + size.toString();
    return ApiClient.request<ItemsData>(http.RequestMethod.GET, '/api/items' + qs, undefined, true, true);
  }

  static getItem(id: string): Promise<ArchiveItem> {
    return ApiClient.request<ItemDetailData>(http.RequestMethod.GET, '/api/items/' + id, undefined, true, true)
      .then((d: ItemDetailData) => {
        return d.item;
      });
  }

  /**
   * 全文检索。后端主搜索读的参数是 **keyword**（q 只属于 /api/search/suggest），
   * 旧版传 ?q= 导致过滤完全失效、恒返回全部条目前 20 条。
   * category=0 为不限；cursor 非空时取下一页（后端返回 nextCursor）。
   */
  static search(keyword: string, category: number = 0, cursor: string = ''): Promise<SearchData> {
    let qs: string = '?keyword=' + encodeURIComponent(keyword) + '&size=20';
    if (category > 0) {
      qs = qs + '&category=' + category.toString();
    }
    if (cursor.length > 0) {
      qs = qs + '&cursor=' + encodeURIComponent(cursor);
    }
    return ApiClient.request<SearchData>(
      http.RequestMethod.GET, '/api/search' + qs, undefined, true, true
    );
  }

  static getRecycleBin(): Promise<RecycleBinData> {
    return ApiClient.request<RecycleBinData>(
      http.RequestMethod.GET, '/api/items/recycle-bin', undefined, true, true
    );
  }

  static createItem(body: ItemWriteRequest): Promise<string> {
    return ApiClient.request<CreateItemData>(http.RequestMethod.POST, '/api/items', body)
      .then((d: CreateItemData) => {
        return d.id;
      });
  }

  static updateItem(id: string, body: ItemUpdateRequest): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.PUT, '/api/items/' + id, body)
      .then(() => {});
  }

  static deleteItem(id: string, version: number): Promise<void> {
    const body: VersionBody = { version: version };
    return ApiClient.request<AckData>(http.RequestMethod.DELETE, '/api/items/' + id, body)
      .then(() => {});
  }

  static restoreItem(id: string): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/items/' + id + '/restore')
      .then(() => {});
  }

  /** 状态流转：draft(0) → active(1) → archived(2)，带乐观锁版本。 */
  static setItemStatus(id: string, body: StatusBody): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/items/' + id + '/status', body)
      .then(() => {});
  }

  /** 克隆为新草稿，返回新条目 ID。 */
  static cloneItem(id: string): Promise<string> {
    const body: EmptyBody = {};
    return ApiClient.request<CloneData>(http.RequestMethod.POST, '/api/items/' + id + '/clone', body)
      .then((d: CloneData) => {
        return d.id;
      });
  }

  static getNotifications(onlyUnread: boolean, page: number = 1): Promise<NotificationsData> {
    let qs: string = '?page=' + page.toString() + '&size=20';
    if (onlyUnread) {
      qs = qs + '&unread=true';
    }
    return ApiClient.request<NotificationsData>(
      http.RequestMethod.GET, '/api/notifications' + qs, undefined, true, true
    );
  }

  static markNotificationRead(id: string): Promise<void> {
    const body: EmptyBody = {};
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/notifications/' + id + '/read', body)
      .then(() => {});
  }

  static markAllNotificationsRead(): Promise<void> {
    const body: EmptyBody = {};
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/notifications/read-all', body)
      .then(() => {});
  }

  static changePassword(body: ChangePasswordBody): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/me/password', body)
      .then(() => {});
  }

  // ================= 主体管理（subjects.cj）=================

  static createSubject(body: SubjectWriteRequest): Promise<string> {
    return ApiClient.request<CreateSubjectData>(http.RequestMethod.POST, '/api/subjects', body)
      .then((d: CreateSubjectData) => d.id);
  }

  static updateSubject(id: string, body: SubjectUpdateRequest): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.PUT, '/api/subjects/' + id, body)
      .then(() => {});
  }

  /** 返回软删后残留的条目数（前端可提示去回收站找回）。 */
  static deleteSubject(id: string): Promise<number> {
    return ApiClient.request<DeleteSubjectData>(http.RequestMethod.DELETE, '/api/subjects/' + id)
      .then((d: DeleteSubjectData) => d.orphanItems);
  }

  // ================= 标签（management.cj / fielddefs.cj）=================

  /** tree=1 返回结构化的 id/name/usageCount 等字段，避免 DB 列名差异。 */
  static getTags(): Promise<TagsData> {
    return ApiClient.request<TagsData>(http.RequestMethod.GET, '/api/tags?tree=1', undefined, true, true);
  }

  static getTagStats(): Promise<TagStatsData> {
    return ApiClient.request<TagStatsData>(http.RequestMethod.GET, '/api/tags/stats', undefined, true, true);
  }

  static createTag(body: CreateTagRequest): Promise<number> {
    return ApiClient.request<CreateTagData>(http.RequestMethod.POST, '/api/tags', body)
      .then((d: CreateTagData) => d.id);
  }

  static deleteTag(id: string): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.DELETE, '/api/tags/' + id)
      .then(() => {});
  }

  static attachTag(itemId: string, tagId: number): Promise<void> {
    const body: TagIdBody = { tagId: tagId };
    return ApiClient.request<AckData>(http.RequestMethod.POST, '/api/items/' + itemId + '/tags', body)
      .then(() => {});
  }

  static detachTag(itemId: string, tagId: string): Promise<void> {
    return ApiClient.request<AckData>(
      http.RequestMethod.DELETE, '/api/items/' + itemId + '/tags/' + tagId
    ).then(() => {});
  }

  static getFieldDefs(category: number = 0): Promise<FieldDefsData> {
    return ApiClient.request<FieldDefsData>(
      http.RequestMethod.GET, '/api/field-defs?category=' + category.toString(), undefined, true, true
    );
  }

  static getItemFields(id: string): Promise<ItemFieldsData> {
    return ApiClient.request<ItemFieldsData>(
      http.RequestMethod.GET, '/api/items/' + id + '/fields', undefined, true, true
    );
  }

  // ================= 共享链接（share.cj）=================

  static getShareLinks(page: number = 1): Promise<ShareLinksData> {
    return ApiClient.request<ShareLinksData>(
      http.RequestMethod.GET, '/api/share-links?page=' + page.toString() + '&size=20', undefined, true, true
    );
  }

  static createShareLink(body: CreateShareLinkRequest): Promise<CreateShareLinkData> {
    return ApiClient.request<CreateShareLinkData>(http.RequestMethod.POST, '/api/share-links', body);
  }

  static revokeShareLink(id: string): Promise<void> {
    return ApiClient.request<AckData>(http.RequestMethod.DELETE, '/api/share-links/' + id)
      .then(() => {});
  }

  // ================= 条目模板（itemtemplates.cj）=================

  static getTemplates(): Promise<TemplatesData> {
    return ApiClient.request<TemplatesData>(
      http.RequestMethod.GET, '/api/item-templates', undefined, true, true
    );
  }

  static applyTemplate(id: string, body: ApplyTemplateRequest): Promise<ApplyTemplateData> {
    return ApiClient.request<ApplyTemplateData>(
      http.RequestMethod.POST, '/api/item-templates/' + id + '/apply', body
    );
  }

  // ================= 历史版本（items.cj）=================

  static getItemVersions(id: string): Promise<VersionsData> {
    return ApiClient.request<VersionsData>(
      http.RequestMethod.GET, '/api/items/' + id + '/versions', undefined, true, true
    );
  }

  static restoreItemVersion(id: string, vid: string): Promise<number> {
    const body: EmptyBody = {};
    return ApiClient.request<RestoreVersionData>(
      http.RequestMethod.POST, '/api/items/' + id + '/versions/' + vid + '/restore', body
    ).then((d: RestoreVersionData) => d.fromVersion);
  }

  // ================= 系统信息（公开只读端点）=================
  // system.cj / admin.cj 里的 /api/admin/* 读端点均需 system:admin / cfg:read，
  // 属高权限；这里改用无需高权限的公开只读端点，口径一致且不越权。

  static getHealth(): Promise<HealthData> {
    return ApiClient.request<HealthData>(http.RequestMethod.GET, '/api/health', undefined, false);
  }

  static getSetupStatus(): Promise<SetupStatusData> {
    return ApiClient.request<SetupStatusData>(http.RequestMethod.GET, '/api/setup/status', undefined, false);
  }

  static getBranding(): Promise<BrandingData> {
    return ApiClient.request<BrandingData>(http.RequestMethod.GET, '/api/branding', undefined, false);
  }

  static getLocales(): Promise<LocalesData> {
    return ApiClient.request<LocalesData>(http.RequestMethod.GET, '/api/i18n/locales', undefined, false);
  }

  // ================= 家庭组（family.cj）=================

  static getFamilyGroups(): Promise<FamilyGroupsData> {
    return ApiClient.request<FamilyGroupsData>(
      http.RequestMethod.GET, '/api/family/groups', undefined, true, true
    );
  }

  static getFamilyMembers(groupId: string): Promise<FamilyMembersData> {
    return ApiClient.request<FamilyMembersData>(
      http.RequestMethod.GET, '/api/family/groups/' + groupId + '/members', undefined, true, true
    );
  }

  static getSharedItems(page: number = 1): Promise<SharedItemsData> {
    return ApiClient.request<SharedItemsData>(
      http.RequestMethod.GET, '/api/family/shared-items?page=' + page.toString() + '&size=20', undefined, true, true
    );
  }

  /** GET /api/family/shared-items/:id 直接返回条目对象（非 {item} 包装）。 */
  static getSharedItem(id: string): Promise<ArchiveItem> {
    return ApiClient.request<ArchiveItem>(
      http.RequestMethod.GET, '/api/family/shared-items/' + id, undefined, true, true
    );
  }

  // ================= 附件（attachments.cj）=================

  static getAttachments(itemId: string): Promise<AttachmentsData> {
    return ApiClient.request<AttachmentsData>(
      http.RequestMethod.GET, '/api/attachments?itemId=' + encodeURIComponent(itemId), undefined, true, true
    );
  }

  static getAttachmentDownload(id: number): Promise<DownloadData> {
    return ApiClient.request<DownloadData>(
      http.RequestMethod.GET, '/api/attachments/' + id.toString() + '/download'
    );
  }

  static batchTagAttachments(body: BatchTagRequest): Promise<BatchTagData> {
    return ApiClient.request<BatchTagData>(http.RequestMethod.POST, '/api/attachments/batch/tag', body);
  }

  /**
   * 单次上传：元数据全在 query，正文是文件原始字节（application/octet-stream），
   * 与 Web 端 AttachmentPanel.vue 一致；不走 request() 的 JSON.stringify。
   */
  static async uploadAttachment(p: UploadAttachmentParams): Promise<UploadData> {
    const req = http.createHttp();
    const headers: Record<string, string> = { 'Content-Type': 'application/octet-stream' };
    const t: string = AuthStore.token();
    if (t.length > 0) {
      headers['Authorization'] = 'Bearer ' + t;
    }
    let qs: string = '?fileName=' + encodeURIComponent(p.fileName)
      + '&title=' + encodeURIComponent(p.title)
      + '&category=' + p.category.toString();
    if (p.itemId.length > 0) {
      qs = qs + '&itemId=' + encodeURIComponent(p.itemId);
    }
    if (p.subjectId.length > 0) {
      qs = qs + '&subjectId=' + encodeURIComponent(p.subjectId);
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: p.data,
      connectTimeout: 20000,
      readTimeout: 20000
    };
    try {
      const resp = await req.request(AuthStore.getBaseUrl() + '/api/attachments' + qs, options);
      const raw: string = resp.result as string;
      const code: number = resp.responseCode;
      if (code < 200 || code >= 300) {
        throw new Error(ApiClient.errorMessage(raw, code));
      }
      const env = JSON.parse(raw) as ApiEnvelope;
      return env.data as UploadData;
    } catch (e) {
      throw new Error((e as Error).message);
    } finally {
      req.destroy();
    }
  }

  // ================= 导入 / 导出任务（import.cj / export.cj）=================

  static createExportTask(body: CreateExportRequest): Promise<CreateExportData> {
    return ApiClient.request<CreateExportData>(http.RequestMethod.POST, '/api/export/tasks', body);
  }

  /** 不传 type，返回本人全部任务（导入 + 导出共用一张任务表）。 */
  static getTasks(page: number = 1): Promise<TasksData> {
    return ApiClient.request<TasksData>(
      http.RequestMethod.GET, '/api/export/tasks?page=' + page.toString() + '&size=20', undefined, true, true
    );
  }

  static getTask(no: string): Promise<TaskRecord> {
    return ApiClient.request<TaskRecord>(
      http.RequestMethod.GET, '/api/export/tasks/' + encodeURIComponent(no), undefined, true, false
    );
  }

  static cancelTask(no: string): Promise<void> {
    const body: EmptyBody = {};
    return ApiClient.request<AckData>(
      http.RequestMethod.POST, '/api/export/tasks/' + encodeURIComponent(no) + '/cancel', body
    ).then(() => {});
  }

  static createImportTask(body: CreateImportRequest): Promise<CreateImportData> {
    return ApiClient.request<CreateImportData>(http.RequestMethod.POST, '/api/import/tasks', body);
  }

  /**
   * 下载导出产物。该端点直接返回 CSV / JSON 正文（ApiResponse(200, 正文, 头)），
   * 不带 {code,message,data} 信封，所以不能用 request() 解包。
   */
  static async downloadExport(taskNo: string): Promise<string> {
    const req = http.createHttp();
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const t: string = AuthStore.token();
    if (t.length > 0) {
      headers['Authorization'] = 'Bearer ' + t;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 10000
    };
    try {
      const resp = await req.request(
        AuthStore.getBaseUrl() + '/api/export/tasks/' + encodeURIComponent(taskNo) + '/download',
        options
      );
      const raw: string = resp.result as string;
      const code: number = resp.responseCode;
      if (code < 200 || code >= 300) {
        throw new Error(ApiClient.errorMessage(raw, code));
      }
      return raw;
    } catch (e) {
      throw new Error((e as Error).message);
    } finally {
      req.destroy();
    }
  }

  /** 从错误响应里尽量取出 message，失败时回退到 HTTP 状态码。 */
  private static errorMessage(raw: string, code: number): string {
    let msg: string = t('api.reqFail', i18nVars([['code', code.toString()]]));
    try {
      const env = JSON.parse(raw) as ApiEnvelope;
      if (typeof env.message === 'string' && env.message.length > 0) {
        msg = env.message;
      }
    } catch (e) {}
    return msg;
  }
}
