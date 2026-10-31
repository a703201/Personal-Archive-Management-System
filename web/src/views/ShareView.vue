<script setup lang="ts">
/**
 * 共享页（FR-ACL-012 · 公开只读）。
 *
 * 路由 `/share/:token` 标记 `meta.public`，未登录也可访问 ——
 * 这正是共享链接的意义：接收方不需要有账号。
 *
 * 安全约定（与后端 ShareRoutes 对齐）：
 *   ① 密码保护时，**首屏不含任何条目信息**，只渲染密码框；
 *   ② 不存在 / 已撤销 / 已过期 一律同一句「链接不存在或已失效」，
 *      不区分原因（后端也是统一 404），避免被用来探测 token 是否存在；
 *   ③ 密码错误次数由后端累计并落库，本页只显示后端返回的剩余次数。
 */
import { onMounted, ref } from 'vue'
import { t } from '../i18n'
import { useRoute } from 'vue-router'
import { api, ApiError } from '../api/client'
import { categoryName, formatTime as fmtTime, sensitivityName, statusName } from '../composables/useCatalog'

const route = useRoute()
const token = String(route.params.token ?? '')

interface SharedItem {
  title: string
  category: number
  status: number
  sensitivity: number
  issuer: string
  issuedDate: string
  expiresAt: string
  remark: string
  linkExpiresAt: number
  viewCount: number
}

const item = ref<SharedItem | null>(null)
const needPassword = ref(false)
const password = ref('')
const submitting = ref(false)
const loading = ref(true)
/** 致命错误：链接不可用（统一话术） */
const dead = ref(false)
const errorText = ref('')

/** 后端三种失败形态：404 = 链接不可用；403 = 密码问题；其它 = 通用错误 */
function handleError(e: unknown): void {
  const err = e as ApiError
  if (err.status === 404) {
    dead.value = true
    errorText.value = '链接不存在或已失效'
    return
  }
  errorText.value = err.message || '加载失败'
}

async function load(): Promise<void> {
  loading.value = true
  try {
    const r = await api<SharedItem & { needPassword?: boolean }>(`/share/${token}`, {
      auth: false,
    })
    if (r && (r as { needPassword?: boolean }).needPassword) {
      needPassword.value = true
    } else {
      item.value = r as SharedItem
    }
  } catch (e) {
    handleError(e)
  } finally {
    loading.value = false
  }
}

async function submit(): Promise<void> {
  if (!password.value) {
    errorText.value = '请输入访问密码'
    return
  }
  submitting.value = true
  errorText.value = ''
  try {
    const r = await api<SharedItem>(`/share/${token}`, {
      method: 'POST',
      body: { password: password.value },
      auth: false,
    })
    item.value = r
    needPassword.value = false
    password.value = ''
  } catch (e) {
    const err = e as ApiError
    if (err.status === 404) {
      dead.value = true
      errorText.value = '链接不存在或已失效'
    } else {
      errorText.value = err.message || '密码不正确'
    }
  } finally {
    submitting.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="share-page">
    <header class="share-page__head">
      <span class="share-page__brand">AMS</span>
      <span class="share-page__tag">{{ t('ShareView.8d281f', '共享只读') }}</span>
    </header>

    <main class="share-card">
      <p v-if="loading" class="share-hint">{{ t('ShareView.300ee3', '加载中…') }}</p>

      <!-- 链接不可用：不区分原因 -->
      <div v-else-if="dead" class="share-dead">
        <p class="share-dead__title">{{ errorText }}</p>
        <p class="share-dead__desc">
          该链接可能已过期、已被撤销，或分享的档案已被删除。请联系分享者重新生成。
        </p>
      </div>

      <!-- 需要密码 -->
      <form v-else-if="needPassword" class="share-pwd" @submit.prevent="submit">
        <h1 class="share-pwd__title">{{ t('ShareView.368498', '该链接需要访问密码') }}</h1>
        <p class="share-pwd__desc">{{ t('ShareView.fded6f', '请输入分享者提供的密码。多次输错会使链接失效。') }}</p>
        <input
          v-model="password"
          class="field-control"
          type="password"
          :placeholder="t('ShareView.c737b7', '访问密码')"
          autocomplete="off"
          autofocus
        />
        <p v-if="errorText" class="share-error">{{ errorText }}</p>
        <button class="btn-primary share-pwd__btn" type="submit" :disabled="submitting">
          {{ submitting ? '校验中…' : '查看档案' }}
        </button>
      </form>

      <!-- 内容 -->
      <article v-else-if="item" class="share-item">
        <h1 class="share-item__title">{{ item.title }}</h1>
        <div class="share-item__tags">
          <span class="chip">{{ categoryName(item.category) }}</span>
          <span class="chip">{{ statusName(item.status) }}</span>
          <span class="chip" :class="`chip--sens${item.sensitivity}`">
            {{ sensitivityName(item.sensitivity) }}
          </span>
        </div>

        <dl class="share-kv">
          <template v-if="item.issuer">
            <dt>{{ t('ShareView.8eb731', '签发机构') }}</dt>
            <dd>{{ item.issuer }}</dd>
          </template>
          <template v-if="item.issuedDate">
            <dt>{{ t('ShareView.0b8bcd', '签发日期') }}</dt>
            <dd>{{ item.issuedDate }}</dd>
          </template>
          <template v-if="item.expiresAt">
            <dt>{{ t('ShareView.37eb47', '有效期至') }}</dt>
            <dd>{{ item.expiresAt }}</dd>
          </template>
          <template v-if="item.remark">
            <dt>{{ t('ShareView.e03614', '备注') }}</dt>
            <dd class="share-kv__multi">{{ item.remark }}</dd>
          </template>
        </dl>

        <p v-if="item.sensitivity >= 3" class="share-mask-note">
          该档案为高敏级别，共享页不展示签发机构与备注。
        </p>

        <footer class="share-item__foot">
          <span>{{ t('ShareView.f23884', '链接到期：') }}{{ fmtTime(item.linkExpiresAt) }}</span>
          <span>{{ t('ShareView.849b13', '已被查看') }} {{ item.viewCount }} {{ t('ShareView.5e5b81', '次') }}</span>
        </footer>
      </article>

      <p v-else-if="errorText" class="share-error">{{ errorText }}</p>
    </main>

    <p class="share-page__foot">{{ t('ShareView.f562ce', '本页由 AMS 个人档案管理系统生成 · 仅展示只读信息') }}</p>
  </div>
</template>

<style scoped>
.share-page {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: var(--sp-6) var(--sp-4);
  gap: var(--sp-4);
  background: var(--bg-app, var(--bg-base, #f5f5f7));
}

.share-page__head {
  width: 100%;
  max-width: 560px;
  display: flex;
  align-items: center;
  gap: var(--sp-2);
}
.share-page__brand {
  font-weight: 700;
  font-size: var(--font-size-lg);
  color: var(--accent);
  letter-spacing: 0.02em;
}
.share-page__tag {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  color: var(--text-muted);
}

.share-card {
  width: 100%;
  max-width: 560px;
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  padding: var(--sp-5);
  box-shadow: var(--shadow-card, 0 1px 2px rgb(0 0 0 / 0.04));
}

.share-hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin: 0;
}
.share-error {
  color: var(--danger);
  font-size: var(--font-size-sm);
  margin: 0;
}

/* ---- 密码 ---- */
.share-pwd {
  display: grid;
  gap: var(--sp-3);
}
.share-pwd__title {
  font-size: var(--font-size-lg);
  margin: 0;
}
.share-pwd__desc {
  margin: 0;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  line-height: 1.6;
}
.share-pwd__btn {
  justify-self: start;
}

/* ---- 失效 ---- */
.share-dead {
  display: grid;
  gap: var(--sp-2);
}
.share-dead__title {
  margin: 0;
  font-size: var(--font-size-lg);
  font-weight: 600;
}
.share-dead__desc {
  margin: 0;
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  line-height: 1.6;
}

/* ---- 内容 ---- */
.share-item__title {
  margin: 0 0 var(--sp-2);
  font-size: var(--font-size-xl);
  line-height: 1.3;
}
.share-item__tags {
  display: flex;
  gap: var(--sp-2);
  flex-wrap: wrap;
  margin-bottom: var(--sp-4);
}
.chip {
  font-size: 12px;
  padding: 2px 10px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  color: var(--text-secondary);
}
.chip--sens2 {
  background: color-mix(in srgb, var(--warning) 16%, transparent);
  color: var(--warning);
}
.chip--sens3 {
  background: color-mix(in srgb, var(--danger) 16%, transparent);
  color: var(--danger);
}

.share-kv {
  display: grid;
  grid-template-columns: 96px 1fr;
  gap: var(--sp-2) var(--sp-3);
  margin: 0;
}
.share-kv dt {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.share-kv dd {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-primary);
  word-break: break-word;
}
.share-kv__multi {
  white-space: pre-wrap;
  line-height: 1.6;
}

.share-mask-note {
  margin: var(--sp-4) 0 0;
  padding: var(--sp-2) var(--sp-3);
  font-size: 12px;
  color: var(--text-muted);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
}

.share-item__foot {
  display: flex;
  justify-content: space-between;
  gap: var(--sp-2);
  flex-wrap: wrap;
  margin-top: var(--sp-4);
  padding-top: var(--sp-3);
  border-top: 1px solid var(--border-subtle);
  font-size: 12px;
  color: var(--text-muted);
}

.share-page__foot {
  margin: 0;
  font-size: 12px;
  color: var(--text-muted);
  text-align: center;
}

@media (max-width: 639px) {
  .share-card {
    padding: var(--sp-4);
  }
  .share-kv {
    grid-template-columns: 1fr;
    gap: 2px var(--sp-3);
  }
  .share-kv dt {
    margin-top: var(--sp-2);
  }
}
</style>
