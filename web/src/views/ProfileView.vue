<script setup lang="ts">
/**
 * 个人主页（FR-UX-001）。
 *
 * 数据来自 /api/me：账号、昵称、掩码后的联系方式、权限点。
 * 注意后端**不会**返回任何凭据字段（口令哈希 / KDF 参数），
 * 前端也没有任何途径拿到 —— 这是设计上的保证，不是"懒得展示"。
 */
import { ref, onMounted } from 'vue'
import { api } from '../api/client'

interface Me {
  id: number
  username: string
  nickname: string
  email: string
  phone: string
  status: number
  perms: string[]
}

const me = ref<Me | null>(null)
const loading = ref(true)
const error = ref('')

/** 权限点按域分组展示（域:动作:范围） */
const groupedPerms = ref<Record<string, string[]>>({})

function groupPerms(perms: string[]): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const p of perms) {
    const domain = p.split(':')[0] ?? 'other'
    ;(out[domain] ??= []).push(p)
  }
  return out
}

async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    me.value = await api<Me>('/me')
    groupedPerms.value = groupPerms(me.value.perms)
  } catch (e) {
    error.value = (e as Error).message
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <section>
    <h1 class="page-title">个人主页</h1>

    <p v-if="loading" class="hint">加载中…</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <template v-else-if="me">
      <div class="card profile">
        <div class="avatar">{{ (me.nickname || me.username).slice(0, 1) }}</div>
        <div class="profile__info">
          <div class="profile__name">{{ me.nickname || me.username }}</div>
          <div class="profile__sub">@{{ me.username }} · ID {{ me.id }}</div>
        </div>
      </div>

      <h2 class="section-title">联系方式</h2>
      <div class="card">
        <dl class="kv">
          <dt>邮箱</dt>
          <dd>{{ me.email || '—' }}</dd>
          <dt>手机号</dt>
          <dd>{{ me.phone || '—' }}</dd>
          <dt>账号状态</dt>
          <dd>{{ me.status === 1 ? '正常' : '已停用' }}</dd>
        </dl>
        <p class="hint">联系方式默认掩码展示，完整值需在各自业务场景中按权限查看。</p>
      </div>

      <h2 class="section-title">权限点（{{ me.perms.length }}）</h2>
      <div class="card">
        <div v-for="(list, domain) in groupedPerms" :key="domain" class="perm-group">
          <div class="perm-group__domain">{{ domain }}</div>
          <div class="perm-group__list">
            <code v-for="p in list" :key="p" class="perm-chip">{{ p }}</code>
          </div>
        </div>
      </div>
    </template>
  </section>
</template>

<style scoped>
.page-title {
  font-size: var(--font-size-xl);
  margin: 0 0 var(--sp-4);
}
.section-title {
  font-size: var(--font-size-lg);
  margin: var(--sp-5) 0 var(--sp-3);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint--error {
  color: var(--danger);
}

.profile {
  display: flex;
  align-items: center;
  gap: var(--sp-4);
}

.avatar {
  width: 56px;
  height: 56px;
  border-radius: 50%;
  background: var(--accent);
  color: var(--text-inverse);
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 22px;
  font-weight: 600;
  flex-shrink: 0;
}

.profile__name {
  font-size: var(--font-size-lg);
  font-weight: 600;
}
.profile__sub {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}

.kv {
  display: grid;
  grid-template-columns: 88px 1fr;
  gap: var(--sp-2) var(--sp-3);
  margin: 0 0 var(--sp-3);
  font-size: var(--font-size-md);
}
.kv dt {
  color: var(--text-secondary);
}
.kv dd {
  margin: 0;
}

.perm-group {
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border-subtle);
}
.perm-group:last-child {
  border-bottom: none;
}
.perm-group__domain {
  font-weight: 600;
  margin-bottom: var(--sp-2);
  font-size: var(--font-size-sm);
}
.perm-group__list {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
}

.perm-chip {
  font-size: 12px;
  padding: 2px var(--sp-2);
  background: var(--bg-hover);
  border: 1px solid var(--border-subtle);
  border-radius: var(--radius-sm);
  color: var(--text-secondary);
}

@media (max-width: 639px) {
  .kv {
    grid-template-columns: 72px 1fr;
  }
}
</style>
