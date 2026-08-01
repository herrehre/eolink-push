# eolink-push CLI

把 OpenAPI 3.0（JSON）规格幂等同步到 Eolink Apikit 项目。

## 命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File eolink\eolink.ps1 validate [-Spec <path>]
powershell -NoProfile -ExecutionPolicy Bypass -File eolink\eolink.ps1 push    [-Spec <path>] [-Project <id>] [-DryRun]
powershell -NoProfile -ExecutionPolicy Bypass -File eolink\eolink.ps1 list    [-Project <id>]
```

配置文件默认读取脚本同目录 `eolink.config.json`，凭证也可用环境变量覆盖：
`EOLINK_BASE_URL` / `EOLINK_SPACE_ID` / `EOLINK_PROJECT_ID` / `EOLINK_SECRET_KEY`。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 规格校验失败 |
| 2 | 鉴权/配置错误 |
| 3 | 网络或服务不可达 |
| 4 | 部分成功或功能暂不支持 |

stdout 输出 JSON（机器可读），提示信息走 stderr。

## 幂等语义

- 匹配键：`方法 + 路径`（忽略首尾 `/`、方法大小写）。
- 已存在 → 对比内容，有变化才更新；未变化 → 跳过。
- 不存在 → 创建；分组不存在时自动创建。
- 默认不删除任何文档。

## 暂不支持（v1）

- `-Clean`（按规格删除多余接口）：Eolink Open API 未公开删除端点，暂不实现。
- `-FullImport`（原生批量导入）：导入端点未公开，暂不实现。
- YAML 规格：仅支持 JSON。
