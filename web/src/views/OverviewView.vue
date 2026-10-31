<script setup lang="ts">
/**
 * 概览（FR-UX-001 个人主页与概览）。
 *
 * 数据来自 /api/overview：总数、分类分布、最近更新、未读提醒。
 * 全部由**服务端按可访问主体**统计，前端不做任何越权拼接。
 */
import { ref, onMounted, computed } from 'vue'
import { t } from '../i18n'
import { api } from '../api/client'
import { categoryName, formatTime } from '../composables/useCatalog'

interface CategoryStat {
  category: number
  count: number
}

interface RecentItem {
  id: number
  category: number
  title: string
  updatedAt: number
}

interface Overview {
  total: number
  categories: CategoryStat[]
  recent: RecentItem[]
  unreadNotifications: number
}

const data = ref<Overview | null>(null)
const loading = ref(true)
const error = ref('')

/** 只展示有数据的分类，按数量倒序 */
const topCategories = computed<CategoryStat[]>(() => {
  if (!data.value) return []
  return data.value.categories
    .filter((c) => c.count > 0)
    .sort((a, b) => b.count - a.count)
    .slice(0, 8)
})

/** 分类中文名与时间格式化统一取自 `composables/useCatalog`
 *  —— 此前本页自带一份映射，已与 docs/06 §12.3 漂移
 *  （「基本信息」应为「个人基本信息」、「身份证明」应为「证件信息」、
 *   「工作经历」应为「职业经历」、「资格证书」应为「资质证书」）。 */


async function load(): Promise<void> {
  loading.value = true
  error.value = ''
  try {
    data.value = await api<Overview>('/overview')
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
    <h1 class="page-title">{{ t('OverviewView.506042', '概览') }}</h1>

    <p v-if="loading" class="hint">{{ t('OverviewView.300ee3', '加载中…') }}</p>
    <p v-else-if="error" class="hint hint--error">{{ error }}</p>

    <template v-else-if="data">
      <!-- 关键指标 -->
      <div class="grid">
        <div class="card stat">
          <div class="stat__label">{{ t('OverviewView.cf2efb', '档案总数') }}</div>
          <div class="stat__value">{{ data.total }}</div>
        </div>
        <div class="card stat">
          <div class="stat__label">{{ t('OverviewView.7ee3be', '未读提醒') }}</div>
          <div class="stat__value">{{ data.unreadNotifications }}</div>
        </div>
        <div class="card stat">
          <div class="stat__label">{{ t('OverviewView.d19b98', '有数据分类') }}</div>
          <div class="stat__value">{{ topCategories.length }}</div>
        </div>
        <div class="card stat">
          <div class="stat__label">{{ t('OverviewView.80920c', '最近更新') }}</div>
          <div class="stat__value stat__value--sm">
            {{ data.recent.length ? formatTime(data.recent[0].updatedAt) : '—' }}
          </div>
        </div>
      </div>

      <!-- 分类分布 -->
      <h2 class="section-title">{{ t('OverviewView.245475', '分类分布') }}</h2>
      <div class="card">
        <p v-if="topCategories.length === 0" class="hint">{{ t('OverviewView.2e545d', '还没有档案，先去创建一条吧。') }}</p>
        <ul v-else class="bars">
          <li v-for="c in topCategories" :key="c.category" class="bar">
            <span class="bar__name">{{ categoryName(c.category) }}</span>
            <span class="bar__track">
              <span
                class="bar__fill"
                :style="{ width: Math.max(3, Math.round((c.count / data.total) * 100)) + '%' }"
              />
            </span>
            <span class="bar__count">{{ c.count }}</span>
          </li>
        </ul>
      </div>

      <!-- 最近更新 -->
      <h2 class="section-title">{{ t('OverviewView.80920c', '最近更新') }}</h2>
      <div class="card">
        <p v-if="data.recent.length === 0" class="hint">{{ t('OverviewView.4952df', '暂无更新记录。') }}</p>
        <ul v-else class="recent">
          <li v-for="it in data.recent" :key="it.id" class="recent__row">
            <span class="recent__title">{{ it.title }}</span>
            <span class="recent__cat">{{ categoryName(it.category) }}</span>
            <span class="recent__time">{{ formatTime(it.updatedAt) }}</span>
          </li>
        </ul>
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

.stat__label {
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
  margin-bottom: var(--sp-2);
}
.stat__value {
  font-size: 28px;
  font-weight: 600;
}
.stat__value--sm {
  font-size: var(--font-size-md);
  font-weight: 500;
}

.bars,
.recent {
  list-style: none;
  margin: 0;
  padding: 0;
}

.bar {
  display: grid;
  grid-template-columns: 96px 1fr 40px;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-2) 0;
}
.bar__name {
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
}
.bar__track {
  background: var(--bg-hover);
  border-radius: 999px;
  height: 8px;
  overflow: hidden;
}
.bar__fill {
  display: block;
  height: 100%;
  background: var(--accent);
  border-radius: 999px;
}
.bar__count {
  text-align: right;
  font-variant-numeric: tabular-nums;
  font-size: var(--font-size-sm);
}

.recent__row {
  display: grid;
  grid-template-columns: 1fr 96px 140px;
  gap: var(--sp-3);
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border-subtle);
  font-size: var(--font-size-sm);
}
.recent__row:last-child {
  border-bottom: none;
}
.recent__cat,
.recent__time {
  color: var(--text-muted);
}

/* 移动端：把多列压成单列，避免横向挤压 */
@media (max-width: 639px) {
  .bar {
    grid-template-columns: 80px 1fr 32px;
  }
  .recent__row {
    grid-template-columns: 1fr;
    gap: var(--sp-1);
  }
  .recent__cat,
  .recent__time {
    font-size: 12px;
  }
}
</style>
