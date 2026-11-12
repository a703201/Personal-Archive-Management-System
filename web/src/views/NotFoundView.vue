<script setup lang="ts">
import { RouterLink } from 'vue-router'
import { t } from '../i18n'
</script>

<template>
  <main class="state-page" role="main">
    <div class="state-page__card">
      <p class="state-page__code">404</p>
      <h1 class="state-page__title">{{ t('route.notFoundTitle', '页面不存在') }}</h1>
      <p class="state-page__desc">
        {{ t('route.notFoundDesc', '你访问的地址不存在，或者内容已被移动。') }}
      </p>
      <RouterLink class="state-page__action" to="/overview">
        {{ t('route.notFoundBack', '返回概览') }}
      </RouterLink>
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
.state-page__code {
  margin: 0 0 12px;
  font-size: 56px;
  font-weight: 600;
  letter-spacing: -0.04em;
  color: var(--accent, #0071e3);
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
  border-radius: 999px;
  background: var(--accent, #0071e3);
  color: #fff;
  font-size: 15px;
  font-weight: 600;
  text-decoration: none;
}
.state-page__action:hover { opacity: 0.88; }
</style>
