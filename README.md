# API Ledger · 中转站账本与全局比价

**v1.1 · 公开版候选**

这是一个仅提供中转站账本、跨站模型定价比较与价格同步的单文件网页。`index.html` 仅包含这两个可用模块；「打开换算工具」按钮为未来独立开发功能的占位入口，不提供计算器页面或代码。

## 文件一览

| 文件 | 用途 |
| --- | --- |
| `index.html` | 中转站账本、余额与流水概览、模型定价、价格刷新、全局比价、Supabase 登录设置 |
| `sql/01_schema.sql` | 中转站专用空表、模型定价配置、RLS、站点采集自动登记 |
| `sql/02_rpc.sql` | 中转站专用增额、消费、模型定价和汇总 RPC；含服务端代理所需权限分离 |
| `functions/pricing-sync/index.ts` | Supabase Edge Function，验证账户与站点、读取公开报价、按比例转换人民币 |
| `functions/pricing-sync/normalize.mjs` | 公开 `/api/pricing` 价格解析、模型匹配、去重 |
| `LICENSE` | 适用于本仓库可授权原创文件的 MIT 许可 |

## 部署

1. 新建自己的空白 Supabase 项目，启用 Auth 邮箱登录。
2. 在 SQL Editor 依次执行 `sql/01_schema.sql`、`sql/02_rpc.sql`；两份 SQL 是空库建表脚本，不要覆盖现有生产数据库。
3. 在 Supabase Edge Functions 中创建 `pricing-sync`，同时上传 `index.ts` 和 `normalize.mjs`，保留 JWT 验证。
4. 将 `index.html` 部署到自己的静态托管或直接打开进行界面预览，在网页内配置自己的 Supabase URL 与 publishable/anon Key。**绝不能将 Secret / service_role Key 放入网页或仓库。**
5. 根据自身需要创建站点和模型系列配置；初始化后的表不含任何预设账户、余额、充值金额、站点 URL 或报价。站点根 URL 存入 `hsb_stations.price_base_url` 后可自动列入价格采集列表。
6. 可根据自己的实际充值金额/额度配置价格换算比例，并通过「更新价格」同步受支持的站点报价。

> 注意：当前是公开版候选，保留已实现功能；全新账户的冷部署流程仍需独立验收。使用自建数据库的默认空配置，不会自动展示作者的站点或报价。

## 功能边界与安全

- 后端仅包含中转站余额、消费/增额流水、模型价格、价格采集与动态配置的数据结构与 RPC。
- 网页只包含中转站账本和全局比价两个可用页面；占位按钮不会运行或加载额外组件。
- 中转站数据通过登录用户的 Supabase RLS 策略隔离，后台服务账号使用单独授权的 RPC。
- 支持配置 HTTP(S) 站点公开 `/api/pricing`；HTTP 链路未加密，请优先使用可信 HTTPS 站点。模型采集范围受自建库中启用的模型配置控制。
- 公开文件不含个人站点、账号、充值/消费记录和任何生产项目地址或密钥。
