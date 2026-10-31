<script setup lang="ts">
/**
 * 首次使用引导（FR-UX-007）。
 *
 * 三步引导 + 分类体系说明，仅在首次访问时展示（localStorage 记忆，
 * 用户也可在「设置」外主动清除以重看）。纯前端、零后端依赖。
 *
 * ⚠️ 展示条件必须同时满足「未看过 + 已登录 + 非公开页」：
 *    本组件挂在 App 外壳之外，原先只看 localStorage，于是登录页、
 *    找回口令页、以及共享页（`/share/:token`，接收方根本没有账号）
 *    都会被这层引导蒙住 —— 共享页尤其致命：内容被盖住，接收方还以为
 *    链接坏了。公开页的访客不是「本系统的新用户」，不该给他看产品介绍。
 */
import { ref, computed } from 'vue'
import { t } from '../i18n'
import { useRoute } from 'vue-router'
import { getToken } from '../api/client'

const STORAGE_KEY = 'ams.onboarded'

const route = useRoute()
const dismissed = ref(localStorage.getItem(STORAGE_KEY) === '1')
const step = ref(0)

/** 是否真的该展示引导 */
const visible = computed(
  () => !dismissed.value && !route.meta.public && getToken() !== '',
)

const STEPS = [
  {
    icon: '🗂️',
    title: t('componentsOnboarding.05ad8e', '欢迎使用 AMS 个人档案管理系统'),
    body: t('componentsOnboarding.fdc227', '这里帮你把身份证、学历、证书、健康、资产等重要证件与资料，按分类安全归档、加密存储、随时检索。所有敏感字段默认脱敏，密钥掌握在你手中。'),
  },
  {
    icon: '🔐',
    title: t('componentsOnboarding.2a7b4d', '三类敏感度，分级守护'),
    body: t('componentsOnboarding.dbf814', '普通（绿）：基本信息、教育、职业等；敏感（橙）：证件、联系方式、家庭关系；高敏（红）：健康、资产。高敏数据默认仅你能看，导出需额外确认。'),
  },
  {
    icon: '⚡',
    title: t('componentsOnboarding.94e3d7', '三步开始管理'),
    body: t('componentsOnboarding.720e2d', '① 选择或新建一个「档案主体」（如你自己、配偶、子女）；② 按分类新建档案并上传附件；③ 用顶部搜索或 Cmd/Ctrl+K 快速定位。到期证件会自动提醒续期。'),
  },
]

const current = computed(() => STEPS[step.value])
const isLast = computed(() => step.value === STEPS.length - 1)

function next(): void {
  if (isLast.value) {
    finish()
  } else {
    step.value = step.value + 1
  }
}

function finish(): void {
  localStorage.setItem(STORAGE_KEY, '1')
  dismissed.value = true
}
</script>

<template>
  <div
    v-if="visible"
    class="onboard"
    role="dialog"
    aria-modal="true"
    aria-labelledby="onboard-title"
  >
    <div class="onboard__card">
      <div class="onboard__step">
        <div class="onboard__icon" aria-hidden="true">{{ current.icon }}</div>
        <h2 id="onboard-title" class="onboard__title">{{ current.title }}</h2>
        <p class="onboard__body">{{ current.body }}</p>
      </div>

      <div class="onboard__dots" aria-hidden="true">
        <span
          v-for="(_, i) in STEPS"
          :key="i"
          class="onboard__dot"
          :class="{ 'onboard__dot--on': i === step }"
        />
      </div>

      <div class="onboard__actions">
        <button class="btn-ghost" type="button" @click="finish">{{ t('Onboarding.31a985', '跳过') }}</button>
        <button class="btn-primary" type="button" @click="next">
          {{ isLast ? '开始使用' : '下一步' }}
        </button>
      </div>
    </div>
  </div>
</template>
