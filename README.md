# JoolinkSDReplay — 乔安智联报警消息直达本地 SD 卡录像（TrollStore + dylib）

> 目标 App：乔安智联 Joolink 4.4.67（bundle id `com.qiaoan.qiaoanzhilian`，已砸壳）
> 注入方式：TrollStore + TrollFools 注入 dylib
> 当前版本：v1 诊断版 —— 先跑一轮拿运行时数据，确认设备对象来源后升级 v2 完整版
> 编译：推本仓库 GitHub Actions 自动编出 dylib（或 macOS 上跑 `bash build.sh`）

---

## 一、逆向结论（已确认，来自 ipa 静态逆向）

### 三层架构
| 层 | 说明 | 抓包可见性 |
|---|---|---|
| 云 API | `qacloudapi.jooancloud.com`，`Authorization: Bearer access_token` | HTTP 可抓 |
| 设备协议 | Breeze 私有 P2P SDK（TCP/UDP 穿透 NAT）+ 设备本地 goform + RTSP | 抓不到（私有长连接） |
| 推送 | MQTT + netty 长连接 | 部分可见 |

### 关键类与方法（ObjC runtime 已解析，9202 类全量）
| 用途 | 类 | 方法 |
|---|---|---|
| 报警详情页 | `JANewsWarnInfoDetailVC` | `clickCloudRecordAction:`（看录像按钮）、`handleJumpToOpenCloud`（开通引导） |
| 报警消息列表页 | `JANewDevWarnInfoListVC` | `loadDataFirstWithDate:showHud:isTableRefresh:finish:` |
| 报警模型 | `JAEMWarnInfoEntityModel` | `eventTimeUTC` / `event_time` / `event_date` / `event_type` / `event_file_url` / `eventPicThumbUrl` / `warn_record_type` / `cs_status` |
| 本地 SD 回放页 | `JANewSDPlayerViewController` | `seekTo:duration:`（按时间戳定位）、`respDeviceSdRecordList:type:`（SD 录像列表）、`currentEvent`/`currentTimeStamp`/`eventList` |
| 设备本地接口 | goform | `/goform/SingleHandlebyCommand` + `get_recordlist`（recordStartTime/EndTime）→ `rtsp_playback\|TimeStamp=%ld`，端口 `:9898` |

### 目标行为
报警消息 → 点图片 → 「看录像」→ 原逻辑弹「您尚未开通云存储…」引导
**改为**：直接进 `JANewSDPlayerViewController` 本地 SD 回放，带报警时间戳定位。外面网络可用（官方 Breeze P2P 穿透兜底）。

---

## 二、v1 诊断版做了什么

1. **纯 runtime swizzle**（不依赖 CydiaSubstrate，TrollStore 可直接注入）；
2. 拦截 `clickCloudRecordAction:` / `handleJumpToOpenCloud` —— 不再弹云存储引导；
3. 打印诊断日志到系统日志 + 沙盒 `Documents/jasdreplay.log`：
   - 报警模型全部关键字段（时间戳、类型、云状态、事件文件 URL）
   - `deviceId` / `devicePwd`
   - `viewModel` 及其设备类属性、self 上所有含 "Camera" 的属性
4. 尝试创建 `JANewSDPlayerViewController` 并 push。

## 三、编译

### 方式 A：GitHub Actions（推荐，推上去自动编译）
推 `main` 分支即触发本仓库 Actions → 最新运行 → Artifacts 下载 `JoolinkSDReplay-v1.0`（内含 dylib）。

### 方式 B：本地（macOS）
```bash
bash build.sh
# 或 Theos：
# export THEOS=/path/to/theos && make
```
产物：`JoolinkSDReplay-v1.0.dylib`

## 四、安装与测试

1. TrollStore 安装/重签乔安智联（App Store 版 4.4.67）；
2. TrollFools 注入 `JoolinkSDReplay-v1.0.dylib`；
3. 打开乔安智联 → 报警消息 → 点一条 → 点「看录像」；
4. 拿日志：
   - 手机装 Console App（Apple 开发者日志）过滤 `JASDReplay`；
   - 或「文件」App → 乔安智联 Documents → `jasdreplay.log` 发回。
5. 发回日志，确认 v2 需要：
   - ✅ 设备对象来源（viewModel 里的 Camera / 全局设备管理器）
   - ✅ 时间戳格式（eventTimeUTC 是秒还是毫秒、UTC 还是本地）
   - ✅ SDPlayer 的正确初始化方式（alloc/init 是否够）

## 五、v2 完整版计划（拿到 v1 日志后）

- [ ] 设备对象正确传入 `JANewSDPlayerViewController`；
- [ ] 报警时间戳 → `seekTo:duration:` 精确定位；
- [ ] 报警图片/事件列表正确展示；
- [ ] 多设备、4G/枪球机型适配；
- [ ] 自写 App 可行性报告（云 API + Breeze 穿透 + goform 协议三件套，另行输出）。

## 六、注意

- 只注入 `com.qiaoan.qiaoanzhilian`，不影响其他 App；
- 不修改官方 App 文件，TrollStore 沙盒注入，移除 dylib 即恢复；
- 仅供本人设备研究使用。
