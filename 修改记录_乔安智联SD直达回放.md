# 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像（JoolinkSDReplay）

## 一、项目背景与目标

用户使用乔安智联 App（iOS，版本 4.4.67），监控摄像头录像保存在**本地 SD 卡**（未开通云存储）。
报警消息详情页点「看录像」时，官方会弹「需开通云存储」引导，无法直接看本地录像。
用户手动进本地回放（设备列表 → 回放）虽然能看 SD 卡录像，但**无法直接定位到报警图片对应的时间点**，
只能手动拖回放条。

**目标**：报警消息点「看录像」→ 不弹云存储 → 直接进入官方本地 SD 回放界面，并**自动定位到报警时间点播放**。

**实现方式**：TrollStore + TrollFools 注入 dylib（纯 runtime hook + C IMP，零类依赖、零 Substrate），
GitHub Actions 编译产物 `JoolinkSDReplay-v1.16.dylib`。

## 二、最终成果（v1.16 清理版）

| 项 | 说明 |
|---|---|
| 拦截点 | 报警详情页 `clickCloudRecordAction:`（官方点「看录像」按钮的原逻辑 = 弹云存储） |
| 目标界面 | 官方本地 SD 回放 `JANewRtcSDPlayViewController`（时间轴拖条/日历选日/SD 卡容量/变速/录音，即手动进本地回放看到的界面） |
| 定位方式 | 从报警图片 URL 提取报警秒时间戳 → viewDidAppear 后自动调官方 `startSDPlayWithSelectTimeStamp:` → 官方建流播放并定位到报警时间点 |
| 设备获取 | 详情页 myCamera → JAGroupManager 按 eid 匹配 → JALiveManager → 导航栈回溯（多级兜底） |
| 兼容 | TrollStore 注入，无越狱依赖；App 升级需重新注入 |

**实测（v1.15，jasdreplay (8).log）**：连续 6 次点「看录像」全部成功 —— 时间戳全部秒级提取、
push RTC 播放器、viewDidAppear 后自动 `startSDPlayWithSelectTimeStamp:` 报警秒；
两台设备（WY5NT5B3ANSDAGV1111A / NBDEWTHYAZ6YG1R7111A）均正常直达。

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
| **v1.16** | 本次 | **清理版**：删除 v1.5~v1.14 在旧 VC 上的全部残留（旧类生命周期/事件列表/seekTo/闸门 getter/p2p 建流/补拉闭包等 20+ 函数），只保留 RTC 链路 + 崩溃修复成果；代码 1224 行 → 576 行 |

## 四、逆向核心结论（技术要点）

1. **官方本地 SD 回放入口 = `JANewRtcSDPlayViewController`**：
   - 321 个方法：timeLineView、calendarPopViewHelper、switchToSDDay:dateString:、getSDCapcity、
     startSDPlayWithSelectTimeStamp:、startPlay/pausePlay/changeSDPlaySpeed:、
     respDeviceSDPlayerStatus:、seekTo:duration:、noneVideoViewIsShow:dayEnd: 等
   - viewDidLoad（0x100af4498）自动：`JADevicePlatform.sharedInstance setMyCamera:self.myCamera`、
     `setIsSDPlayer:YES`、创建 viewModel、setupUI —— **只需喂 myCamera + currentTimeStamp**
   - myCamera 无公开 setter → 用 KVC `[vc setValue:cam forKey:@"myCamera"]`
2. **自动定位链**：`startSDPlayWithSelectTimeStamp:sec` → viewModel `startSDPlayShowWithSelectTimeStamp:sec`
   → 官方建流播放并定位（0x100b07b0c / stub 0x103562680 反汇编定案）
3. **报警时间戳提取**：优先 event_file_url 文件名内嵌秒（`2310018773-1792397226.jpg`），
   兜底 event_date+event_time 拼秒；单位必须**秒**（10 位），传毫秒会导致无法定位
4. **报警日 0 点**：`(ts - ts%86400) - 28800`（北京 00:00 = UTC 0 点 - 8 小时），
   喂给 myCamera.sdSelectiontDay → 官方 setupData 选中报警日并加载当日事件列表
5. **崩溃教训（v1.14 定案）**：respDeviceSDPlayerStatus:/respDeviceFirstFrameTimeStamp:
   参数是数值（int 状态码/时间戳），hook 签名必须 (id, SEL, long long)，绝不能向参数发消息
6. **旧 VC（JANewSDPlayerViewController）是另一播放器**，界面与手动本地回放完全不同，
   在其上做的建流/开闸修复（v1.10~v1.14）全部无效 —— 黑屏根因是跳错界面

## 五、安装使用说明

1. iOS 设备安装 TrollStore（https://github.com/opa334/TrollStore）
2. 安装 TrollFools（TrollStore 应用商店内可搜到），用它注入 dylib 到乔安智联 App
3. 下载最新 `JoolinkSDReplay-v1.16.dylib`（GitHub Actions 产物），TrollFools 注入
4. **重要：TrollFools 里只保留最新一个 dylib，删除旧版**（旧版残留会污染日志/历史假象）
5. 打开乔安智联 → 报警消息详情 → 点「看录像」→ 直达本地 SD 回放并自动定位到报警时间点
6. 排障：日志在 App 沙盒 Documents/jasdreplay.log，可用 TrollStore 的文件管理器导出
   （文件共享开启后也可通过爱思助手/文件 App 查看）

## 六、交付文件清单

| 文件 | 说明 |
|---|---|
| Tweak.m | 注入逻辑源码（单文件，纯 C/ObjC runtime hook） |
| .github/workflows/build.yml | GitHub Actions 编译配置（xcrun clang 出 dylib，产物带版本号防覆盖） |
| 修改记录_乔安智联SD直达回放.txt / .md | 本记录 |
| JoolinkSDReplay-v1.16.dylib | 安装包（GitHub Actions 产物，仓库 Releases/Artifacts 下载） |

仓库：https://github.com/2014502888/qiaoan （公开）
