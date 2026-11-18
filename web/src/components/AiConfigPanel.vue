<script setup lang="ts">
/**
 * AI 能力配置卡（docs/20 §6.3 / I2，仅 system:admin 可见）。
 *
 * provider / 模型 / 端点 / 密钥（脱敏）写 deployment.env；
 * 总开关 / 出境同意 / 分域开关写 cfg_settings。
 * 密钥显示 *** 表示"不修改"，留空同样不覆盖真实密钥。
 */
import { ref, computed, watch, onMounted } from 'vue'
import { api } from '../api/client'
import { t as tr } from '../i18n'
import { useToast } from '../composables/useToast'
import { useAiCapabilities } from '../composables/useAiCapabilities'

const toast = useToast()
const { refresh: refreshCaps } = useAiCapabilities()

interface AiConfig {
  provider: string
  baseUrl: string
  model: string
  apiKey: string
  apiKeySet: boolean
  enabled: boolean
  onlineAllowed: boolean
  vision: boolean
  summary: boolean
  query: boolean
  advice: boolean
}

const cfg = ref<AiConfig>({
  provider: 'ollama', baseUrl: '', model: '', apiKey: '', apiKeySet: false,
  enabled: false, onlineAllowed: false,
  vision: true, summary: true, query: true, advice: true,
})
const busy = ref(false)
const testing = ref(false)

// online=true 表示会将档案内容发出本机（含自定义端点，保守归为需出境同意）
const PROVIDERS = [
  { value: 'local', label: 'Local (built-in)', online: false },
  { value: 'ollama', label: 'Ollama', online: false },
  { value: 'lmstudio', label: 'LM Studio', online: false },
  { value: 'cherry', label: 'Cherry Studio (backend)', online: false },
  { value: 'siliconflow', label: 'SiliconFlow', online: true },
  { value: 'aliyun', label: 'Aliyun DashScope', online: true },
  { value: 'huawei', label: 'Huawei ModelArts', online: true },
  { value: 'deepseek', label: 'DeepSeek', online: true },
  { value: 'openai', label: 'OpenAI', online: true },
  { value: 'custom', label: 'Custom (OpenAI-compatible)', online: true },
]

const isOnlineProvider = (v: string): boolean =>
  PROVIDERS.find((p) => p.value === v)?.online === true

// 未勾选「允许数据出境」时，下拉只列本地 provider；勾选后才出现在线服务商
const visibleProviders = computed(() =>
  cfg.value.onlineAllowed ? PROVIDERS : PROVIDERS.filter((p) => !p.online)
)

// 取消出境同意时，若当前选的是在线 provider，自动回退到本地 ollama
watch(
  () => cfg.value.onlineAllowed,
  (allowed, was) => {
    if (was && !allowed && isOnlineProvider(cfg.value.provider)) {
      cfg.value.provider = 'ollama'
    }
  }
)

onMounted(async () => {
  try {
    const d = await api<AiConfig>('/admin/ai/config')
    cfg.value = { ...cfg.value, ...d, apiKey: '' }
  } catch { /* 配置读取失败保持默认 */ }
})

async function save(): Promise<void> {
  busy.value = true
  try {
    const d = await api<AiConfig>('/admin/ai/config', {
      method: 'PUT', body: { ...cfg.value },
    })
    cfg.value = { ...cfg.value, ...d, apiKey: '' }
    toast.success(tr('aiConfig.saved', 'AI 配置已保存'))
    await refreshCaps()
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    busy.value = false
  }
}

async function test(): Promise<void> {
  testing.value = true
  try {
    const r = await api<{ ok: boolean; reason: string }>('/admin/ai/test', { method: 'POST' })
    if (r.ok) toast.success(tr('aiConfig.testOk', '连接成功'))
    else toast.error(r.reason || tr('aiConfig.testFail', '连接失败'))
  } catch (e) {
    toast.error((e as Error).message)
  } finally {
    testing.value = false
  }
}
</script>

<template>
  <div class="card deploy ai-config" data-ai-feature="admin">
    <h2 class="deploy__title">{{ tr('aiConfig.title', 'AI 能力配置') }}</h2>
    <p class="hint">{{ tr('aiConfig.note', '本地优先；在线服务需显式同意出境') }}</p>

    <!-- 恢复开关（docs/20 §6.9.3）：关闭态下这是管理员唯一可见的 AI 入口，始终保留 -->
    <label class="deploy__switch ai-config__master">
      <input v-model="cfg.enabled" type="checkbox" />
      <span>{{ tr('aiConfig.enable', '启用 AI 能力') }}</span>
    </label>
    <p v-if="!cfg.enabled" class="storage-note">{{ tr('aiConfig.disabledNote', '当前未启用；勾选并保存后可配置服务商与能力域') }}</p>

    <template v-if="cfg.enabled">
    <div class="deploy__grid">
      <label class="field">
        <span class="field__label">{{ tr('aiConfig.provider', 'Provider') }}</span>
        <select v-model="cfg.provider" class="field-control">
          <option v-for="p in visibleProviders" :key="p.value" :value="p.value">{{ p.label }}</option>
        </select>
      </label>
      <label class="field">
        <span class="field__label">{{ tr('aiConfig.model', '模型') }}</span>
        <input v-model="cfg.model" class="field-control" type="text" placeholder="qwen2.5:0.5b-instruct" />
      </label>
      <label class="field">
        <span class="field__label">{{ tr('aiConfig.baseUrl', '端点') }}</span>
        <input v-model="cfg.baseUrl" class="field-control" type="text" placeholder="http://127.0.0.1:11434/v1" />
      </label>
      <label class="field">
        <span class="field__label">
          {{ tr('aiConfig.apiKey', 'API 密钥') }}
          <em v-if="cfg.apiKeySet" class="ai-config__set">{{ tr('aiConfig.keySet', '已配置') }}</em>
        </span>
        <input v-model="cfg.apiKey" class="field-control" type="password" placeholder="***" autocomplete="off" />
      </label>
    </div>

    <p class="hint">{{ tr('aiConfig.credentialHint', '密钥脱敏回显，留空表示本次不重写。') }}</p>

    <div class="storage-provider-hint ai-config__domains">
      <div class="deploy__title">{{ tr('aiConfig.domains', '能力域开关') }}</div>
      <div class="ai-config__domain-grid">
        <label><input v-model="cfg.vision" type="checkbox" /> {{ tr('aiConfig.vision', '视觉识别') }}</label>
        <label><input v-model="cfg.summary" type="checkbox" /> {{ tr('aiConfig.summary', '档案总结') }}</label>
        <label><input v-model="cfg.query" type="checkbox" /> {{ tr('aiConfig.query', '自然语言查询') }}</label>
        <label><input v-model="cfg.advice" type="checkbox" /> {{ tr('aiConfig.advice', '智能建议') }}</label>
      </div>
      <label class="ai-config__online">
        <input v-model="cfg.onlineAllowed" type="checkbox" />
        {{ tr('aiConfig.online', '允许数据出境（在线服务商）') }}
        <em class="ai-config__online-note">{{
          cfg.onlineAllowed
            ? tr('aiConfig.onlineOn', '已允许：可选在线服务商，数据将发送到本机之外')
            : tr('aiConfig.onlineOff', '未允许：仅可选本地服务，不向外部发送任何档案内容')
        }}</em>
      </label>
      <div class="hint">{{ tr('aiConfig.domainHint', '纯文本模型仅启用总结/查询/建议；视觉识别需视觉模型。在线服务商需先勾选上方出境同意才会出现在 Provider 列表。') }}</div>
    </div>
    </template>

    <div class="deploy__actions">
      <button class="btn-primary" type="button" :disabled="busy" @click="save">
        {{ busy ? tr('common.saving', '保存中…') : tr('common.save', '保存') }}
      </button>
      <button v-if="cfg.enabled" class="btn-ghost" type="button" :disabled="testing" @click="test">
        {{ testing ? tr('aiConfig.testing', '测试中…') : tr('aiConfig.test', '测试连接') }}
      </button>
    </div>
  </div>
</template>

<style scoped>
/* 与 SystemView「部署配置 / 存储平台」页同款：复用全局 .card / .field-control / .btn-*，
   以下仅补 SystemView scoped 里那几类的等价样式（子组件拿不到父组件的 scoped 样式）。 */
.ai-config { margin-bottom: var(--sp-4); }
.deploy__title { font-size: var(--font-size-lg); font-weight: 600; margin: 0 0 var(--sp-2); }
.hint { font-size: var(--font-size-sm); color: var(--text-secondary); margin: var(--sp-2) 0; line-height: 1.6; }
.deploy__grid {
  display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--sp-4); margin-top: var(--sp-4);
}
.field { display: grid; gap: var(--sp-2); }
.field__label { font-size: var(--font-size-sm); color: var(--text-secondary); }
.deploy__actions { display: flex; gap: var(--sp-3); margin-top: var(--sp-4); }
.deploy__switch { display: inline-flex; align-items: center; gap: var(--sp-2); cursor: pointer; font-size: var(--font-size-md); }
.deploy__switch input { width: 18px; height: 18px; accent-color: var(--accent); }
.ai-config__master { margin: var(--sp-3) 0; }
.storage-note {
  border: 1px solid var(--border-subtle); background: var(--bg-inset);
  border-radius: var(--g3-sm); padding: var(--sp-3) var(--sp-4);
  font-size: var(--font-size-sm); color: var(--text-secondary); margin: var(--sp-3) 0;
}
.storage-provider-hint {
  border: 1px solid var(--border-subtle); background: var(--bg-inset);
  border-radius: var(--g3-md); padding: var(--sp-4); margin-top: var(--sp-4);
}
.ai-config__set { color: var(--accent); font-style: normal; margin-left: 6px; }
.ai-config__domain-grid {
  display: grid; grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: var(--sp-2) var(--sp-4); margin: var(--sp-3) 0;
}
.ai-config__domain-grid label, .ai-config__online {
  display: inline-flex; align-items: center; gap: var(--sp-2); font-size: var(--font-size-sm);
}
.ai-config__online { margin-bottom: var(--sp-2); flex-wrap: wrap; }
.ai-config__online-note { font-size: var(--font-size-xs); color: var(--text-muted); font-style: normal; }
.ai-config__domain-grid input, .ai-config__online input { width: 16px; height: 16px; accent-color: var(--accent); }
@media (max-width: 639px) {
  .deploy__grid, .ai-config__domain-grid { grid-template-columns: 1fr; }
}
</style>
