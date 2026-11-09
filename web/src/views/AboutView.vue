<script setup lang="ts">
/**
 * 关于（独立页面）
 *   —— 项目简介、版本信息、作者信息与外链入口。
 * 所有内容与地址集中在 src/config/about.ts，本页只负责呈现；
 * 未提供的字段与地址按该文件的占位规则渲染，不产生死链。
 * 版式沿用全站组件层（.card / .kv / .btn-ghost）与 Apple 设计令牌。
 */
import { computed } from 'vue'
import { RouterLink } from 'vue-router'
import { t } from '../i18n'
import { aboutConfig, ABOUT_PLACEHOLDER } from '../config/about'

const cfg = aboutConfig

/** 空字段统一显示占位文案，填入真实值后自动切换 */
function valueOrPlaceholder(v: string): string {
  return v && v.trim() ? v : ABOUT_PLACEHOLDER.text
}

/** 外链 aria-label：静态结构走 t()，动态字段用 vars 注入，避免 en/fr 残留中文括号 */
function linkAriaLabel(label: string, description: string): string {
  const newWindow = t('about.opensNewWindow', '在新窗口打开')
  return t('about.linkAria', `${label} · ${description}（${newWindow}）`, {
    label,
    description,
    newWindow,
  })
}

/** 仍有未提供的内容时，才显示「如何替换」的说明 */
const hasPending = computed(
  () =>
    !cfg.author.name.trim() ||
    !cfg.author.email.trim() ||
    !cfg.releaseDate.trim() ||
    cfg.links.some((l) => !l.href.trim()),
)
</script>

<template>
  <section class="about">
    <header class="about__hero">
      <div class="about__mark" aria-hidden="true">A</div>
      <p class="about__eyebrow">{{ t('about.eyebrow', '关于') }}</p>
      <h1 class="page-title">{{ cfg.productName }}</h1>
      <p class="about__tagline">{{ cfg.tagline }}</p>
      <p class="about__version">v{{ cfg.version }} · {{ cfg.license }}</p>
    </header>

    <!-- 项目简介 -->
    <div class="card about__card">
      <h2 class="section-title">{{ t('about.introTitle', '项目简介') }}</h2>
      <p v-for="(para, i) in cfg.summary" :key="i" class="about__para">{{ para }}</p>
      <ul class="about__stack" :aria-label="t('about.stack', '技术栈')">
        <li v-for="s in cfg.stack" :key="s" class="about__stack-item">{{ s }}</li>
      </ul>
    </div>

    <!-- 版本信息 -->
    <div class="card about__card">
      <h2 class="section-title">{{ t('about.versionTitle', '版本信息') }}</h2>
      <dl class="kv">
        <dt>{{ t('about.version', '版本号') }}</dt>
        <dd>v{{ cfg.version }}</dd>
        <dt>{{ t('about.releaseDate', '发布日期') }}</dt>
        <dd>{{ valueOrPlaceholder(cfg.releaseDate) }}</dd>
        <dt>{{ t('about.license', '许可证') }}</dt>
        <dd>{{ cfg.license }}</dd>
        <dt>{{ t('about.stack', '技术栈') }}</dt>
        <dd>{{ cfg.stack.join(' · ') }}</dd>
      </dl>
    </div>

    <!-- 作者信息 -->
    <div class="card about__card">
      <h2 class="section-title">{{ t('about.authorTitle', '作者信息') }}</h2>
      <dl class="kv">
        <dt>{{ t('about.authorName', '作者') }}</dt>
        <dd>{{ valueOrPlaceholder(cfg.author.name) }}</dd>
        <dt>{{ t('about.email', '联系邮箱') }}</dt>
        <dd>{{ valueOrPlaceholder(cfg.author.email) }}</dd>
      </dl>
    </div>

    <!-- 相关链接：已配置则可在新窗口打开，未配置则显示占位项 -->
    <div class="card about__card">
      <h2 class="section-title">{{ t('about.linksTitle', '相关链接') }}</h2>
      <ul class="about__links">
        <li v-for="link in cfg.links" :key="link.label">
          <a
            v-if="link.href.trim()"
            class="about__link"
            :href="link.href"
            target="_blank"
            rel="noopener noreferrer"
            :aria-label="linkAriaLabel(link.label, link.description)"
          >
            <span class="about__link-text">
              <span class="about__link-label">{{ link.label }}</span>
              <span class="about__link-desc">{{ link.description }}</span>
            </span>
            <svg class="about__link-arrow" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="m9 18 6-6-6-6" />
            </svg>
          </a>
          <div v-else class="about__link about__link--pending" :aria-label="`${link.label} · ${ABOUT_PLACEHOLDER.link}`">
            <span class="about__link-text">
              <span class="about__link-label">{{ link.label }}</span>
              <span class="about__link-desc">{{ link.description }}</span>
            </span>
            <span class="about__tag">{{ ABOUT_PLACEHOLDER.link }}</span>
          </div>
        </li>
      </ul>
      <p v-if="hasPending" class="hint about__hint">
        {{ t('about.configHint', '未配置的地址显示「待配置」，留空的字段显示「待补充」；在配置中填写后自动生效。') }}
      </p>
    </div>

    <RouterLink class="btn-ghost about__back" to="/overview">
      {{ t('about.backHome', '返回概览') }}
    </RouterLink>
  </section>
</template>

<style scoped>
.about {
  max-width: 820px;
}

/* ---- Hero：纯排版，无渐变、无发光 ---- */
.about__hero {
  margin-bottom: var(--sp-6);
}
.about__mark {
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: 13px;
  background: var(--accent);
  color: #fff;
  font-size: 22px;
  font-weight: 700;
  letter-spacing: 0.02em;
}
.about__eyebrow {
  margin: var(--sp-4) 0 var(--sp-2);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--text-muted);
}
.page-title {
  margin: 0;
  font-size: var(--font-size-xl);
  letter-spacing: var(--tracking-heading);
}
.about__tagline {
  margin: var(--sp-2) 0 0;
  font-size: var(--font-size-lg);
  color: var(--text-secondary);
}
.about__version {
  margin: var(--sp-3) 0 0;
  font-size: var(--font-size-sm);
  color: var(--text-muted);
  font-variant-numeric: tabular-nums;
}

/* ---- 卡片 ---- */
.about__card {
  margin-bottom: var(--sp-4);
}
.section-title {
  margin: 0 0 var(--sp-4);
  font-size: var(--font-size-lg);
  font-weight: 600;
}
.about__para {
  margin: 0 0 var(--sp-3);
  color: var(--text-secondary);
  line-height: var(--leading-body);
}
.about__para:last-of-type {
  margin-bottom: 0;
}
.about__stack {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-2);
  margin: var(--sp-4) 0 0;
  padding: 0;
  list-style: none;
}
.about__stack-item {
  padding: 4px 12px;
  border-radius: var(--g3-pill);
  background: var(--bg-inset);
  color: var(--text-secondary);
  font-size: var(--font-size-sm);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.about__hint {
  margin: var(--sp-4) 0 0;
}

/* ---- 外链：全宽圆角卡片 + 文字 + 右箭头 ---- */
.about__links {
  display: grid;
  gap: var(--sp-2);
  margin: 0;
  padding: 0;
  list-style: none;
}
.about__link {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-3) var(--sp-4);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-md);
  background: var(--bg-inset);
  color: var(--text-primary);
  text-decoration: none;
  transition:
    background-color var(--spring-fast) var(--ease-out-soft),
    border-color var(--spring-fast) var(--ease-out-soft);
}
a.about__link:hover {
  background: var(--bg-hover);
  border-color: var(--accent);
}
a.about__link:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.about__link-text {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}
.about__link-label {
  font-weight: 600;
}
.about__link-desc {
  font-size: var(--font-size-sm);
  color: var(--text-muted);
}
.about__link-arrow {
  flex: none;
  width: 18px;
  height: 18px;
  color: var(--text-muted);
}
.about__link--pending {
  cursor: default;
  opacity: 0.72;
}
.about__tag {
  flex: none;
  padding: 3px 10px;
  border-radius: var(--g3-pill);
  background: var(--bg-hover);
  color: var(--text-muted);
  font-size: 12px;
}

.about__back {
  display: inline-flex;
  margin-top: var(--sp-2);
}
</style>
