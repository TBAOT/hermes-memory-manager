# Hermes Memory Manager

一个 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 桌面端插件，让你在桌面 UI 中直接查看和编辑当前人格（profile）的 **代理记忆（MEMORY.md）** 与 **用户画像（USER.md）**，并随人格切换自动跟随。

## 为什么需要它

Hermes 桌面端默认没有记忆查看/编辑界面，只能通过命令行或文件管理器手动打开 `~/.hermes/memories/MEMORY.md`。本插件把这个流程做成了一个一等公民的桌面视图：

- 在侧边栏一键打开记忆编辑器
- 标签切换 **代理记忆 / 用户画像**
- 切换 profile 时自动加载对应记忆
- 保存前自动备份 `.bak`，避免误操作丢失数据
- 未保存提示、撤销更改、命令面板入口

## 目录结构

```
hermes-memory-manager/
├── python/
│   └── dashboard/
│       ├── manifest.json      # 后端插件清单
│       └── plugin_api.py      # FastAPI 路由：GET/POST /content、GET /profile
├── desktop/
│   └── plugin.js              # 桌面端 runtime plugin（注册路由/侧边栏/命令面板）
├── install.ps1                # Windows 一键安装
├── install.sh                 # Linux/macOS 一键安装
└── README.md
```

## 安装

### 一键安装（推荐）

**Windows（PowerShell）：**

```powershell
irm https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.ps1 | iex
```

**Linux / macOS：**

```bash
curl -fsSL https://raw.githubusercontent.com/TBAOT/hermes-memory-manager/main/install.sh | bash
```

脚本会：

1. 把后端文件放到 `<HERMES_HOME>/plugins/memory-manager/dashboard/`
2. 把桌面插件放到 `<HERMES_HOME>/desktop-plugins/memory-manager/plugin.js`
3. 调用 `hermes plugins enable memory-manager` 启用后端 API（fallback 直接编辑 `config.yaml`）
4. 提示你重启 Hermes Desktop

### 手动安装

```bash
# 1. 放后端文件
mkdir -p ~/.hermes/plugins/memory-manager/dashboard
cp python/dashboard/{manifest.json,plugin_api.py} ~/.hermes/plugins/memory-manager/dashboard/

# 2. 放桌面插件
mkdir -p ~/.hermes/desktop-plugins/memory-manager
cp desktop/plugin.js ~/.hermes/desktop-plugins/memory-manager/

# 3. 启用后端 API
hermes plugins enable memory-manager

# 4. 重启网关
hermes gateway restart
```

## 使用

1. 启动 Hermes Desktop
2. 在左侧侧边栏点击 **记忆管理器**（数据库图标），或按 `Ctrl+K` 打开命令面板搜索「打开记忆管理器」
3. 切换标签查看/编辑 **代理记忆** 或 **用户画像**
4. 点击 **保存** 写入磁盘（原文件会备份为 `MEMORY.md.bak` / `USER.md.bak`）
5. 在桌面顶部切换 profile，记忆内容会自动重新加载

## 跟随 profile 切换

- 后端 `plugin_api.py` 使用 `hermes_constants.get_hermes_home()`，在 profile-scoped gateway 下自动指向当前 profile 的 `memories/` 目录
- 桌面端通过 `useValue(host.state.profile)` 订阅当前 profile，profile 变化时 React Query 自动重新拉取

## 路由

| 方法   | 路径                                       | 说明                              |
| ------ | ------------------------------------------ | --------------------------------- |
| GET    | `/api/plugins/memory-manager/content`      | 返回 `{memory, user}` 两个字符串  |
| POST   | `/api/plugins/memory-manager/content`      | 保存 `{memory?, user?}`（仅写入提供的字段） |
| GET    | `/api/plugins/memory-manager/profile`      | 返回当前 profile 名称与记忆目录   |

## 卸载

```bash
hermes plugins disable memory-manager
rm -rf ~/.hermes/plugins/memory-manager
rm -rf ~/.hermes/desktop-plugins/memory-manager
hermes gateway restart
```

## 兼容性

- Hermes Agent 桌面端（支持 `desktop-plugins/` runtime plugin 系统）
- Python 3.10+（FastAPI + Pydantic v2，随 Hermes 依赖安装）
- Windows / Linux / macOS

## 开发

桌面插件是从磁盘热加载的：编辑 `<HERMES_HOME>/desktop-plugins/memory-manager/plugin.js` 保存后会自动重新加载，无需重启。后端 `plugin_api.py` 修改后需要 `hermes gateway restart`。

## License

MIT
