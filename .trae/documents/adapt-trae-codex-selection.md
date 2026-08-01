# 适配 Trae：安装时可选 Trae / Codex

## 摘要

将 eolink-push 项目从仅支持 Codex 扩展为同时支持 Trae 和 Codex，在 `setup.ps1` 安装流程中增加 AI IDE 选择步骤（类似 OpenSpec 的 `init` 选择体验），并生成对应的规则文件。

## 当前状态

- 项目仅有 `AGENTS.md`（Codex 规则文件），无 Trae 配置
- `setup.ps1` 无 AI IDE 选择步骤，结尾提示固定为 "open this repository in Codex"
- `eolink.ps1` 第 710 行 hint 固定提及 Codex
- `README.md` 4 处提及 Codex，无 Trae 说明
- `.gitignore` 未涉及 `.trae/` 目录

## 变更计划

### 1. 新建 `.trae/rules/eolink-push.md`（Trae 项目规则）

**为什么**：Trae 的项目规则放在 `.trae/rules/` 目录下，使用 Markdown + frontmatter 格式。此文件应入库（团队共享规则）。

**内容**：将 AGENTS.md 的内容适配为 Trae 规则格式：
- 添加 frontmatter：`alwaysApply: true`（始终生效）
- 将 "Codex 当前工作区" 改为 "当前工作区"（Trae 语境）
- 其余 /api 命令流程、约定保持一致

### 2. 修改 `eolink/setup.ps1`：增加 AI IDE 选择步骤

**位置**：在 `defaultGroup` 提问之后、`projectDir` 提问之前插入。

**逻辑**：
```
Write-Host "Which AI IDE are you using?"
Write-Host "  [1] Trae (Recommended)"
Write-Host "  [2] Codex"
Write-Host "  [3] Both"
$input = Read-Host "Select (default: 1)"
```

根据选择：
- Trae / Both：验证 `.trae/rules/eolink-push.md` 存在（已入库，正常情况一定存在）；若不存在则提示
- Codex / Both：验证 `AGENTS.md` 存在；若不存在则提示
- 将选择结果写入 `eolink.config.json` 的新字段 `aiIde`（值为 `trae` / `codex` / `both`）

**结尾提示**：根据选择输出不同的 Next 步骤：
- Trae → "Next: open this repository in Trae and type: /api <接口描述>"
- Codex → "Next: open this repository in Codex and type: /api <接口描述>"
- Both → 两行都输出

### 3. 修改 `eolink/eolink.ps1`：更新 hint 文案

**位置**：第 710 行 `Invoke-Project` 函数中的 hint。

**变更**：
```
# 旧
hint = 'run setup.ps1 to set projectDir, or open Codex in the project directory'
# 新
hint = 'run setup.ps1 to set projectDir, or open the project in Trae/Codex'
```

### 4. 修改 `AGENTS.md`：泛化工作区描述

**位置**：第 21 行。

**变更**：
```
# 旧
- 优先：Codex 当前工作区（若含 ...）
# 新
- 优先：AI IDE 当前工作区（若含 ...）
```

这样 AGENTS.md 同时被 Trae（Trae 也读 AGENTS.md）和 Codex 使用时都合理。

### 5. 修改 `README.md`：文档双支持

**变更点**：
- 特性列表：增加 "支持 Trae / Codex 双 AI IDE，setup 时可选"
- 环境要求：`使用 AI 入口还需要 Trae 或 Codex`
- 快速开始步骤 3a：改为 Trae 和 Codex 两种入口并列
- /api 用法段落：说明 Trae 和 Codex 均可使用
- 新增一小节说明 Trae 规则文件位置（`.trae/rules/eolink-push.md`）

### 6. 修改 `eolink/eolink.config.example.json`：增加 aiIde 字段

```json
{
  ...
  "aiIde": "trae"
}
```

### 7. `.gitignore` 无需修改

`.trae/rules/` 是项目规则，应入库共享，不需要忽略。

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `.trae/rules/eolink-push.md` | 新建 | Trae 项目规则（alwaysApply） |
| `eolink/setup.ps1` | 修改 | 增加 AI IDE 选择 + 结尾提示适配 |
| `eolink/eolink.ps1` | 修改 | 第 710 行 hint 泛化 |
| `AGENTS.md` | 修改 | 第 21 行 "Codex" → "AI IDE" |
| `README.md` | 修改 | 文档双支持说明 |
| `eolink/eolink.config.example.json` | 修改 | 增加 `aiIde` 字段 |

## 假设与决策

- Trae 规则使用 `alwaysApply: true`（始终生效），因为 /api 命令是全局入口，不应限定文件范围
- `aiIde` 字段仅为记录用户偏好，不影响 CLI 核心逻辑（validate/push/list 与 IDE 无关）
- AGENTS.md 保留不删除（Codex 原生读取 + Trae 也兼容读取）
- `.trae/rules/eolink-push.md` 入库（团队共享），不加入 .gitignore

## 验证步骤

1. 运行 `powershell -NoProfile -ExecutionPolicy Bypass -File eolink/setup.ps1`，确认出现 AI IDE 选择步骤，三种选项均正常工作
2. 确认 `.trae/rules/eolink-push.md` 格式正确（frontmatter + markdown body）
3. 运行 `powershell -NoProfile -ExecutionPolicy Bypass -File eolink/eolink.ps1 project`，确认 hint 文案已更新
4. 在 Trae 中打开项目，确认规则被加载（设置 → 规则 → 项目规则中可见 eolink-push）
5. 检查 README.md 渲染正常，无断链
