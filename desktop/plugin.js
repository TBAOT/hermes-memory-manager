/**
 * Memory Manager desktop plugin.
 *
 * Registers a route + sidebar entry + palette command that opens a panel
 * for viewing and editing the active profile's MEMORY.md and USER.md.
 * The backend API lives in `python/dashboard/plugin_api.py` and is
 * mounted at `/api/plugins/memory-manager/` by the Hermes web server.
 *
 * Loaded as a runtime disk plugin from
 * `<HERMES_HOME>/desktop-plugins/memory-manager/plugin.js`.
 */

import { jsx, jsxs, Fragment } from 'react/jsx-runtime'
import { useState, useEffect, useCallback } from 'react'

import {
  host,
  useValue,
  useQuery,
  useMutation,
  useQueryClient,
  cn,
  Button,
  Textarea,
  Loader,
  ConfirmDialog,
  PALETTE_AREA,
  ROUTES_AREA,
  SIDEBAR_NAV_AREA
} from '@hermes/plugin-sdk'

const PLUGIN_ID = 'memory-manager'
const ROUTE_PATH = '/memory-manager'

// Saved from register(ctx) — the sanctioned IPC bridge for plugin REST calls.
// In the Electron desktop the page origin is file://, so raw fetch() can't
// reach the HTTP backend. ctx.rest() goes through window.hermesDesktop.api()
// which the main process forwards to the web server with auth.
let _rest = null

// File keys handled by the backend. Keep in sync with plugin_api.py.
const TABS = [
  { key: 'memory', label: '代理记忆', file: 'MEMORY.md' },
  { key: 'user', label: '用户画像', file: 'USER.md' }
]

async function fetchContent() {
  if (!_rest) throw new Error('插件未初始化')
  return _rest('/content')
}

async function fetchStats() {
  if (!_rest) throw new Error('插件未初始化')
  return _rest('/stats')
}

async function fetchSettings() {
  if (!_rest) throw new Error('插件未初始化')
  return _rest('/settings')
}

function useMemoryContent(profile) {
  const queryKey = ['memory-manager', 'content', profile]
  const { data, isLoading, error, refetch } = useQuery({
    queryKey,
    queryFn: fetchContent
  })

  return { data, isLoading, error, refetch, queryKey }
}

function useMemoryStats(profile) {
  const queryKey = ['memory-manager', 'stats', profile]
  const { data, isLoading, error } = useQuery({
    queryKey,
    queryFn: fetchStats
  })
  return { data, isLoading, error, queryKey }
}

function useMemorySettings(profile) {
  const queryKey = ['memory-manager', 'settings', profile]
  const { data, isLoading } = useQuery({
    queryKey,
    queryFn: fetchSettings
  })
  return { data, isLoading, queryKey }
}

function MemoryManagerPanel() {
  const profile = useValue(host.state.profile)
  const queryClient = useQueryClient()

  const [activeTab, setActiveTab] = useState('memory')
  const [draft, setDraft] = useState({ memory: '', user: '' })
  const [dirty, setDirty] = useState({ memory: false, user: false })
  const [confirmSwitch, setConfirmSwitch] = useState(null)
  const [confirmReset, setConfirmReset] = useState(false)
  const [showSettings, setShowSettings] = useState(false)
  const [settingsDraft, setSettingsDraft] = useState('1')

  const profileName = profile || 'default'

  // useQuery's queryKey includes profileName, so react-query auto-refetches
  // when the active profile changes — that's the "follow profile switch"
  // behavior. The draft is re-initialized from the new data via the effect
  // below.
  const { data, isLoading, error, refetch } = useMemoryContent(profileName)
  const { data: stats } = useMemoryStats(profileName)
  const { data: settings } = useMemorySettings(profileName)

  // Initialize draft when content loads or profile changes.
  useEffect(() => {
    if (data) {
      setDraft({
        memory: data.memory || '',
        user: data.user || ''
      })
      setDirty({ memory: false, user: false })
    }
  }, [data])

  // Sync settings draft when settings load.
  useEffect(() => {
    if (settings && settings.max_size_bytes) {
      setSettingsDraft((settings.max_size_bytes / 1_048_576).toFixed(1))
    }
  }, [settings])

  const saveMutation = useMutation({
    mutationFn: async (content) => {
      if (!_rest) throw new Error('插件未初始化')
      return _rest('/content', { method: 'POST', body: content })
    },
    onSuccess: () => {
      setDirty({ memory: false, user: false })
      host.notify({ kind: 'success', message: '记忆已保存' })
      queryClient.invalidateQueries({ queryKey: ['memory-manager', 'content'] })
      queryClient.invalidateQueries({ queryKey: ['memory-manager', 'stats'] })
    },
    onError: (err) => {
      host.notifyError(err, '保存记忆失败')
    }
  })

  const saveSettingsMutation = useMutation({
    mutationFn: async (maxSizeMb) => {
      if (!_rest) throw new Error('插件未初始化')
      const maxSizeBytes = Math.round(parseFloat(maxSizeMb) * 1_048_576)
      return _rest('/settings', { method: 'POST', body: { max_size_bytes: maxSizeBytes } })
    },
    onSuccess: () => {
      host.notify({ kind: 'success', message: '设置已保存' })
      queryClient.invalidateQueries({ queryKey: ['memory-manager', 'settings'] })
      queryClient.invalidateQueries({ queryKey: ['memory-manager', 'stats'] })
    },
    onError: (err) => {
      host.notifyError(err, '保存设置失败')
    }
  })

  const handleChange = useCallback((key, value) => {
    setDraft(prev => ({ ...prev, [key]: value }))
    setDirty(prev => ({ ...prev, [key]: true }))
  }, [])

  const handleSave = useCallback(() => {
    const payload = {}
    if (dirty.memory) payload.memory = draft.memory
    if (dirty.user) payload.user = draft.user
    if (Object.keys(payload).length === 0) return
    saveMutation.mutate(payload)
  }, [draft, dirty, saveMutation])

  const handleSaveSettings = useCallback(() => {
    const val = parseFloat(settingsDraft)
    if (Number.isNaN(val) || val <= 0) {
      host.notify({ kind: 'error', message: '请输入有效的大小限制' })
      return
    }
    saveSettingsMutation.mutate(settingsDraft)
  }, [settingsDraft, saveSettingsMutation])

  const handleTabSwitch = useCallback((next) => {
    if (next === activeTab) return
    if (dirty[activeTab]) {
      setConfirmSwitch(next)
    } else {
      setActiveTab(next)
    }
  }, [activeTab, dirty])

  const handleReset = useCallback(() => {
    if (data) {
      setDraft({
        memory: data.memory || '',
        user: data.user || ''
      })
      setDirty({ memory: false, user: false })
      host.notify({ kind: 'info', message: '已撤销未保存的更改' })
    }
  }, [data])

  const hasDirty = dirty.memory || dirty.user
  const isSaving = saveMutation.isPending

  if (isLoading && !data) {
    return jsx('div', {
      className: 'flex h-full w-full items-center justify-center',
      children: jsx(Loader, { type: 'rose-curve' })
    })
  }

  if (error && !data) {
    return jsxs('div', {
      className: 'flex h-full w-full flex-col items-center justify-center gap-3 p-6 text-center',
      children: [
        jsx('div', {
          className: 'text-sm font-medium text-destructive',
          children: '加载记忆失败'
        }),
        jsx('div', {
          className: 'text-xs text-muted-foreground',
          children: String(error?.message || error)
        }),
        jsx(Button, {
          variant: 'outline',
          size: 'sm',
          onClick: () => refetch(),
          children: '重试'
        })
      ]
    })
  }

  return jsxs(Fragment, {
    children: [
      jsxs('div', {
        className: 'flex h-full w-full flex-col gap-3 p-4',
        children: [
          // Header — show active profile + action buttons
          jsxs('div', {
            className: 'flex items-center justify-between gap-2',
            children: [
              jsxs('div', {
                className: 'flex flex-col',
                children: [
                  jsxs('div', {
                    className: 'text-sm font-medium',
                    children: ['当前 Profile: ', jsx('span', { className: 'text-primary', children: profileName })]
                  }),
                  jsx('div', {
                    className: 'text-xs text-muted-foreground',
                    children: '编辑后点击保存。切换 Profile 会自动加载对应记忆。'
                  })
                ]
              }),
              jsxs('div', {
                className: 'flex items-center gap-2',
                children: [
                  jsx(Button, {
                    variant: 'ghost',
                    size: 'sm',
                    onClick: () => setShowSettings(s => !s),
                    children: '设置'
                  }),
                  jsx(Button, {
                    variant: 'ghost',
                    size: 'sm',
                    onClick: () => setConfirmReset(true),
                    disabled: !hasDirty || isSaving,
                    children: '撤销更改'
                  }),
                  jsx(Button, {
                    size: 'sm',
                    onClick: handleSave,
                    disabled: !hasDirty || isSaving,
                    children: isSaving ? '保存中…' : '保存'
                  })
                ]
              })
            ]
          }),

          // Settings panel (inline)
          showSettings && jsxs('div', {
            className: 'flex items-center gap-3 rounded-md border bg-muted/50 p-3',
            children: [
              jsxs('span', {
                className: 'text-xs font-medium',
                children: ['记忆大小限制']
              }),
              jsxs('div', {
                className: 'flex items-center gap-1',
                children: [
                  jsx('input', {
                    type: 'number',
                    min: 0.1,
                    step: 0.5,
                    className: 'h-7 w-20 rounded-md border bg-background px-2 text-xs tabular-nums',
                    value: settingsDraft,
                    onChange: (e) => setSettingsDraft(e.target.value)
                  }),
                  jsx('span', {
                    className: 'text-xs text-muted-foreground',
                    children: 'MB'
                  })
                ]
              }),
              jsx(Button, {
                size: 'sm',
                variant: 'outline',
                onClick: handleSaveSettings,
                disabled: saveSettingsMutation.isPending,
                children: saveSettingsMutation.isPending ? '保存中…' : '保存'
              })
            ]
          }),

          // Tab switcher
          jsx('div', {
            className: 'inline-flex h-9 w-fit items-center gap-1 rounded-lg bg-muted p-1',
            children: TABS.map(tab => {
              const isActive = activeTab === tab.key
              const isTabDirty = dirty[tab.key]
              return jsxs('button', {
                type: 'button',
                onClick: () => handleTabSwitch(tab.key),
                className: cn(
                  'inline-flex h-7 items-center gap-1.5 rounded-md px-3 text-sm font-medium transition-all',
                  isActive
                    ? 'bg-background text-foreground shadow-xs'
                    : 'text-muted-foreground hover:text-foreground'
                ),
                children: [
                  tab.label,
                  isTabDirty ? jsx('span', {
                    className: 'size-1.5 rounded-full bg-primary',
                    'aria-label': '未保存'
                  }) : null
                ]
              }, tab.key)
            })
          }),

          // Editor area
          jsx('div', {
            className: 'flex-1 min-h-0 overflow-hidden rounded-md border',
            children: jsx(Textarea, {
              className: 'h-full w-full resize-none rounded-md border-0 bg-transparent font-mono text-sm leading-relaxed focus-visible:ring-0',
              value: draft[activeTab] || '',
              onChange: (e) => handleChange(activeTab, e.target.value),
              placeholder: `当前没有 ${TABS.find(t => t.key === activeTab)?.file} 内容。开始输入即可创建。`,
              spellCheck: false
            })
          }),

          // Footer — size stats + file info
          jsxs('div', {
            className: 'flex flex-col gap-1.5',
            children: [
              // Size progress bar
              stats && jsxs('div', {
                className: 'flex items-center gap-2',
                children: [
                  jsx('div', {
                    className: 'h-1.5 flex-1 rounded-full bg-muted overflow-hidden',
                    children: jsx('div', {
                      className: cn(
                        'h-full rounded-full transition-all',
                        stats.usage_percent > 100 ? 'bg-destructive' :
                        stats.usage_percent > 80 ? 'bg-amber-500' : 'bg-primary'
                      ),
                      style: { width: `${Math.min(stats.usage_percent, 100)}%` }
                    })
                  }),
                  jsxs('span', {
                    className: cn(
                      'text-[11px] tabular-nums shrink-0',
                      stats.usage_percent > 100 ? 'text-destructive font-medium' :
                      stats.usage_percent > 80 ? 'text-amber-500' : 'text-muted-foreground'
                    ),
                    children: [
                      `${stats.total_formatted} / ${stats.max_size_formatted}`,
                      ` (${stats.usage_percent}%)`
                    ]
                  })
                ]
              }),

              // Footer hint row
              jsxs('div', {
                className: 'flex items-center justify-between text-xs text-muted-foreground',
                children: [
                  jsxs('span', {
                    children: [
                      '文件: ',
                      TABS.find(t => t.key === activeTab)?.file,
                      stats?.sizes?.[activeTab]
                        ? ` (${stats.sizes[activeTab].formatted})`
                        : null
                    ]
                  }),
                  hasDirty ? jsx('span', { className: 'text-amber-500', children: '有未保存的更改' }) : jsx('span', { children: '已保存' })
                ]
              })
            ]
          })
        ]
      }),

      // Confirm dialog: switch tab with unsaved changes
      jsx(ConfirmDialog, {
        open: confirmSwitch !== null,
        onClose: () => setConfirmSwitch(null),
        onConfirm: async () => {
          if (confirmSwitch) setActiveTab(confirmSwitch)
        },
        title: '未保存的更改',
        description: '当前标签有未保存的更改，切换后将丢失。确定要切换吗？',
        confirmLabel: '切换',
        destructive: true,
        dismissOnConfirm: true
      }),

      // Confirm dialog: reset changes
      jsx(ConfirmDialog, {
        open: confirmReset,
        onClose: () => setConfirmReset(false),
        onConfirm: async () => {
          handleReset()
        },
        title: '撤销更改',
        description: '将所有未保存的编辑恢复为磁盘上的内容。',
        confirmLabel: '撤销',
        destructive: true,
        dismissOnConfirm: true
      })
    ]
  })
}

export default {
  id: PLUGIN_ID,
  name: '记忆管理器',
  defaultEnabled: true,
  register(ctx) {
    _rest = ctx.rest
    // Command palette entry
    ctx.register({
      id: 'open',
      area: PALETTE_AREA,
      data: {
        id: 'open-memory-manager',
        label: '打开记忆管理器',
        keywords: ['memory', '记忆', 'MEMORY.md', 'USER.md', '用户画像'],
        run: () => host.navigate(ROUTE_PATH)
      }
    })

    // Route — the full-page view
    ctx.register({
      id: 'route',
      area: ROUTES_AREA,
      title: '记忆管理器',
      data: { path: ROUTE_PATH },
      render: () => jsx(MemoryManagerPanel, {})
    })

    // Sidebar navigation row
    ctx.register({
      id: 'nav',
      area: SIDEBAR_NAV_AREA,
      data: {
        codicon: 'database',
        label: '记忆管理器',
        path: ROUTE_PATH
      }
    })
  }
}
