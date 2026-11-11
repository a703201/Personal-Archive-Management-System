import { http } from '@kit.NetworkKit';
import { AuthStore } from '../store/AuthStore';
import { Subject, ArchiveItem } from '../models/Models';
import { Fingerprint } from '../crypto/Fingerprint';

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

export class ApiClient {
  static AUTH_EXPIRED: string = '登录已过期，请重新登录';

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
        throw new Error(ApiClient.AUTH_EXPIRED);
      }
      if (code < 200 || code >= 300) {
        let msg: string = '请求失败（' + code + '）';
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
        try {
          AppStorage.setOrCreate(cacheKey, raw);
        } catch (e) {}
      }
      return env.data as T;
    } catch (e) {
      const msg: string = (e as Error).message;
      if (cacheable && msg !== ApiClient.AUTH_EXPIRED) {
        const cached: string | undefined = AppStorage.get<string>(cacheKey);
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
}
