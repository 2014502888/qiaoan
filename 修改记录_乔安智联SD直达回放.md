# 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像（JoolinkSDReplay）

## 一、项目背景与目标

用户使用乔安智联 App（iOS，版本 4.4.67），监控摄像头录像保存在**本地 SD 卡**（未开通云存储）。
报警消息详情页点「看录像」时，官方会弹「需开通云存储」引导，无法直接看本地录像。
用户手动进本地回放（设备列表 → 回放）虽然能看 SD 卡录像，但**无法直接定位到报警图片对应的时间点**，
只能手动拖回放条。

**目标**：报警消息点「看录像」→ 不弹云存储 → 直接进入官方本地 SD 回放界面，并**自动定位到报警时间点播放**
（画面时间与底部时间轴指示器一致，跨天场景自动选到报警日）。

**实现方式**：TrollStore + TrollFools 注入 dylib（纯 runtime hook + C IMP，零类依赖、零 Substrate），
GitHub Actions 编译产物 `JoolinkSDReplay-v1.32.dylib`。

## 二、最终成果（v1.32 定案）

| 项 | 说明 |
|---|---|
| 拦截点 | 报警详情页 `clickCloudRecordAction:`（官方点「看录像」按钮的原逻辑 = 弹云存储） |
| 目标界面 | 官方本地 SD 回放 `JANewRtcSDPlayViewController`（时间轴拖条/日历选日/SD 卡容量/变速，即手动进本地回放看到的界面） |
| 定位链路 | 提取报警秒时间戳 → viewDidAppear 后 3.0s：stopSDPlay（停官方自动流，单流）+ `switchToSDDay:dateString:`（官方选日入口，切报警日+加载该日事件，跨天修正）+ 重设 myCamera.sdSelectiontDay → 再 2.5s `startSDPlayWithSelectTimeStamp:`（定位报警秒）→ 再 1.5s `changeCurrentTimeStamp:`（拨时间轴指示器/时间标签到报警时间） |
| 设备获取 | 详情页 myCamera → JAGroupManager 按 eid 匹配 → JALiveManager → 导航栈回溯（多级兜底）；首次点击找不到设备时延迟 1.2s 重试一次 |
| 返回处理 | viewDidDisappear 后 0.3s stopSDPlay（返回后流量不再跑，下次进入不续播旧时间） |
| 兼容 | TrollStore 注入，无越狱依赖；App 升级需重新注入 |

**验收口径**：画面时间 = 报警时间 = 底部拖条指示器时间；跨天（过 12 点查昨天报警）自动切到报警日。

## 三、版本演进记录（git 提交线）

| 版本 | 提交 | 关键内容与结论 |
|---|---|---|
| v1.0 | be4fcbf | 拦截 clickCloudRecordAction: push JANewSDPlayerViewController → SIGABRT（设备 nil → MYOpenSDK 异常）；随后「弹云存储」反复出现 |
| v1.1 | a4e2e53 | setMyCamera:+KVC → 仍弹云存储 |
| v1.2 | 894db43 | 设备来源补全 → 仍弹云存储；**发现旧 dylib 未删、双层加载祸根** |
| v1.3 | 2202ffc→d911a98 | method_setImplementation 幂等 + 2s 防抖 + JALiveManager 类方法探测 → 跳转不闪但定位错/只能看实时 |
| v1.4 | 650090e | 时间戳改秒（优先 event_file_url 内嵌 `-(\d{10})\.`）→ 链路走通但回放闪 |
| v1.5 | 6ecde92 | 定位「闪」根因 = SD 事件列表从未拉取（sdSelectiontDay==0）；hook viewWillAppear 强制 pendingReload=报警日0点 |
| v1.6 | 7b37f2f | 诊断版：设备回传 21→347→211 条但报警模型字段读全 null（MYEventModel 字段不同） |
| v1.7 | e8a8c22 | resp 回调前强制设回报警日0点 → 仍「当前时间无录像」 |
| v1.8 | ab304bb | dump MYEventModel 真实字段；seekTo 前两道闸门：isEnterBackPlayer==0→跳过、detectType==-1→跳走 |
| v1.9 | 88be9d4 | setter 开闸失败（JALiveManager 无 sharedInstance 单例）；编译失败两次（ARC 禁裸指针 cast） |
| v1.10 | 9f5a5e7 | getter 层开闸：JASDPlayerActive=YES 期间强制 detectType→0 / isEnterBackPlayer→1；**seekTo:duration: 首次被官方消费**（sec=1792378567 duration=0）；画面仍无录像 |
| v1.11 | b52acfd→68f70c9 | JADayStartSec 修正 8 小时偏移；新增多处监控；**点看录像即崩/返回后再点崩**（IPS rawCodes=[1,32]、dispatch_after 补拉闭包 receiver=0x20）；v1.11.1 移除 setIsSDPlayer:YES |
| v1.12 | b623cc0→8cf823e | 移除 3/7/12s 补拉闭包；版本号统一。**用户测黑屏无反应**（v1.11+v1.12 双层 hook 历史假象，实为单份 dylib 命名误导） |
| v1.13 | 89f2058 | **建流修复**：官方链须先 startReplay 建流再 seekReplay 定位；hook p2p_starPlayBack 首次放行真实值走建流 → 用户测黑屏+闪退 |
| v1.14 | 0571e83 | **崩溃定案（IPS 124424 + 反汇编）**：respDeviceSDPlayerStatus:/respDeviceFirstFrameTimeStamp: 参数是**数值不是对象**，旧签名向 32 发消息 SIGSEGV；修正数值签名 + isStarBackPlayer 强制 0 建流全开 |
| v1.15 | 3e43372 | **跳错界面定案（用户两次质疑 + 类名清单 + 反汇编）**：官方本地 SD 回放 = JANewRtcSDPlayViewController（非一直 push 的 JANewSDPlayerViewController）；KVC 喂 myCamera + currentTimeStamp + sdSelectiontDay，viewDidAppear 后自动 startSDPlayWithSelectTimeStamp: → **全链路打通，用户实测成功** |
| v1.16 | 0f90f0c | **清理版**：删除 v1.5~v1.14 在旧 VC 上的全部残留（旧类生命周期/事件列表/seekTo/闸门 getter/p2p 建流/补拉闭包等 20+ 函数），只保留 RTC 链路 + 崩溃修复成果；1224 行 → 576 行 |
| v1.17 | a271e2c | **时间轴问题起点**：画面已定位但底部拖条停在最新。只读定案：`startSDPlayWithSelectTimeStamp:` → viewModel `startSDPlayShowWithSelectTimeStamp:` block 预检查 streamCtx 非空 —— 0.4s 调用时官方未就绪 → 定位不执行；延迟 0.4s→3.0s + 首帧确认 hook（后续证实官方不触发该回调，挂空） |
| v1.18 | 819863e | **时间轴组件定案**：时间轴 = JATimeLineView；官方唯一拨指示器 API = `[timeLineView changeCurrentTimeStamp:sec]`（0x1000ff834：setCurrentSec → adjustScrollViewOffsetAtCurrentSec → lastDisplaySec → 时间标签 setText）；`timeLine:scrollToTime:timeSecValue:` 是用户拖动回调不可程序化。实现 JATimeLineSyncToSec |
| v1.19 | c1bc03f | **相对秒修正**：changeCurrentTimeStamp: 入参是**当日相对秒（0~86399）不是绝对 Unix 秒** —— 绝对秒 1792407777 被官方按 秒/3600 显示成 497891:02:57；修正为 报警秒 − 报警日0点 |
| v1.20 | 93c1291 | **偶发播最新修复**：复用流时 startSDPlayWithSelectTimeStamp: 走 seekSDPlay（前置闸门 0x103429ee0 bit0 不过 → 跳过 seek → 播最新）；viewDidAppear 世代去重（g_rtcVdaGen）+ viewWillDisappear stopSDPlay |
| v1.21 | 830ad35 | **双流交替修复**：移除 viewWillDisappear 停流（pop 过渡期停流不干净 + 官方清理叠加 → 旧流残留+新流并存交替渲染），改 3.0s 定位前先 stopSDPlay 再立即 startSDPlay（单流+每次强制重建，绕开 seek 闸门） |
| v1.22 | 182fc11 | 跨天问题起点（过 12 点查昨天报警 → 顶部仍「今日录像」→ 拖条卡 00:00）：猜测 setCurrentSelectedSDDay+setCurrentDateStr+loadDataFirstWithDate → 实证 loadDataFirst... respondsToSelector=NO + 相对秒 clip 0 |
| v1.23 | 2060320 | KVC 取 viewModel 调用 + 相对秒按报警日 0 点纯计算 → 拖条时间对了但顶部仍「今日录像」 |
| v1.24 | 92db50a | 运行时枚举诊断 → 命中 VC 真实方法：`switchToSDDay:dateString:` / `reloadLatestEventList` / `setNeedRefreshSelectedDayWhenAppear:` |
| v1.25 | 6e6c10a | **跨天定案**：反汇编 0x100afb2e8 —— `switchToSDDay:dateString:` x2=报警日0点秒、x3=日期字符串，内部设选中日/日期串/时间区间并经 viewModel 加载该日事件+刷新时间轴+顶部日期 = 官方手动选日正规入口；替换全部猜测调用 → **用户实测「可以了」** |
| v1.26 | f2c5ec0 | **清理版**：用户要求清理无用/残留 + jasdreplay.log 日志代码。删除 JALog 日志系统（含写文件）、v1.17 首帧确认 hook（官方不触发挂空）、JADumpWarnInfo 诊断；777 行 → 481 行 |
| v1.27 | 96190eb | **当日/凌晨修复**：v1.26 后用户实测「当日看不了：00:21 跳转播实时 + 时间线 23:59:59」。根因 = JADayStartSec 旧公式（UTC当日0点−28800）在北京凌晨 0~8 点跨 UTC 日算错（10-21 00:21 → dayStart 错成 10-20 0点 → 相对秒 87660 clip 86399 + switchToSDDay 日期串与秒数不匹配播实时）；改 `sec−((sec+28800)%86400)`，三场景数值验证全对 |
| v1.28 | 2e6f52a | **首次点击不跳转 + 偶发无录像修复**：① camera 异步加载未就绪 → 首次点击找不到设备不跳转，加 1.2s 延迟重试；② switchToSDDay 切日后事件列表异步拉取，1.5s 不够偶发「当前时间无录像」→ 等待 2.5s 再 startSDPlay |
| v1.29 | 8428a6c | App 杀死重进后官方 viewDidLoad/viewDidAppear 自动恢复上次回放位置并自动播实时 → 三段乱跳；viewDidAppear 后 0.5s 预停官方自动流（实测三段仍可见，无效） |
| v1.30 | e4377c7→2be38ba | 预停提前到 viewDidLoad 后 0.3s（仍无效）；新增 viewDidDisappear 后 0.3s stopSDPlay（返回流量停 + 清活跃标记，此部分保留） |
| v1.31 | 0a448be | **源头拦截 startPlay（反汇编 0x100b074e0）**：定位完成前吞掉官方无参 startPlay → **实测画面实时、时间轴正确（定位被破坏）**：吞 startPlay 让官方 isEnterSDPlay 停在 NO，定位调用走 block 的「startSDPlay 无时间戳分支」→ 播最新实时、忽略报警时间戳 |
| **v1.32** | 7b23896→457a699 | **回退定案**：v1.29/30/31 的预停与 startPlay 拦截均与官方 isEnterSDPlay 状态机耦合，越拦越破坏定位。回退到 v1.28 验收链路（3.0s 停官方流 → switchToSDDay → 2.5s 定位 → 1.5s 时间轴），定位 100% 可靠；**保留 viewDidDisappear 0.3s 停流**（返回流量不再跑）。接受官方 viewDidLoad 自动流的短暂显示（读取进度/实时）观感，换取定位正确。code review：删除未使用变量 map、修正头部注释。565 行 |

## 四、逆向核心结论（技术要点）

1. **官方本地 SD 回放入口 = `JANewRtcSDPlayViewController`**：
   - 321+ 方法：timeLineView、switchToSDDay:dateString:、startSDPlayWithSelectTimeStamp:、
     startPlay、stopSDPlay、changeSDPlaySpeed:、seekTo:duration:、noneVideoViewIsShow:dayEnd: 等
   - viewDidLoad（0x100af4498）自动：`JADevicePlatform.sharedInstance setMyCamera:self.myCamera`、
     `setIsSDPlayer:YES`、创建 viewModel、setupUI —— 只需喂 myCamera + currentTimeStamp
   - myCamera 无公开 setter → 用 KVC `[vc setValue:cam forKey:@"myCamera"]`
2. **定位链**：`startSDPlayWithSelectTimeStamp:sec`（0x100b07b0c）→ viewModel
   `startSDPlayShowWithSelectTimeStamp:`（0x100b0c730）→ block 按 `isEnterSDPlay` 分流
   seekSDPlay（YES，带时间戳定位）/ startSDPlay（NO，无时间戳播最新）——
   **定位必须保证 isEnterSDPlay=YES**（官方 viewDidLoad 自动 startPlay 会置 YES；吞掉它则定位失效）
3. **时间轴同步链**：VC.timeLineView（JATimeLineView）→ `changeCurrentTimeStamp:相对秒`
   （0x1000ff834：setCurrentSec → adjustScrollViewOffsetAtCurrentSec → lastDisplaySec → 标签 setText）；
   入参是**当日相对秒（0~86399）**，不是绝对秒
4. **跨天选日**：官方唯一正规入口 `switchToSDDay:dateString:`
   （0x100afb2e8：x2=报警日0点秒 long long、x3=@"yyyy-MM-dd" 字符串），内部设选中日/日期串/
   时间区间并经 viewModel 加载该日事件 + 刷新时间轴 + 顶部日期；`setCurrentSelectedSDDay:` 是纯
   ivar setter 不刷新时间轴（废弃）；`loadDataFirstWithDate:`/`setCurrentDateStr:` 运行时无此方法（废弃）
5. **报警时间戳提取**：优先 event_file_url 文件名内嵌秒（`2310018773-1792397226.jpg`），
   兜底 eventTimeUTC / event_date+event_time 拼秒；单位必须**秒**（10 位）
6. **报警日 0 点（v1.27 定案）**：`sec − ((sec + 28800) % 86400)`（东八区北京时间 00:00）。
   ⚠ 旧公式「UTC当日0点−28800」在北京**凌晨 0~8 点**跨 UTC 日算错（会得前一日 0 点）：
   10-21 00:21 → 相对秒 87660 clip 23:59:59 + 日期串与秒数不匹配播实时
7. **崩溃教训（v1.14 定案）**：respDeviceSDPlayerStatus:/respDeviceFirstFrameTimeStamp:
   参数是数值（int 状态码/时间戳），hook 签名必须 (id, SEL, long long)，绝不能向参数发消息
8. **旧 VC（JANewSDPlayerViewController）是另一播放器**，界面与手动本地回放完全不同，
   在其上做的建流/开闸修复（v1.10~v1.14）全部无效 —— 黑屏根因是跳错界面
9. **返回停流（v1.30 保留）**：viewDidDisappear 后 0.3s stopSDPlay —— 官方 pop 返回不主动
   停流（后台一直拉流 + 持久化播放状态 → 下次进入先恢复上次时间续播）；用 viewDidDisappear
   避开 v1.21 viewWillDisappear 的 pop 过渡期停流冲突（双流交替）
10. **状态机耦合教训（v1.32 定案）**：官方「进入即播」（viewDidLoad 自动 startPlay 恢复上次
    位置→播实时）与 isEnterSDPlay 状态机绑死：提前 stopSDPlay 或吞 startPlay 会让
    isEnterSDPlay 停在 NO → 定位调用走无时间戳分支 → 画面实时、忽略报警时间戳。
    **不要拦截官方自动流，让它跑，3.0s 后再 stop + switchToSDDay + 定位**（v1.28 链路）

## 五、安装使用说明

1. iOS 设备安装 TrollStore（https://github.com/opa334/TrollStore）
2. 安装 TrollFools（TrollStore 应用商店内可搜到），用它注入 dylib 到乔安智联 App
3. 下载最新 `JoolinkSDReplay-v1.32.dylib`（GitHub Actions 产物），TrollFools 注入
4. **重要：TrollFools 里只保留最新一个 dylib，删除旧版**（旧版残留会污染行为/历史假象）
5. 打开乔安智联 → 报警消息详情 → 点「看录像」→ 直达本地 SD 回放并自动定位到报警时间点
6. v1.26 起**不再写日志**（jasdreplay.log 已移除）；问题反馈请描述界面现象（画面时间/
   拖条位置/是否实时/是否无录像），必要时截图
7. dylib 文件名可自行改成中文（如「乔安SD查看.dylib」），**先改名再注入**，不影响功能

## 六、交付文件清单

| 文件 | 说明 |
|---|---|
| Tweak.m | 注入逻辑源码（单文件，纯 C/ObjC runtime hook，565 行） |
| .github/workflows/build.yml | GitHub Actions 编译配置（xcrun clang 出 dylib，产物带版本号防覆盖） |
| 修改记录_乔安智联SD直达回放.txt / .md | 本记录（v1.0~v1.32 完整演进） |
| JoolinkSDReplay-v1.32.dylib | 安装包（GitHub Actions 产物，仓库 Actions Artifacts 下载） |

仓库：https://github.com/2014502888/qiaoan （公开）

---

## 七、v2.0 云回放式「格子」页面（2026-11-12）

### 背景结论（拆解真机后修正）
云回放与卡回放**是同一份数据**：都是「按天的事件列表（MYEventModel）+ 从事件秒起播放」。
云版只是把列表渲染成 3 列、用抓拍图当封面、点开播固定 35 秒；卡回放给一根时间轴让用户自己拖。
所以复刻它的「效果」不需要云，也不需要另找数据源 —— 用 SD 的事件列表 + 按段播放即可。
35 秒是云切片的长度，不是录像属性；我们这边长度可自定（默认 35s）。

### 本版做了什么
| 项 | 内容 |
|---|---|
| 入口 | 官方本地回放页（`JANewRtcSDPlayViewController`）右上角新增「格子」按钮，**不替换官方任何按钮**；点击 push 自绘格子页 |
| 格子页 | 自绘 `JAGridReplayViewController`（UICollectionView）：3 列、卡片 16:9、图下 `HH:mm:ss`、按「日期」分组头、滑到底自动往前加载一天 |
| 数据层 | 造一个不显示的官方 dataVC，设 `myCamera.sdSelectiontDay = 某天0点` → 官方 viewModel 拉该日事件 → 运行时在 VC/ivm 里定位事件数组（`JAGridFindEvents`：先试 eventList/events/viewModel 等键，再深度 ≤4 扫 ivar） |
| 字段 | 封面 = `event_file_url`（抓拍图）；时间 = 文件名内嵌 10 位秒（复用 `JABuildTimestamp`） |
| 播放 | 复用 v1.28 定位链路：设 `g_rtcTargetSec` + `g_activeSDPlayer` → push 官方 RTC 播放器 → 其 `viewDidAppear` 3.0s 后自动 stop/切日/定位/拨时间轴，**这一段完全未改** |
| 连播 | 定位 3.0s + 播 35s ≈ 38s 后自动 `pop` 回格子页并播下一格；导航栏「连播 开/关」可关；到列表尾部自动加载更早一天 |
| 流量 | 借用的 dataVC 取完列表即 `stopSDPlay` 并释放，避免后台白跑流 |
| 诊断 | 三天都没有事件时，把 dataVC 内部结构（各数组条数 + 元素类名 + ivar 名）打到屏幕上，截图即可定位字段路径 |

### 新增/改动文件
- `Tweak.m`：新增 v2.0 模块（事件识别/数组查找/探针/图片缓存/单元格/格子页/入口 hook）约 600 行；
  `JAHook` 增加 `viewWillAppear:`（用 `class_addMethod` 只挂本类，避免污染 UIViewController）与 `ja_openGrid:`。
- `.github/workflows/build.yml`、`build.sh`：产物版本号 v1.32 → **v2.0**。

### 真机待确认（按顺序）
1. 格子页能否列出事件（**3.2s / 6.2s 两次抓取**是否够官方拉完该日列表）。
2. 事件数组的真实路径（若探针打出结构，按 `[N] 类名 keys=...` 那几行把路径固化进 `JAGridFindEvents` 的键列表即可，不用改其它代码）。
3. 38s 连播时序是否合适（定位慢的时候可能还没播满就被切；调 `openPlayerAtIndex:` 里的 38.0）。
4. 封面图并发（当前走 `NSURLSession sharedSession` 默认 6 并发，单日 300+ 条时滚动是否卡）。

### 测试路径
乔安智联 → 设备 → 本地回放（进入 `JANewRtcSDPlayViewController`）→ 右上角「格子」→ 看到 3 列卡片 → 点任意卡片 → 定位到该秒并播放 → 38s 后自动回格子页并播下一格。