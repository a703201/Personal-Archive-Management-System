<script setup lang="ts">
import { t } from '../i18n'

function reload(): void {
  window.location.reload()
}
</script>

<template>
  <main class="state-page" role="main">
    <div class="state-page__card">
      <h1 class="state-page__title" role="alert">
        {{ t('route.loadFailedTitle', '页面加载失败') }}
      </h1>
      <p class="state-page__desc">
        {{ t('route.loadFailedDesc', '资源没有成功载入，通常是网络中断或版本更新导致的，刷新后重试即可。') }}
      </p>
      <button class="state-page__action" type="button" @click="reload">
        {{ t('route.loadFailedRetry', '刷新重试') }}
      </button>
    </div>
  </main>
</template>

<style scoped>
.state-page {
  min-height: 60vh;
  display: grid;
  place-items: center;
  padding: 48px 24px;
  background: var(--bg-app, #f5f5f7);
}
.state-page__card {
  width: 100%;
  max-width: 420px;
  padding: 40px 32px;
  border-radius: 18px;
  background: var(--bg-surface, #ffffff);
  text-align: center;
}
.state-page__title {
  margin: 0 0 12px;
  font-size: 24px;
  font-weight: 600;
  color: var(--text-primary, #1d1d1f);
}
.state-page__desc {
  margin: 0 0 28px;
  font-size: 15px;
  line-height: 1.6;
  color: var(--text-secondary, #6e6e73);
}
.state-page__action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-height: 44px;
  padding: 0 22px;
  border: 0;
  border-radius: 999px;
  background: var(--accent, #0071e3);
  color: #fff;
  font-size: 15px;
  font-weight: 600;
  cursor: pointer;
}
.state-page__action:hover { opacity: 0.88; }
</style>
