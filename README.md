# Watch AI

独立运行的 Apple Watch AI 客户端（watchOS 10+，无需 iPhone App），支持任意 OpenAI 兼容接口，内置 MiniMax 预设。

## 运行

```bash
xcodegen generate          # 修改 project.yml 后重新生成工程
open WatchAI.xcodeproj
```

在 Xcode 中为 `WatchAI` 和 `WatchAIWidgets` 两个 target 在 Signing & Capabilities 中选择你的 Team（真机需要），然后运行到手表或模拟器。
两个 target 共用 App Group `group.com.watchai.client`（数据目录放在其中，表盘小组件才能读取）；如需修改 Bundle ID，同时修改 `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`、App Group 以及 `Shared/AppGroup.swift`。

首次打开：首页「配置 API」→ 选择「MiniMax 国内」（`https://api.minimax.cn/v1`）或「MiniMax 国际」→ 填写 API Key → 测试连接。
iPhone 在附近时，可用 iPhone 键盘输入长 Key。

## 功能一览

| 模块 | 功能 |
|--|--|
| 对话 | SSE 流式输出、停止、重新生成、编辑重发、分叉对话、朗读、分享、消息收藏、首字延迟/耗时 |
| 小屏效率 | 首页一步提问（语音/涂写/键盘）、watchOS 11 双指互点手势发送、快捷回复、小屏简洁模式、回答从问题开始阅读、问答大纲跳转、字号调节 |
| 表盘 | 「问 AI」复杂功能一键新对话；「计时与待办」显示最先结束的倒计时或下一项待办（圆形 / 角落 / 行内 / 矩形，支持智能叠放），轻点直达对应页面 |
| 对话管理 | 置顶、收藏、归档/自动归档/批量归档、文件夹、标签、AI 智能整理、AI 标题、AI 摘要、全文搜索、导出 Markdown |
| 问答速览 | 全部问答卡片翻页（数码表冠）/ 列表模式、筛选、收藏 |
| 上下文 | 条数限制、按模型窗口自动截断、清除上下文分隔线、AI 压缩上下文、单条消息排除、上下文 tokens 估算与占用条 |
| 渲染 | 标题、列表、任务列表、表格（可切换卡片视图）、引用、代码块（语法高亮、折叠、全屏、换行/字号）、LaTeX 公式转 Unicode、图片、链接 |
| 网页 | 本地阅读模式抓取渲染网页（支持 GBK）、页内链接继续跳转、AI 生成的 HTML/Markdown/JSON 代码块本地预览、让 AI 总结网页 |
| 图片 | 从手表相册选图（最多 4 张）、自动压缩、视觉模型多模态输入 |
| Agent | 备忘录、待办（到期提醒）、倒计时（通知+震动），以及读取网页、检索历史对话、写入记忆等工具 |
| 反思记忆 | 全局开关、自动反思、AI 主动写入开关、注入条数、手动增删改/停用/置顶、AI 合并整理、反思日志 |
| API 管理 | 多服务商、Key 存钥匙串、获取模型列表、测试连接、模型单价/上下文/视觉/工具能力、额外请求参数 JSON、辅助模型 |
| 用量计费 | 按日/7 天/本月/全部统计、费用图表、按模型/用途/对话分布、缓存命中、月预算、汇率合并 |

## MiniMax 说明

- M2.x 的思考内容放在 `<think>` 中，客户端会折叠显示；服务商「思考回传」默认“仅工具调用轮”，按官方建议在工具调用中回传完整思考。
- MiniMax-M3 支持图片输入；可在模型编辑页一键添加 `{"thinking": {"type": "disabled"}}` 关闭思考以提速。
- 预设价格来自官方定价页（2026-10），如有变化请在模型编辑页修改。

## 目录结构

```
WatchAI/
  App/          入口、路由、全局状态
  Models/       数据模型与设置
  Storage/      JSON 文件存储、钥匙串、各类 Store
  Networking/   OpenAI 兼容客户端（流式 SSE、工具调用、用量解析）
  Engine/       对话引擎、上下文构建、工具、搜索、朗读
  Markdown/     Markdown 解析与渲染、语法高亮、代码块
  Web/          HTML → Markdown 阅读模式
  Views/        各功能界面
WatchAIWidgets/ 表盘小组件（WidgetKit），读取 App Group 中的 timers.json / todos.json
Shared/         App 与小组件共用（App Group 路径）
```

## 调试

Debug 构建支持启动参数驱动界面（Release 不包含）：

```bash
xcrun simctl launch <udid> com.watchai.client -WAIAsk "你好" -WAINoNotif
```

可用参数：`-WAIRoute qa|usage|memory|timers|…`、`-WAIChat <序号>`、`-WAIScroll top|<序号>`、`-WAISend <文本>`、`-WAIOptions`、`-WAIOutline`、`-WAIActions`、`-WAIWeb <url>`、`-WAIImage <路径>`、`-WAIReflect <序号>`、`-WAINoNotif`。
