# eolink-push

本仓库是一个把接口文档幂等推送到 Eolink Apikit 的工具：

- `eolink/eolink.ps1` —— CLI（`validate` / `push` / `list`），stdout 输出 JSON。
- `eolink/setup.ps1` —— 交互式生成 `eolink/eolink.config.json`（含凭证，已 gitignore）。
- `eolink/specs/openapi.json` —— AI 生成的 OpenAPI 3.0 规格（累积写入，不入库）。

配置字段：`baseUrl`（SaaS 为 `https://api.eolink.com`）、`spaceId`、`projectId`、`eoSecretKey`、
`defaultGroup`、`projectDir`（用户的 Spring Boot 项目路径，只读引用）、`sqlCommentsPath`（可选）、`specPath`。
凭证也可用环境变量 `EOLINK_BASE_URL` / `EOLINK_SPACE_ID` / `EOLINK_PROJECT_ID` / `EOLINK_SECRET_KEY` 覆盖。

## /api 命令

当用户消息以 `/api` 开头时，执行接口推送流程，参数为接口描述（如「客户列表接口」「推送客户管理模块」）。
若没有本地配置或未安装步骤，先引导用户运行 `eolink/setup.ps1`。

1. **定位项目代码（当前项目）**：先运行
   `powershell -NoProfile -ExecutionPolicy Bypass -File eolink/eolink.ps1 project`
   拿到项目路径，规则为：
   - 优先：Codex 当前工作区（若含 `pom.xml`/`build.gradle` 且 `src/main/java`，即用户说的「当前项目」）；
   - 其次：`eolink/eolink.config.json` 中的 `projectDir`（可指向 `../crm-master` 等相对路径，相对于本仓库解析）；
   - 都没有 → 提示用户先运行 `eolink/setup.ps1` 设置 `projectDir`。
   然后根据描述定位该项目中的 Controller 方法。
2. **提取接口数据**：读取 Spring MVC 注解 `@RequestMapping` / `@GetMapping` / `@PostMapping` /
   `@PutMapping` / `@DeleteMapping` 得到方法与路径；`@PathVariable` / `@RequestParam` / `@RequestBody`
   得到路径参数、Query 参数与请求体；返回值类型得到响应字段。
3. **字段中文名**（按优先级）：
   1. Java 字段上方的 `// 中文` 行注释或 Javadoc `/** 中文 */`；
   2. 配置 `sqlCommentsPath` 指向的 SQL 文件中的列 `COMMENT`；
   3. 兜底使用字段名。
4. **生成/合并规格**：把本次接口写入 `eolink/specs/openapi.json`（OpenAPI 3.0，JSON）：
   - 接口名：Controller 方法注释或 `summary`；字段中文名写入每个字段的 `description`；
   - 分组：`tags` 取用户描述中的模块名，缺省用配置 `defaultGroup`；
   - 必须保留文件中其他已有接口，只新增/更新本次描述的接口。
5. **推送**：依次运行：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File eolink/eolink.ps1 validate -Spec eolink/specs/openapi.json
   powershell -NoProfile -ExecutionPolicy Bypass -File eolink/eolink.ps1 push -Spec eolink/specs/openapi.json
   ```
   `validate` 失败时按输出修正规格后再推送；`push` 失败时按 stderr 提示排查（鉴权/网络/字段），
   不要绕过校验直接调用 Eolink 其他接口。
6. **汇报**：向用户报告每个接口的 `created` / `updated` / `skipped` 与分组、路径，说明中文名来源。

## 约定

- 只允许用 `eolink.ps1` 与 Eolink 交互（幂等同步，按 方法+路径 匹配，默认不删除）。
- 不修改 `projectDir` 指向的用户项目代码；提取只读。
- 不要把 `eoSecretKey` 等凭证写进任何文件或输出；配置只存 `eolink/eolink.config.json`。
- 若 Eolink 报 401/403，提示用户检查 `eoSecretKey` 与空间/项目权限，而不是重试或绕过。
