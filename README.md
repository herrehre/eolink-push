# eolink-push

让 AI 直接读取 Spring Boot 代码里的接口与字段（字段中文名来自代码注释），并把接口文档**幂等同步**到
[Eolink Apikit](https://www.eolink.com) 项目。纯 PowerShell，零依赖，开箱即用。

## 特性

- `/api <接口描述>` 一句话入口：AI 自动定位 Controller、提取参数与实体字段、从注释取中文名、生成 OpenAPI 规格并推送。
- 支持 Trae / Codex 双 AI IDE，`setup.ps1` 安装时可选。
- 「当前项目」自动解析：优先 AI IDE 打开的工作区（含 `pom.xml`/`build.gradle` 即视为 Spring Boot 项目，支持多模块项目），
  否则使用配置 `projectDir`（自动设为 eolink-push 的父目录）。
- 幂等同步：按「方法 + 路径」匹配，已存在则更新（内容未变跳过）、不存在则创建、分组缺失自动创建、默认不删除。
- CLI 手动用法：`validate` / `push` / `list`，stdout 输出 JSON，退出码约定，可进 CI。
- 凭证本地保存（gitignore）或环境变量注入，仓库内无任何真实凭证。

## 快速开始

环境要求：Windows 10/11、PowerShell 5.1+（系统自带）、Git；使用 AI 入口还需要 Trae 或 Codex。

```powershell
# 1. 克隆到你的 Spring Boot 项目根目录下
cd your-spring-boot-project
git clone https://github.com/herrehre/eolink-push.git

# 2. 生成配置（粘贴项目 URL 自动解析，只需手动输入令牌）
#    setup 会自动检测父目录为 projectDir，并部署规则文件到项目根目录
powershell -NoProfile -ExecutionPolicy Bypass -File eolink-push\eolink\setup.ps1

# 3a. 在 Trae 或 Codex 中打开你的 Spring Boot 项目，输入：
#     /api 客户列表接口

# 3b. 或手动推送一份 OpenAPI 3.0 JSON：
powershell -NoProfile -ExecutionPolicy Bypass -File eolink-push\eolink\eolink.ps1 validate -Spec eolink-push\sample\openapi.example.json
powershell -NoProfile -ExecutionPolicy Bypass -File eolink-push\eolink\eolink.ps1 push -Spec eolink-push\sample\openapi.example.json -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File eolink-push\eolink\eolink.ps1 push -Spec eolink-push\sample\openapi.example.json
```

## 获取 Eolink 凭证

1. 登录 Eolink，打开你的 API 项目，复制浏览器地址栏中的项目 URL（形如
   `https://xxx.w.eolink.com/home/api-studio/inside/.../api/12345/list?spaceKey=xxx`）。
2. 进入工作空间 **空间设置 → 开放 API**，生成 **Open API 令牌（Eo-Secret-Key）**。
3. 运行 `setup.ps1`，粘贴项目 URL 即可自动解析 `spaceId` 和 `projectId`，只需手动输入令牌。
4. setup 会自动测试连通性，并保存到 `eolink/eolink.config.json`（已被 .gitignore 排除）。

## CLI 命令

```powershell
validate [-Spec <path>]                       # 校验规格：summary 与字段中文名必填
push [-Spec <path>] [-Project <id>] [-DryRun] # 幂等同步到 Eolink
list [-Project <id>]                          # 列出项目/分组/接口
project [-Dir <path>]                         # 解析当前 Spring Boot 项目路径
```

退出码：`0` 成功 / `1` 校验失败 / `2` 配置或鉴权错误 / `3` 网络错误 / `4` 部分成功或功能暂不支持。
stdout 为 JSON（供 AI/CI 解析），提示信息在 stderr。

## 配置

`eolink/eolink.config.json`（模板见 `eolink/eolink.config.example.json`）：

| 字段 | 说明 |
| --- | --- |
| `baseUrl` | Eolink Open API 基址，SaaS 默认 `https://api.eolink.com` |
| `spaceId` | 工作空间域名标识 |
| `projectId` | 目标项目 ID |
| `eoSecretKey` | Open API 令牌 |
| `defaultGroup` | 缺省分组名 |
| `projectDir` | 自动设为 eolink-push 的父目录（即你的 Spring Boot 项目根目录） |
| `sqlCommentsPath` | 可选：SQL 文件路径，字段中文注释兜底来源 |
| `specPath` | 规格文件路径，默认 `specs/openapi.json` |
| `aiIde` | 使用的 AI IDE：`trae` / `codex` / `both`，默认 `trae` |

凭证也可用环境变量覆盖：`EOLINK_BASE_URL` / `EOLINK_SPACE_ID` / `EOLINK_PROJECT_ID` / `EOLINK_SECRET_KEY`。

## /api 用法（AI 入口）

将 eolink-push 克隆到你的 Spring Boot 项目根目录下，运行 `setup.ps1` 后，规则文件会自动部署到项目根目录。
在 Trae 或 Codex 中打开你的 Spring Boot 项目，输入：

```
/api 客户管理模块接口
/api 新增客户的请求参数和响应
/api 把用户登录接口推上去
```

AI 会先解析「当前项目」（当前工作区优先，支持多模块 Maven/Gradle 项目），读取其中的 Spring Boot 代码，
按以下优先级为字段取中文名：
Java 字段 `// 注释` 或 Javadoc `/** 注释 */` → SQL 列 `COMMENT` → 字段名兜底。
规格累积写入 `eolink-push/eolink/specs/openapi.json`，推送后汇报每个接口的创建/更新/跳过结果。

## AI IDE 规则文件

| AI IDE | 规则文件 | 说明 |
| --- | --- | --- |
| Trae | `.trae/rules/eolink-push.md` | 项目规则，`alwaysApply: true` |
| Trae | `.trae/commands/api.md` | 斜杠命令 `/api` |
| Codex | `AGENTS.md` | 项目根目录，Codex 原生读取 |

`setup.ps1` 安装时可选择使用的 AI IDE（Trae / Codex / Both），选择结果记录在配置 `aiIde` 字段中。
规则文件会自动部署到你的 Spring Boot 项目根目录，路径引用会自动改写为 `eolink-push/eolink/...`。

## 幂等语义

- 匹配键：`方法 + 路径`（忽略首尾 `/` 与大小写）。
- 已存在 → 对比内容（名称/路径/方法/分组/参数），有变化才更新；未变化 → 跳过。
- 不存在 → 创建；目标分组不存在时自动创建。
- 默认不删除任何已有文档（`-Clean` 暂未实现，因 Eolink Open API 未公开删除端点）。

## 更新

一键拉取最新版本，配置和规格文件不受影响（gitignored），规则文件自动重新部署：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File eolink-push\eolink\update.ps1
```

## 常见问题

- **401/403**：检查 `eoSecretKey` 是否正确、该空间/项目是否有权限；重新运行 `setup.ps1`。
- **连接失败**：确认 `baseUrl`（SaaS 为 `https://api.eolink.com`，无末尾斜杠）与网络。
- **validate 报字段缺中文名**：给字段补 `description`（AI 提取时从注释读取）。
- **只支持 JSON 规格**：v1 不支持 YAML。
- **`-Clean` / `-FullImport`**：v1 暂不支持，使用时会明确报错。

## License

MIT，见 [LICENSE](LICENSE)。
