// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.26（清理版）：移除日志系统（jasdreplay.log）、v1.17 首帧确认 hook
// （respDeviceFirstFrameTimeStamp: 官方链不触发，挂空无用）、JADumpWarnInfo 诊断。
// v1.27：修正 JADayStartSec 公式 —— 旧实现"UTC当日0点-28800"在北京凌晨 0~8 点
//   （UTC 前一日 16~24 点）跨 UTC 日算错 → 10-21 00:21 报警 dayStart 错成 10-20
//   0点 → 相对秒 87660 clip 23:59:59 + switchToSDDay 日期串与秒数不匹配播实时。
//   改为 sec-((sec+28800)%86400)（v1.19 兜底式，正确统一处理凌晨与晚上）。
// v1.28：① camera 可能异步加载未就绪 → 首次点击"不跳转"，加 1.2s 延迟重试一次；
//   ② switchToSDDay 后事件列表异步拉取，等待 1.5s→2.5s 减少偶发"当前时间无录像"。
// v1.29：App 杀死重进后官方 viewDidLoad/viewDidAppear 自动恢复上次回放位置并自动播
//   实时 → 三段乱跳（上次时间→实时→定位）。viewDidAppear 后 0.5s 先 stopSDPlay
//   停官方自动流，再走 3.0s 定位链路。
// v1.30：① 预停提前到 viewDidLoad 后 0.3s（官方在 viewDidLoad 阶段即恢复上次位置并
//   开播渲染，0.5s 预停太晚，三段切换仍可见）→ 压到不可见；
//   ② 返回停流：viewDidDisappear 后 0.3s stopSDPlay（官方 pop 返回不主动停流，后台
//   一直拉流 + 持久化播放状态 → 下次进入先恢复上次时间继续播）→ 清 g_activeSDPlayer。
//   用 viewDidDisappear 避开 v1.21 viewWillDisappear 的 pop 过渡期停流冲突（双流交替）。
// v1.31：源头拦截 —— hook 官方无参 startPlay（反汇编 0x100b074e0，"进入即播"自动流
//   入口：viewDidLoad/viewDidAppear 调它播上次位置/最新实时并显示读取进度）。定位
//   完成前吞掉该调用，官方根本不起自动流 → 三段切换从源头消除（反复 stopSDPlay
//   打不过官方自动重启/异步建流的问题不再存在）；定位发出 2s 后放行。
// v1.32（回退定案）：v1.29/30/31 的预停与 startPlay 拦截均与官方 isEnterSDPlay 状态机
//   耦合 —— 提前 stop 或吞 startPlay 会让官方 isEnterSDPlay 停在 NO，定位调用
//   startSDPlayWithSelectTimeStamp: 走 block 的"startSDPlay 无时间戳分支" → 画面实时、
//   忽略报警时间戳（时间轴对、画面不对）。回退到 v1.28 验收链路（3.0s 停官方流 →
//   switchToSDDay → 2.5s 定位 → 1.5s 时间轴），定位 100% 可靠；官方 viewDidLoad 自动流
//   的短暂显示（读取进度/实时）为官方固有行为，接受三段观感，换取定位正确。
//   保留 viewDidDisappear 0.3s 停流（返回流量不再跑，v1.30，无副作用）。
// v2.0（云回放式格子页）：在官方本地回放页右上角加「格子」入口，进入自绘 3 列栅格回放页
//   —— 按天分组、抓拍图当封面、精确到秒，点卡片直接 push 官方 RTC 播放器定位到该秒，
//   35 秒后自动 pop 回来并播下一格（连播可关）。
//   数据层不自己拼接口：造一个不显示的官方 JANewRtcSDPlayViewController（dataVC），
//   把 myCamera.sdSelectiontDay 设成某天 0 点 → 官方 viewModel 拉该日事件 →
//   运行时在 VC/ivm 里找「事件数组」（JAGridFindEvents），取 event_file_url 当封面
//   + 文件名内嵌秒当时间（复用 JABuildTimestamp）。找不到列表时把结构打到屏幕上供截图诊断。
// 保留完整功能链路（v1.15~v1.25 全部修复）：
//   点「看录像」→ 不再弹云存储 → push JANewRtcSDPlayViewController（官方本地 SD 回放）
//   → viewDidAppear 后 3.0s：stopSDPlay（停官方自动流，单流）+
//   switchToSDDay:dateString:（官方选日入口，切到报警日并加载其事件，跨天修正）
//   + 重设 myCamera.sdSelectiontDay=报警日0点 → 再 2.5s startSDPlayWithSelectTimeStamp:
//   （定位报警秒）→ 再 1.5s JATimeLineSyncToSec（拨时间轴指示器/时间标签到报警时间）。
//
// 关键定案（git 提交记录含完整历史）：
//   v1.15：官方本地 SD 回放界面 = JANewRtcSDPlayViewController（时间轴/日历选日/
//           SD 卡检测/变速；用户手动进本地回放看到的就是它）。之前 push 的
//           JANewSDPlayerViewController 是另一播放器 → 界面不同 → 黑屏根因。
//   v1.17：startSDPlayWithSelectTimeStamp: 调用延迟 0.4s→3.0s（官方未就绪时
//           block 预检查失败 → 定位不执行 → 播最新）。
//   v1.18：时间轴指示器唯一更新入口 = JATimeLineView changeCurrentTimeStamp:
//           （0x1000ff834），主动拨动。
//   v1.19：changeCurrentTimeStamp: 入参是当日相对秒（0~86399），不是绝对秒
//           （绝对秒 1792407777 → 官方显示 497891:02:57）。
//   v1.20：viewDidAppear 世代去重（官方可能多次触发 → 只保留最后一次定位）。
//   v1.21：移除 viewWillDisappear stopSDPlay（pop 过渡期停流不干净 → 双流交替
//           渲染），改 3.0s 定位前先 stopSDPlay 再立即建流（单流+每次强制重建）。
//   v1.25：跨天修正定案 —— 官方选日正规入口 switchToSDDay:dateString:
//           （反汇编 0x100afb2e8：x2=报警日0点秒、x3=日期字符串，内部设选中日/
//           日期串/时间区间并经 viewModel 转发加载该日事件+刷新时间轴+顶部日期）。
//           替代 v1.22~v1.24 的 setCurrentSelectedSDDay:/setCurrentDateStr:/
//           loadDataFirstWithDate: 猜测组合（其中 loadDataFirstWithDate: 在 VC 与
//           viewModel 上运行时均无该方法）。
//   v1.26：清理（本版）。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------- KVC 工具 ----------

static id JAVal(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static void JASet(id obj, NSString *key, id val) {
    if (!obj || !val) return;
    @try { [obj setValue:val forKey:key]; }
    @catch (NSException *e) {}
}

static UIViewController *JATopVC(void) {
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    return vc;
}

// ---------- camera（设备对象 MyCamera）获取 ----------

static id JAGroupManagerShared(void) {
    Class cls = NSClassFromString(@"JAGroupManager");
    if (!cls) return nil;
    NSArray *names = @[@"shared", @"sharedInstance", @"shareManager",
                       @"defaultManager", @"getInstance", @"sharedManager",
                       @"defaultInstance", @"shareInstance", @"manager"];
    for (NSString *sn in names) {
        SEL s = NSSelectorFromString(sn);
        if (class_respondsToSelector(cls, s)) {
            id obj = ((id(*)(id, SEL))objc_msgSend)((id)cls, s);
            if (obj) return obj;
        }
    }
    return nil;
}

// eid / uid 归一化比较（NSNumber / NSString 兼容）
static NSString *JANormId(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSNumber.class]) {
        return [v stringValue];
    }
    if ([v isKindOfClass:NSString.class]) {
        return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return [v description];
}

// 从 JAGroupManager 按报警模型 eid 匹配设备 MyCamera
static id JAFindCameraFromGroupManager(id warn, NSString **src) {
    id gm = JAGroupManagerShared();
    if (!gm) return nil;

    NSString *eid = JANormId(JAVal(warn, @"eid"));

    // 1) getMyCameraWithUid:eid 直查（myCameraMap[eid]）
    if (eid) {
        id cam = nil;
        @try {
            cam = [gm performSelector:NSSelectorFromString(@"getMyCameraWithUid:")
                           withObject:JAVal(warn, @"eid")];
        } @catch (NSException *e) {}
        if (cam) {
            *src = [NSString stringWithFormat:@"JAGroupManager.getMyCameraWithUid(eid=%@)", eid];
            return cam;
        }
    }

    // 2) 遍历 getAllMyCamera 比对 uid
    id all = nil;
    @try {
        all = [gm performSelector:NSSelectorFromString(@"getAllMyCamera")];
    } @catch (NSException *e) {}
    if ([all isKindOfClass:NSArray.class]) {
        NSUInteger n = [all count];
        for (NSUInteger i = 0; i < n; i++) {
            id cam = [all objectAtIndex:i];
            NSString *uid = JANormId(JAVal(cam, @"uid"));
            if (eid && uid && [uid isEqualToString:eid]) {
                *src = [NSString stringWithFormat:@"getAllMyCamera uid==eid(%@)", eid];
                return cam;
            }
        }
    }
    return nil;
}

// 多级获取设备对象：详情页官方属性 → JAGroupManager 按 eid → JALiveManager → 导航栈
static id JAFindCamera(UIViewController *detailVC, id warn, NSString **src) {
    // a. 详情页官方属性 myCamera（父类 JABasicViewController 普通属性）
    id cam = JAVal(detailVC, @"myCamera");
    if (cam) {
        *src = @"detailVC.myCamera";
        return cam;
    }

    // b. JAGroupManager 按 eid 匹配设备列表（AI 报警场景主路径）
    cam = JAFindCameraFromGroupManager(warn, src);
    if (cam) {
        *src = [NSString stringWithFormat:@"%@ (+%@)", *src, @"JAGroupManager"];
        return cam;
    }

    // c. JALiveManager 单例（最近直播/回放设备）
    Class lmCls = NSClassFromString(@"JALiveManager");
    if (lmCls) {
        id lm = JAVal(lmCls, @"sharedInstance");
        if (lm) {
            cam = JAVal(lm, @"myCamera");
            if (cam) {
                *src = @"JALiveManager.sharedInstance.myCamera";
                return cam;
            }
        }
    }

    // d. 导航栈回溯
    UINavigationController *nav = detailVC.navigationController;
    for (UIViewController *v in nav.viewControllers) {
        id c = JAVal(v, @"myCamera");
        if (c) {
            *src = [NSString stringWithFormat:@"navStack.%@.myCamera", NSStringFromClass(v.class)];
            return c;
        }
    }

    return nil;
}

// ---------- 时间戳 ----------

// 报警事件时间戳：秒（NSNumber）
// 优先级：① event_file_url 文件名内嵌秒（服务器权威，如 -1792304458.jpg）
//         ② eventTimeUTC（字符串直接取秒，NSNumber 原样）
//         ③ event_date + event_time 拼本地秒
static NSNumber *JABuildTimestamp(id warn) {
    // ① event_file_url 文件名内嵌秒：xxx/2310111541-1792304458.jpg
    id url = JAVal(warn, @"event_file_url");
    if ([url isKindOfClass:NSString.class]) {
        NSString *u = url;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"-(\\d{10})\\."
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:u options:0
                                                   range:NSMakeRange(0, u.length)];
        if (m && m.numberOfRanges > 1) {
            NSString *sec = [u substringWithRange:[m rangeAtIndex:1]];
            return @(sec.longLongValue);
        }
    }
    // ② eventTimeUTC
    id t = JAVal(warn, @"eventTimeUTC");
    if (t) {
        if ([t isKindOfClass:NSNumber.class]) {
            return t; // 原样（秒）
        }
        if ([t isKindOfClass:NSString.class]) {
            return @((long long)[t doubleValue]); // 秒字符串（不再 ×1000）
        }
        return nil;
    }
    // ③ event_date + event_time 拼秒（本地时区）
    NSString *d = JAVal(warn, @"event_date");
    NSString *tm = JAVal(warn, @"event_time");
    if (d.length && tm.length) {
        NSString *s = [NSString stringWithFormat:@"%@ %@", d, tm];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        fmt.timeZone = [NSTimeZone localTimeZone];
        NSDate *date = [fmt dateFromString:s];
        if (date) {
            return @((long long)[date timeIntervalSince1970]);
        }
    }
    return nil;
}

// 从秒级时间戳算"报警日 0 点秒"（本地时区语义 = 北京时间 00:00）
// 正确公式：sec - ((sec + 28800) % 86400)（东八区，正确处理北京凌晨 0~8 点）。
// ⚠ 不能按"UTC 当日 0 点 - 28800"算：北京凌晨 0~8 点 = UTC 前一日 16~24 点，
//   会跨 UTC 日 → 得出前一日北京 0 点（v1.26 实测 bug：10-21 00:21 报警 →
//   dayStart 错成 10-20 0点 → 相对秒 87660 → clip 23:59:59；switchToSDDay 日期串
//   与秒数不匹配 → 定位失败播实时）。晚上时段（北京日==UTC 日）旧公式碰巧正确，
//   所以 v1.25 测 10-19 23:13 未暴露。
// 例：1792513260（北京 10-21 00:21）→ (1792513260+28800)%86400=1260 →
//     1792513260-1260 = 1792512000（北京 10-21 00:00）
static long long JADayStartSec(NSNumber *ts) {
    if (!ts) return 0;
    long long v = ts.longLongValue;
    if (v >= 1000000000LL && v < 10000000000LL) {
        return v - ((v + 28800LL) % 86400LL);
    }
    return 0;
}

// ---------- 核心：打开官方本地 SD 回放并定位 ----------

// 前置声明（实现位于下方 hook 区，JATryOpenSDReplay 需提前引用）
static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved);
static void ja_rtc_viewDidAppear(id self, SEL _cmd);
static void ja_rtc_viewDidDisappear(id self, SEL _cmd);
static void JATimeLineSyncToSec(id sdVC, long long sec);

// v1.15：当前活跃 RTC SD 播放器指针（纯 C 比较守卫，不向对象发消息）
static id g_activeSDPlayer = nil;
static BOOL g_rtcHooked = NO;        // JANewRtcSDPlayViewController hook 已装
static IMP g_orig_rtc_vda = NULL;    // 原 viewDidAppear: IMP
static IMP g_orig_rtc_vdd = NULL;    // 原 viewDidDisappear: IMP（v1.30 返回停流）
static long long g_rtcTargetSec = 0; // 报警时间戳（秒），viewDidAppear 后自动定位播放
// v1.20：viewDidAppear 世代去重（官方可能多次触发 → 只保留最后一次的 3.0s 定位）
static unsigned long long g_rtcVdaGen = 0;

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    // 目标界面 = 官方本地 SD 回放 JANewRtcSDPlayViewController（RTC 完整播放器，
    // 时间轴/日历/SD 卡检测/播放控制；用户手动进本地回放看到的就是它）。
    Class cls = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!cls) return;
    // RTC hooks 补装（类晚加载/轮询错过场景兜底）
    if (!g_rtcHooked) {
        JASetImp(cls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
        JASetImp(cls, @selector(viewDidDisappear:), (IMP)ja_rtc_viewDidDisappear, &g_orig_rtc_vdd);
        g_rtcHooked = YES;
    }
    id vc = [[cls alloc] init];

    // 1) myCamera 用 KVC（RTC 版无 setMyCamera: 公开方法）。
    // 官方 viewDidLoad 会自己读 self.myCamera → setMyCamera: 到 JADevicePlatform.sharedInstance
    //（反汇编 0x100af461c 定案），这里只需把 camera 挂到 VC 上。
    @try {
        [vc setValue:cam forKey:@"myCamera"];
    } @catch (NSException *e) {}

    // 2) 事件与时间戳
    if (warn) {
        JASet(vc, @"currentEvent", warn);
        NSNumber *ts = JABuildTimestamp(warn);
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        // 校验秒范围：10 位秒级（1.0e9 ~ 9.9e9），防止再传毫秒
        long long tv = ts ? ts.longLongValue : 0;
        // 记录报警时间戳（秒），RTC viewDidAppear 后自动 startSDPlayWithSelectTimeStamp:
        if (tv >= 1000000000LL && tv < 10000000000LL) g_rtcTargetSec = tv;
        // 预设设备 SD 选中日期 = 报警日 0 点秒 —— RTC setupData（0x100af6104）会
        // 读 myCamera.sdSelectiontDay → 加载该日事件列表
        long long dayStart = JADayStartSec(ts);
        if (dayStart > 0 && cam) {
            JASet(cam, @"sdSelectiontDay", @(dayStart));
        }
    }

    // 3) push
    UINavigationController *nav = detailVC.navigationController;
    if (!nav) nav = JATopVC().navigationController;
    if (nav) {
        g_activeSDPlayer = vc;  // 登记当前活跃 RTC SD 播放器（viewDidAppear hook 守卫用）
        [nav pushViewController:vc animated:YES];
        // RTC 版是官方完整播放器，官方链自己建流 → 不做任何状态强制
    } else {
        [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:vc animated:YES completion:nil];
    }
}

// ---------- hook 实现（C IMP，无类依赖） ----------

static IMP g_orig_clickCloudRecordAction = NULL;
static IMP g_orig_handleJumpToOpenCloud = NULL;

// v1.15 核心：JANewRtcSDPlayViewController viewDidAppear（官方本地 SD 回放界面）
// 官方 viewDidLoad/setupData 已自动：setMyCamera 到 sharedInstance、setIsSDPlayer:YES、
// 建 viewModel、按 myCamera.sdSelectiontDay 设选中日、加载事件列表。
// 本 hook：官方 viewDidAppear 完成后，延迟 3.0s 调 startSDPlayWithSelectTimeStamp:
//（报警时间戳）→ viewModel startSDPlayShowWithSelectTimeStamp: → block 执行体
//（isEnterSDPlay ? seekSDPlayWithSelectTimeStamp : startSDPlayWithSelectTimeStamp）
// → 官方建流/定位到报警时间。
// v1.17：延迟 0.4s→3.0s（反汇编 block 执行体 0x100b0c9cc 预检查 streamCtx/
// isSeekingPlay，0.4s 时官方未就绪 → 预检查失败 → 定位不执行 → 播最新）。
// v1.18：时间轴指示器唯一更新入口 = JATimeLineView changeCurrentTimeStamp:
//（0x1000ff834），播放定位后主动拨动。
// v1.32：移除 v1.29 0.5s 预停 / v1.30 viewDidLoad 0.3s 预停 / v1.31 startPlay 拦截
// —— 官方 viewDidLoad 自动播（上次位置→实时）与 isEnterSDPlay 状态机耦合，提前
// stop 或吞 startPlay 会打断官方播放状态（isEnterSDPlay 停在 NO → 定位调用走
// startSDPlay 无时间戳分支 → 画面实时、忽略报警时间戳）。回退到 v1.28 验收链路：
// 3.0s stopSDPlay（停官方自动流）→ switchToSDDay 切报警日 → 2.5s 定位 → 1.5s 时间轴。
// 官方自动流的短暂显示（读取进度/实时）是官方 viewDidLoad 固有行为，定位成功后
// 画面即切到报警时间；三段"乱跳"观感保留，换取定位 100% 可靠。
static void ja_rtc_viewDidAppear(id self, SEL _cmd) {
    if (g_orig_rtc_vda) ((void(*)(id, SEL))g_orig_rtc_vda)(self, _cmd);
    if (self != g_activeSDPlayer) return;
    long long sec = g_rtcTargetSec;
    if (sec < 1000000000LL) return;
    // v1.20：世代去重 —— 官方可能多次触发 viewDidAppear，只保留最后一次生效
    unsigned long long myGen = ++g_rtcVdaGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
        // v1.21：先停官方 viewDidLoad 自动起的流（避免双流并存交替渲染），再建定位流。
        // 每次进入都"停旧→建新"，绕开复用流上 seekSDPlay 前置闸门（0x103429ee0 bit0）
        // 导致的"第二次起偶发定位不生效/播最新"。
        SEL st = NSSelectorFromString(@"stopSDPlay");
        if ([self respondsToSelector:st]) {
            ((void(*)(id, SEL))objc_msgSend)(self, st);
        }
        // v1.25 定案（v1.24 运行时枚举 + 反汇编 0x100afb2e8）：官方"选日期"正规入口 =
        // switchToSDDay:dateString:（x2=报警日0点秒 long long，x3=日期字符串）。
        // 内部：算时间范围 → 设选中日/日期串/时间区间 → 经 viewModel 转发触发
        // 加载该日事件 + 刷新时间轴 + 顶部日期显示（跨天修正：官方默认选中"今日"，
        // 过了 12 点打开昨天报警会卡 00:00、看不到昨天进度条）。
        long long dayStart = JADayStartSec(@(sec));
        if (dayStart < 1000000000LL) dayStart = sec - ((sec + 28800LL) % 86400LL);
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd";
        NSString *ds = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:sec]];
        SEL sw = NSSelectorFromString(@"switchToSDDay:dateString:");
        if ([self respondsToSelector:sw]) {
            ((void(*)(id, SEL, long long, id))objc_msgSend)(self, sw, dayStart, ds);
        }
        // 官方 viewDidLoad 会把 myCamera.sdSelectiontDay 覆盖成"今日0点"（跨天场景 = 10-20），
        // 时间轴/相对秒若读它就会算错。这里重设回报警日0点。
        @try {
            [self setValue:@(dayStart) forKeyPath:@"myCamera.sdSelectiontDay"];
        } @catch (NSException *e) {}
        // 事件列表加载是异步的（网络拉取），等 2.5s 后再建流定位。
        // v1.28：1.5s→2.5s —— switchToSDDay 切日（尤其跨天场景 10-19）后官方要重新
        // 网络拉取该日事件列表，网络稍慢时 1.5s 内列表未到 → startSDPlay 定位时官方
        // 找不到该时间点录像 → 偶发"当前时间无录像"。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
            SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
            if ([self respondsToSelector:s]) {
                ((void(*)(id, SEL, long long))objc_msgSend)(self, s, sec);
            }
            // v1.18：播放定位已发出，再等 1.5s 拨时间轴指示器到报警时间点
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
                JATimeLineSyncToSec(self, sec);
            });
        });
    });
}

// v1.18：把官方时间轴指示器/滚动位置/时间标签同步到指定秒。
// 链：VC.timeLineView（懒加载 getter，自动创建并初始化）→
//     [timeLineView changeCurrentTimeStamp:sec]（官方 API 0x1000ff834：
//     内部 setCurrentSec: + adjustScrollViewOffsetAtCurrentSec + setLastDisplaySec:）。
// v1.19 关键修正：changeCurrentTimeStamp: 的入参是「当日内的相对秒」（0~86399），
// 不是绝对 Unix 秒！绝对秒 1792407777 → 官方按 秒/3600 算小时 → 显示 497891:02:57。
// 修正：相对秒 = 报警秒 - 报警日0点（JADayStartSec 纯计算，跨天后官方会把
// myCamera.sdSelectiontDay 覆盖成今日0点，读 ivar 会算错 → 必须用计算值）。
static void JATimeLineSyncToSec(id sdVC, long long sec) {
    @autoreleasepool {
        long long dayStart = JADayStartSec(@(sec));
        if (dayStart < 1000000000LL) dayStart = sec - ((sec + 28800LL) % 86400LL);
        long long rel = sec - dayStart;   // 报警日相对秒 0~86399
        if (rel < 0) rel = 0;
        if (rel > 86399) rel = 86399;

        id tl = nil;
        @try { tl = [sdVC valueForKey:@"timeLineView"]; }
        @catch (NSException *e) { return; }
        if (!tl) return;
        SEL c = NSSelectorFromString(@"changeCurrentTimeStamp:");
        if ([tl respondsToSelector:c]) {
            ((void(*)(id, SEL, long long))objc_msgSend)(tl, c, rel);
        }
    }
}

// 防抖：同一详情页实例 2 秒内只 push 一次（官方可能触发两次点击事件 → 双 push 闪烁）
static void *g_lastDetailVC = NULL;
static NSTimeInterval g_lastPushTime = 0;

static BOOL JADebounce(UIViewController *detailVC) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ((__bridge void *)detailVC == g_lastDetailVC && (now - g_lastPushTime) < 2.0) {
        return YES;
    }
    return NO;
}

// 原 selector：clickCloudRecordAction:（点「看录像」按钮，官方原逻辑弹云存储）
// v1.28：camera 可能异步加载未就绪（详情页 myCamera 未挂/设备列表未拉到）→
// 首次点击找不到 camera 会"不跳转"，用户需再点一次。改为延迟 1.2s 重试一次，
// 仍找不到才恢复官方逻辑。
static void ja_clickCloudRecordAction(id self, SEL _cmd, id sender) {
    if (JADebounce(self)) return;
    NSString *src = nil;
    id warn = JAVal(self, @"warnInfoEntityModelEx");
    id cam = JAFindCamera(self, warn, &src);
    if (cam) {
        JATryOpenSDReplay(self, warn, cam);
        g_lastDetailVC = (__bridge void *)self;
        g_lastPushTime = [NSDate timeIntervalSinceReferenceDate];
        return;
    }
    // 设备对象未就绪：延迟 1.2s 重试（设备列表/详情页数据异步加载完成后再找一次）
    __weak id weakSelf = self;
    __weak id weakSender = sender;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (!strongSelf) return;
        if (JADebounce(strongSelf)) return;
        id warn2 = JAVal(strongSelf, @"warnInfoEntityModelEx");
        NSString *src2 = nil;
        id cam2 = JAFindCamera(strongSelf, warn2, &src2);
        if (cam2) {
            JATryOpenSDReplay(strongSelf, warn2, cam2);
            g_lastDetailVC = (__bridge void *)strongSelf;
            g_lastPushTime = [NSDate timeIntervalSinceReferenceDate];
        } else {
            // 仍找不到，恢复官方逻辑（保留云存储引导，防崩溃）
            id sender2 = weakSender;
            if (g_orig_clickCloudRecordAction) {
                ((void(*)(id, SEL, id))g_orig_clickCloudRecordAction)(strongSelf, _cmd, sender2);
            }
        }
    });
}

// 原 selector：handleJumpToOpenCloud —— 不再拦截，转发原实现
static void ja_handleJumpToOpenCloud(id self, SEL _cmd) {
    if (g_orig_handleJumpToOpenCloud) {
        ((void(*)(id, SEL))g_orig_handleJumpToOpenCloud)(self, _cmd);
    }
}

// v1.30：viewDidDisappear 后 0.3s 停流 —— 用户按返回时官方不主动停流，SD 回放流
// 继续在后台拉数据（状态栏流量一直跑），官方还会把"播放中"状态持久化，导致下次
// 进入先恢复上次时间继续播（秒数叠加）。用 viewDidDisappear（pop 动画结束后再停）
// 避开 v1.21 曾用的 viewWillDisappear（pop 过渡期停流不干净 + 官方清理叠加 → 旧流
// 残留与新流并存交替渲染）。停流后清活跃标记，阻断旧闭包继续执行。
static void ja_rtc_viewDidDisappear(id self, SEL _cmd) {
    if (g_orig_rtc_vdd) ((void(*)(id, SEL))g_orig_rtc_vdd)(self, _cmd);
    if (self != g_activeSDPlayer) return;
    g_activeSDPlayer = nil;  // 先清标记：后续 viewDidAppear/定位闭包不再执行
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SEL st = NSSelectorFromString(@"stopSDPlay");
        if ([self respondsToSelector:st]) {
            ((void(*)(id, SEL))objc_msgSend)(self, st);
        }
    });
}

// =========================================================
// v2.0：云回放式「格子」页面
//   3 列 · 按天分组 · 抓拍图当封面 · 精确到秒 · 点开即播 35 秒自动下一格
// 数据来源：借用官方 JANewRtcSDPlayViewController 的按天事件列表
//   （把 myCamera.sdSelectiontDay 设成某天 0 点，官方 viewModel 就会拉该日事件）
// 播放：完全复用 v1.28 定位链路（g_rtcTargetSec + g_activeSDPlayer + ja_rtc_viewDidAppear）
// =========================================================

static void ja_openGrid(id self, SEL _cmd);

// ---------- 时间/日期 ----------

static long long JAGridTodayStart(void) {
    return JADayStartSec(@((long long)[[NSDate date] timeIntervalSince1970]));
}

static NSString *JAGridDayText(long long dayStart) {
    static NSDateFormatter *df = nil;
    if (!df) {
        df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy年M月d日";
    }
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)dayStart]];
}

static NSString *JAGridTimeText(long long sec) {
    static NSDateFormatter *tf = nil;
    if (!tf) {
        tf = [[NSDateFormatter alloc] init];
        tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        tf.dateFormat = @"HH:mm:ss";
    }
    return [tf stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)sec]];
}

// ---------- 事件对象识别 / 数组查找 ----------

static BOOL JAGridIsJunk(id o) {
    if (!o) return YES;
    if ([o isKindOfClass:NSString.class]) return YES;
    if ([o isKindOfClass:NSNumber.class]) return YES;
    if ([o isKindOfClass:NSDate.class]) return YES;
    if ([o isKindOfClass:NSData.class]) return YES;
    if ([o isKindOfClass:UIImage.class]) return YES;
    if ([o isKindOfClass:UIColor.class]) return YES;
    if ([o isKindOfClass:UIFont.class]) return YES;
    if ([o isKindOfClass:UIView.class]) return YES;
    if ([o isKindOfClass:UIViewController.class]) return YES;
    if ([o isKindOfClass:NSNull.class]) return YES;
    return NO;
}

// 官方事件模型是 MYEventModel 对象（不是字典），所以不能只认字典键；
// 这里改成「打分」：数组元素只要有抓拍图字段 / 时间字段 / 类名带 Event 就是候选，
// 全树收集候选后取代分最高的那个（v2.1 修正：原来只认字典导致找不到列表）。
static NSString *JAGridImageURL(id ev);
static NSNumber *JAGridTimestamp(id ev);

static BOOL JAGridIsPlainJunk(id o) {
    if (!o) return YES;
    if ([o isKindOfClass:UIViewController.class]) return NO;
    return JAGridIsJunk(o);
}

static int JAGridScoreElement(id o) {
    if (!o) return -8;
    if ([o isKindOfClass:NSString.class] || [o isKindOfClass:NSNumber.class]) return -8;
    if ([o isKindOfClass:NSDate.class] || [o isKindOfClass:NSData.class]) return -8;
    int s = 0;
    if ([o isKindOfClass:NSDictionary.class]) {
        NSDictionary *d = (NSDictionary *)o;
        if (d[@"event_file_url"]) s += 6;
    }
    if (JAGridImageURL(o)) s += 6;
    if (JAGridTimestamp(o)) s += 2;
    NSString *cn = NSStringFromClass(object_getClass(o));
    if (cn.length) {
        if ([cn rangeOfString:@"event" options:NSCaseInsensitiveSearch].location != NSNotFound) s += 2;
        if ([cn rangeOfString:@"warn" options:NSCaseInsensitiveSearch].location != NSNotFound) s += 1;
        if ([cn rangeOfString:@"record" options:NSCaseInsensitiveSearch].location != NSNotFound) s += 2;
    }
    return s;
}

static int JAGridScoreArray(NSArray *a) {
    if (!a || a.count == 0) return -100;
    int best = -100;
    NSUInteger n = MIN(a.count, (NSUInteger)4);
    for (NSUInteger i = 0; i < n; i++) {
        int s = JAGridScoreElement([a objectAtIndex:i]);
        if (s > best) best = s;
    }
    if (best < 3) return best;
    if (a.count == 1) best -= 1;
    return best;
}

static void JAGridCollect(id root, int depth, NSMutableSet *seen, NSMutableArray *cands) {
    if (!root || depth <= 0) return;
    if ([root isKindOfClass:NSArray.class]) {
        NSArray *a = (NSArray *)root;
        if (a.count == 0) return;
        int sc = JAGridScoreArray(a);
        if (sc >= 3) {
            [cands addObject:@[a, @(sc)]];
            return;                      // 已经是事件列表，不用再往下钻
        }
        NSUInteger lim = MIN(a.count, (NSUInteger)3);
        for (NSUInteger i = 0; i < lim; i++) {
            JAGridCollect([a objectAtIndex:i], depth - 1, seen, cands);
        }
        return;
    }
    if (JAGridIsPlainJunk(root)) return;
    NSValue *k = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:k]) return;
    [seen addObject:k];

    Class cls = object_getClass(root);
    int level = 0;
    while (cls && cls != [NSObject class] && level < 3) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *enc = ivars ? ivar_getTypeEncoding(ivars[i]) : NULL;
            if (!enc || enc[0] != '@') continue;   // 只读对象型 ivar
            id v = nil;
            @try { v = object_getIvar(root, ivars[i]); } @catch (NSException *e) { v = nil; }
            JAGridCollect(v, depth - 1, seen, cands);
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
        level++;
    }
}

// 在 VC（及其 viewModel/dataSource 等）里找出「事件模型数组」（打分取代分最高的）
static NSArray *JAGridFindEvents(id vc) {
    if (!vc) return nil;
    NSMutableArray *cands = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *keys = @[@"sdRecordFileArr", @"recordFileArr", @"recordFileList", @"sdRecordFileList",
                      @"recordFiles", @"fileArr", @"eventList", @"eventLists", @"events",
                      @"eventArray", @"eventModelList", @"dataArray", @"dataList", @"listArray",
                      @"records", @"recordList", @"warnList", @"warningList", @"currentEventList",
                      @"sdEventList", @"mEventList", @"allEvents", @"viewModel", @"mViewModel",
                      @"playerModel", @"sdModel", @"dataSource", @"adapter"];
    for (NSString *k in keys) {
        JAGridCollect(JAVal(vc, k), 4, seen, cands);
    }
    JAGridCollect(vc, 4, seen, cands);

    NSArray *best = nil;
    int bs = 2;                    // 阈值 3 分才认
    for (NSArray *pair in cands) {
        int sc = [(NSNumber *)pair[1] intValue];
        if (sc > bs) { bs = sc; best = (NSArray *)pair[0]; }
    }
    return best;
}

// ---------- 诊断（找不到列表时给出一份结构快照，自动复制到剪贴板） ----------

static NSString *JAGridIvarNames(id obj, int maxLevel, NSUInteger maxCount) {
    if (!obj) return @"-";
    NSMutableArray *ks = [NSMutableArray array];
    Class cls = object_getClass(obj);
    int level = 0;
    while (cls && cls != [NSObject class] && level < maxLevel && ks.count < maxCount) {
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n && ks.count < maxCount; i++) {
            const char *nm = ivar_getName(iv[i]);
            if (!nm) continue;
            NSString *s = [NSString stringWithUTF8String:nm];
            if (s) [ks addObject:s];
        }
        if (iv) free(iv);
        cls = class_getSuperclass(cls);
        level++;
    }
    return [ks componentsJoinedByString:@","];
}

// 只列和「事件/列表/天」有关的 selector，用来确认官方真实的取数方法名
static NSString *JAGridMethodNames(id obj) {
    if (!obj) return @"-";
    NSMutableArray *ms = [NSMutableArray array];
    Class cls = object_getClass(obj);
    int level = 0;
    while (cls && cls != [NSObject class] && level < 3 && ms.count < 70) {
        unsigned int n = 0;
        Method *m = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n && ms.count < 70; i++) {
            NSString *sel = NSStringFromSelector(method_getName(m[i]));
            NSString *low = sel.lowercaseString;
            if ([low rangeOfString:@"event"].location != NSNotFound ||
                [low rangeOfString:@"record"].location != NSNotFound ||
                [low rangeOfString:@"sdd"].location != NSNotFound ||
                [low rangeOfString:@"day"].location != NSNotFound ||
                [low rangeOfString:@"list"].location != NSNotFound ||
                [low rangeOfString:@"warn"].location != NSNotFound) {
                [ms addObject:sel];
            }
        }
        if (m) free(m);
        cls = class_getSuperclass(cls);
        level++;
    }
    return [ms componentsJoinedByString:@" "];
}

// 把所有「数组」列出来（条数:元素类名），看数据到底装在哪一层
static void JAGridArrayWalk(id root, int depth, NSMutableSet *seen, NSMutableArray *out) {
    if (!root || depth <= 0 || out.count >= 40) return;
    if ([root isKindOfClass:NSArray.class]) {
        NSArray *a = (NSArray *)root;
        NSString *cn = a.count ? NSStringFromClass(object_getClass([a objectAtIndex:0])) : @"-";
        [out addObject:[NSString stringWithFormat:@"%lu:%@", (unsigned long)a.count, cn]];
        return;
    }
    if (JAGridIsPlainJunk(root)) return;
    NSValue *k = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:k]) return;
    [seen addObject:k];
    Class cls = object_getClass(root);
    int level = 0;
    while (cls && cls != [NSObject class] && level < 3 && out.count < 40) {
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        for (unsigned int i = 0; i < n && out.count < 40; i++) {
            const char *enc = ivars ? ivar_getTypeEncoding(ivars[i]) : NULL;
            if (!enc || enc[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(root, ivars[i]); } @catch (NSException *e) { v = nil; }
            JAGridArrayWalk(v, depth - 1, seen, out);
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
        level++;
    }
}

static NSString *JAGridArraysText(id root, int depth, NSMutableSet *seen, NSMutableArray *out) {
    JAGridArrayWalk(root, depth, seen, out);
    return out.count ? [out componentsJoinedByString:@" | "] : @"-";
}

static NSString *JAGridProbeText(id vc) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"VC=%@\n", NSStringFromClass(object_getClass(vc))];
    [s appendFormat:@"IVAR=%@\n", JAGridIvarNames(vc, 3, 30)];
    [s appendFormat:@"SEL=%@\n", JAGridMethodNames(vc)];

    // 直接看几个关键属性的值/条数（最有用：能立刻判断「列表有没有被拉回来」）
    for (NSString *k in @[@"sdRecordFileArr", @"currentSelectedSDDay", @"currentSDDay",
                         @"isLoadCacheEventList", @"isReLoadNormalEventList",
                         @"currentEvent", @"todayMaxTimestamp"]) {
        id v = JAVal(vc, k);
        if (!v) continue;
        if ([v isKindOfClass:NSArray.class]) {
            NSArray *a = (NSArray *)v;
            NSString *cn = a.count ? NSStringFromClass(object_getClass([a objectAtIndex:0])) : @"-";
            [s appendFormat:@"KVC %@ count=%lu first=%@\n", k, (unsigned long)a.count, cn];
            if (a.count) {
                NSString *d = [[a objectAtIndex:0] description];
                if (d.length > 200) d = [d substringToIndex:200];
                [s appendFormat:@"   %@\n", d];
            }
        } else {
            NSString *d = [v description];
            if (d.length > 120) d = [d substringToIndex:120];
            [s appendFormat:@"KVC %@ = %@\n", k, d];
        }
    }

    NSMutableArray *cands = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    JAGridCollect(vc, 4, seen, cands);
    if (cands.count == 0) {
        [s appendString:@"-- 全树没有候选数组 --\n"];
    }
    for (NSUInteger i = 0; i < cands.count && i < 8; i++) {
        NSArray *pair = (NSArray *)cands[i];
        NSArray *a = (NSArray *)pair[0];
        int sc = [(NSNumber *)pair[1] intValue];
        NSString *cn = a.count ? NSStringFromClass(object_getClass([a objectAtIndex:0])) : @"-";
        [s appendFormat:@"#[%lu score=%d] %@\n", (unsigned long)a.count, sc, cn];
        if (a.count) {
            NSString *desc = [[a objectAtIndex:0] description];
            if (desc.length > 240) desc = [desc substringToIndex:240];
            [s appendFormat:@"  %@\n", desc];
            [s appendFormat:@"  ivi=%@\n", JAGridIvarNames([a objectAtIndex:0], 2, 18)];
        }
    }

    // 单独把「所有数组」列一遍（哪怕没到 3 分，也能看出到底哪层在装数据）
    NSMutableArray *loose = [NSMutableArray array];
    NSMutableSet *seen2 = [NSMutableSet set];
    [s appendFormat:@"ARR=%@\n", JAGridArraysText(vc, 4, seen2, loose)];
    return s;
}

// ---------- 事件字段读取 ----------

static NSString *JAGridImageURL(id ev) {
    NSArray *keys = @[@"event_file_url", @"event_pic_url", @"event_pic", @"picUrl",
                      @"pic_url", @"event_img", @"imageUrl", @"snapUrl", @"eventImagePath",
                      @"recordFileUrl", @"record_file_url", @"fileUrl", @"file_url",
                      @"coverUrl", @"thumbUrl", @"imgUrl", @"eventPicUrl"];
    for (NSString *k in keys) {
        id v = JAVal(ev, k);
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length] > 8) return (NSString *)v;
    }
    return nil;
}

// 时间字段兜底：SD 录像模型不一定叫 event_*，这里把常见命名都试一遍，
// 能取到 10 位秒就返回（文件名内嵌秒优先，其次数值字段/时间字符串）
static NSNumber *JAGridTimestamp(id ev) {
    NSNumber *t = JABuildTimestamp(ev);
    if (t) return t;
    NSArray *numKeys = @[@"startTime", @"startTimestamp", @"beginTime", @"recordStartTime",
                         @"createTime", @"time", @"timestamp", @"eventTime"];
    for (NSString *k in numKeys) {
        id v = JAVal(ev, k);
        if ([v isKindOfClass:NSNumber.class]) {
            long long n = [(NSNumber *)v longLongValue];
            if (n > 1000000000000LL) n /= 1000;      // 毫秒转秒
            if (n >= 1000000000LL && n < 10000000000LL) return @(n);
        }
        if ([v isKindOfClass:NSString.class]) {
            NSString *s = (NSString *)v;
            if (s.length >= 10) {
                long long n = s.longLongValue;
                if (n > 1000000000000LL) n /= 1000;
                if (n >= 1000000000LL && n < 10000000000LL) return @(n);
            }
        }
    }
    NSArray *strKeys = @[@"fileName", @"name", @"file_name", @"recordFileUrl", @"fileUrl"];
    for (NSString *k in strKeys) {
        id v = JAVal(ev, k);
        if (![v isKindOfClass:NSString.class]) continue;
        NSString *s = (NSString *)v;
        if (s.length < 10) continue;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(\\d{10})"
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (m && m.numberOfRanges > 1) {
            NSString *sec = [s substringWithRange:[m rangeAtIndex:1]];
            long long n = sec.longLongValue;
            if (n >= 1000000000LL && n < 10000000000LL) return @(n);
        }
    }
    return nil;
}

// 按运行时类型编码调「单参数」方法：参数可能是 long long，也可能是对象，猜错会崩
static BOOL JAGridCallOneArg(id obj, NSString *selName, long long num, id objArg, BOOL forceObject) {
    if (!obj || !selName.length) return NO;
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    char t = 0;
    if (enc) {
        const char *p = enc;
        while (*p && *p != ':') p++;
        if (*p == ':') {
            p++;
            while (*p >= '0' && *p <= '9') p++;
            t = *p;
        }
    }
    if (t == '@' || forceObject) {
        if (!objArg) return NO;
        ((void (*)(id, SEL, id))objc_msgSend)(obj, sel, objArg);
    } else {
        ((void (*)(id, SEL, long long))objc_msgSend)(obj, sel, num);
    }
    return YES;
}

// ---------- 图片缓存（内存 + 并发限流） ----------

@interface JAGridImageCache : NSObject
@property (nonatomic, strong) NSCache *mem;
+ (instancetype)shared;
- (UIImage *)imageForKey:(NSString *)key;
- (void)loadURL:(NSString *)url completion:(void (^)(UIImage *img, NSString *key))cb;
@end

@implementation JAGridImageCache
+ (instancetype)shared {
    static JAGridImageCache *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JAGridImageCache alloc] init]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _mem = [[NSCache alloc] init];
        _mem.countLimit = 160;
    }
    return self;
}
- (UIImage *)imageForKey:(NSString *)key {
    if (!key) return nil;
    return [self.mem objectForKey:key];
}
- (void)loadURL:(NSString *)url completion:(void (^)(UIImage *, NSString *))cb {
    if (!url.length || ![url hasPrefix:@"http"]) { if (cb) cb(nil, url); return; }
    UIImage *c = [self.mem objectForKey:url];
    if (c) { if (cb) cb(c, url); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { if (cb) cb(nil, url); return; }
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            UIImage *img = nil;
            if (data) { @autoreleasepool { img = [UIImage imageWithData:data]; } }
            if (img) [self.mem setObject:img forKey:url];
            dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(img, url); });
        }];
    [t resume];
}
@end

// ---------- 单元格 ----------

@interface JAGridCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *timeLab;
@property (nonatomic, strong) UIView *playDot;
@property (nonatomic, copy) NSString *imgURL;
- (void)setImageURL:(NSString *)url;
@end

@implementation JAGridCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        _thumb.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        _thumb.layer.cornerRadius = 8;
        [self.contentView addSubview:_thumb];

        _playDot = [[UIView alloc] initWithFrame:CGRectZero];
        _playDot.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        _playDot.layer.cornerRadius = 9;
        _playDot.clipsToBounds = YES;
        [self.contentView addSubview:_playDot];

        UILabel *tri = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
        tri.text = @"▶";
        tri.textColor = [UIColor whiteColor];
        tri.font = [UIFont systemFontOfSize:8];
        tri.textAlignment = NSTextAlignmentCenter;
        [_playDot addSubview:tri];

        _timeLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _timeLab.font = [UIFont systemFontOfSize:12];
        _timeLab.textColor = [UIColor colorWithWhite:0.40 alpha:1.0];
        [self.contentView addSubview:_timeLab];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat thumbH = w * 152.0 / 236.0;
    self.thumb.frame = CGRectMake(0, 0, w, thumbH);
    self.playDot.frame = CGRectMake(w - 24, thumbH - 24, 18, 18);
    self.timeLab.frame = CGRectMake(0, thumbH + 5, w, h - thumbH - 5);
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.imgURL = nil;
    self.thumb.image = nil;
    self.timeLab.text = nil;
}
- (void)setImageURL:(NSString *)url {
    self.imgURL = [url copy];
    UIImage *cached = [[JAGridImageCache shared] imageForKey:url];
    if (cached) { self.thumb.image = cached; return; }
    self.thumb.image = nil;
    if (!url) return;
    __weak typeof(self) ws = self;
    NSString *key = [url copy];
    [[JAGridImageCache shared] loadURL:url completion:^(UIImage *img, NSString *k) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        if (key && [s.imgURL isEqualToString:key]) s.thumb.image = img;
    }];
}
@end

// ---------- 日期分组头 ----------

@interface JAGridHeader : UICollectionReusableView
@property (nonatomic, strong) UILabel *lab;
@end

@implementation JAGridHeader
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lab = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, frame.size.width - 32, 26)];
        _lab.font = [UIFont boldSystemFontOfSize:19];
        _lab.textColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        _lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:_lab];
    }
    return self;
}
@end

// ---------- 格子页本体 ----------

@interface JAGridReplayViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) id myCamera;
@property (nonatomic, strong) NSMutableArray *days;    // @[@{@"day":NSNumber, @"items":NSArray}]
@property (nonatomic, strong) NSMutableArray *flat;    // @[@{@"ev":id, @"sec":NSNumber, @"day":NSNumber}]
@property (nonatomic, strong) UICollectionView *cv;
@property (nonatomic, strong) UILabel *hintLab;
@property (nonatomic, strong) UITextView *diag;          // 诊断快照（可选可滚，自动复制）
@property (nonatomic, strong) UIBarButtonItem *autoItem;
@property (nonatomic, strong) NSMutableArray *retained; // 借用中的官方 dataVC（保活）
@property (nonatomic, assign) long long nextDay;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL autoNext;
@property (nonatomic, assign) NSInteger emptyStreak;
@property (nonatomic, assign) BOOL gaveUp;
@property (nonatomic, assign) NSInteger playIndex;
@property (nonatomic, strong) id playingVC;
@property (nonatomic, copy) NSString *lastProbe;
@end

@implementation JAGridReplayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"回放";
    self.days = [NSMutableArray array];
    self.flat = [NSMutableArray array];
    self.retained = [NSMutableArray array];
    self.autoNext = YES;
    self.playIndex = -1;
    self.emptyStreak = 0;
    self.nextDay = JAGridTodayStart();

    self.autoItem = [[UIBarButtonItem alloc] initWithTitle:@"连播 开"
                                                    style:UIBarButtonItemStylePlain
                                                   target:self
                                                   action:@selector(toggleAutoNext)];
    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"复制"
                                                                style:UIBarButtonItemStylePlain
                                                               target:self
                                                               action:@selector(copyDiag)];
    self.navigationItem.rightBarButtonItems = @[copyItem, self.autoItem];

    UICollectionViewFlowLayout *lay = [[UICollectionViewFlowLayout alloc] init];
    lay.minimumInteritemSpacing = 9;
    lay.minimumLineSpacing = 11;
    lay.sectionInset = UIEdgeInsetsMake(0, 16, 16, 16);
    lay.headerReferenceSize = CGSizeMake(0, 38);

    self.cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:lay];
    self.cv.backgroundColor = [UIColor whiteColor];
    self.cv.alwaysBounceVertical = YES;
    self.cv.dataSource = self;
    self.cv.delegate = self;
    [self.cv registerClass:[JAGridCell class] forCellWithReuseIdentifier:@"cell"];
    [self.cv registerClass:[JAGridHeader class]
        forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
               withReuseIdentifier:@"head"];
    [self.view addSubview:self.cv];

    self.hintLab = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hintLab.numberOfLines = 0;
    self.hintLab.font = [UIFont systemFontOfSize:12];
    self.hintLab.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    self.hintLab.textAlignment = NSTextAlignmentLeft;
    [self.view addSubview:self.hintLab];
    self.hintLab.hidden = YES;

    self.diag = [[UITextView alloc] initWithFrame:CGRectZero];
    self.diag.editable = NO;
    self.diag.selectable = YES;
    self.diag.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.94];
    self.diag.textColor = [UIColor whiteColor];
    UIFont *mono = [UIFont fontWithName:@"Menlo" size:10];
    self.diag.font = mono ? mono : [UIFont systemFontOfSize:10];
    self.diag.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.diag.layer.cornerRadius = 8;
    self.diag.hidden = YES;
    [self.view addSubview:self.diag];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.cv.frame = self.view.bounds;
    CGFloat usable = self.view.bounds.size.width - 32 - 18;
    CGFloat itemW = floor(usable / 3.0);
    UICollectionViewFlowLayout *lay = (UICollectionViewFlowLayout *)self.cv.collectionViewLayout;
    lay.itemSize = CGSizeMake(itemW, itemW * 152.0 / 236.0 + 24);
    self.hintLab.frame = CGRectMake(20, 80, self.view.bounds.size.width - 40,
                                   self.view.bounds.size.height - 160);
    self.diag.frame = CGRectInset(self.view.bounds, 12, 12);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.myCamera) {
        self.hintLab.hidden = NO;
        self.hintLab.text = @"没拿到设备对象（myCamera 为空），格子页无法读取录像";
        return;
    }
    if (self.days.count == 0 && !self.gaveUp) {
        [self loadOneMoreDay];
    }
}

// ---------- 拉一天事件（借官方数据层） ----------

- (void)fetchDay:(long long)dayStart completion:(void (^)(NSArray *events))cb {
    Class rtc = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!rtc) { if (cb) cb(nil); return; }

    id dataVC = [[rtc alloc] init];
    @try { [dataVC setValue:self.myCamera forKey:@"myCamera"]; } @catch (NSException *e) {}
    @try { [self.myCamera setValue:@(dayStart) forKey:@"sdSelectiontDay"]; } @catch (NSException *e) {}

    // 关键（v2.1）：官方是在「页面出现之后」才去拉该日事件列表的。
    // 只 loadViewIfNeeded 的话 viewWillAppear/viewDidAppear 永远不来 → 列表永远空。
    // 这里把它塞成子控制器、视图挪到屏幕外并隐藏，让生命周期照常跑完。
    UIViewController *dvc = (UIViewController *)dataVC;
    @try {
        [self addChildViewController:dvc];
        dvc.view.frame = CGRectMake(-600, -600, 320, 568);
        dvc.view.hidden = YES;
        [self.view addSubview:dvc.view];
        [dvc didMoveToParentViewController:self];
    } @catch (NSException *e) {}

    [self.retained addObject:dataVC];
    while (self.retained.count > 4) [self.retained removeObjectAtIndex:0];

    // 关键（v2.3）：诊断显示列表存在（sdRecordFileArr / loadRecordListWithSelectiontDay:）
    // 但为空 —— 说明官方这页自己没去拉。这里主动触发：先设选中日，再调 v1.28 已验证
    // 的 switchToSDDay:dateString:（内部会转发触发该日事件列表加载），最后兜底直接调
    // loadRecordListWithSelectiontDay:（参数类型运行时判断，避免猜错崩溃）。
    @try { JASet(dataVC, @"currentSelectedSDDay", @(dayStart)); } @catch (NSException *e) {}
    NSDateFormatter *dfDay = [[NSDateFormatter alloc] init];
    dfDay.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dfDay.dateFormat = @"yyyy-MM-dd";
    NSString *dayStr = [dfDay stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)dayStart]];
    SEL swDay = NSSelectorFromString(@"switchToSDDay:dateString:");
    @try {
        if ([dvc respondsToSelector:swDay]) {
            ((void (*)(id, SEL, long long, id))objc_msgSend)(dvc, swDay, dayStart, dayStr);
        }
    } @catch (NSException *e) {}
    @try { JAGridCallOneArg(dvc, @"loadRecordListWithSelectiontDay:", dayStart, @(dayStart), NO); }
    @catch (NSException *e) {}

    [self gridTryFetch:dataVC attempt:0 completion:cb];
}

// 轮询 3 次（每次 3.2s）：官方列表是异步回来的，给足时间；都不行就把诊断快照留下
- (void)gridTryFetch:(id)dataVC attempt:(NSInteger)attempt completion:(void (^)(NSArray *events))cb {
    if (!dataVC) { if (cb) cb(nil); return; }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        NSArray *ev = JAGridFindEvents(dataVC);
        if (ev.count > 0) { [s gridStopDataVC:dataVC]; if (cb) cb(ev); return; }
        if (attempt + 1 < 3) {
            [s gridTryFetch:dataVC attempt:attempt + 1 completion:cb];
            return;
        }
        @try { s.lastProbe = JAGridProbeText(dataVC); } @catch (NSException *e) {}
        [s gridStopDataVC:dataVC];
        if (cb) cb(nil);
    });
}

// 借用的 dataVC 用完即停流（官方 viewDidLoad 可能自动起流，不停会白跑流量）
- (void)gridStopDataVC:(id)dataVC {
    if (!dataVC) return;
    SEL st = NSSelectorFromString(@"stopSDPlay");
    @try {
        if ([dataVC respondsToSelector:st]) {
            ((void (*)(id, SEL))objc_msgSend)(dataVC, st);
        }
    } @catch (NSException *e) {}
    // 从父控制器摘掉（否则每拉一天都会挂着一个隐藏播放页）
    UIViewController *dvc = (UIViewController *)dataVC;
    @try {
        [dvc willMoveToParentViewController:nil];
        [dvc.view removeFromSuperview];
        [dvc removeFromParentViewController];
    } @catch (NSException *e) {}
    @try { [self.retained removeObject:dataVC]; } @catch (NSException *e) {}
}

- (void)loadOneMoreDay {
    if (self.loading || !self.myCamera) return;
    if (self.nextDay <= 0) self.nextDay = JAGridTodayStart();
    long long day = self.nextDay;
    self.loading = YES;
    self.hintLab.hidden = NO;
    self.hintLab.text = @"正在读取该日录像…";

    __weak typeof(self) ws = self;
    [self fetchDay:day completion:^(NSArray *events) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        s.loading = NO;
        s.nextDay = day - 86400;

        if (events.count > 0) {
            s.emptyStreak = 0;
            [s appendDay:day events:events];
            s.hintLab.hidden = YES;
        } else {
            s.emptyStreak++;
            if (s.emptyStreak >= 3) {
                s.gaveUp = YES;
                if (s.lastProbe.length) {
                    [s showDiag:s.lastProbe];
                } else {
                    s.hintLab.hidden = NO;
                    s.hintLab.text = @"往前 3 天都没有录像（这三天没有事件记录）";
                }
            } else {
                [s loadOneMoreDay];
            }
        }
    }];
}

- (void)appendDay:(long long)day events:(NSArray *)events {
    NSMutableArray *items = [NSMutableArray array];
    for (id ev in events) {
        NSNumber *ts = JAGridTimestamp(ev);
        if (!ts) continue;
        long long sec = ts.longLongValue;
        if (sec < 1000000000LL || sec > 10000000000LL) continue;   // 只要 10 位秒
        [items addObject:@{@"ev": ev, @"sec": ts, @"day": @(day)}];
    }
    if (items.count == 0) return;
    [self.days addObject:@{@"day": @(day), @"items": items}];
    [self.flat addObjectsFromArray:items];
    [self.cv reloadData];
}

// ---------- 集合视图 ----------

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return (NSInteger)self.days.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.days.count) return 0;
    NSDictionary *d = self.days[section];
    NSArray *items = d[@"items"];
    return (NSInteger)items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    JAGridCell *c = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    if (ip.section < (NSInteger)self.days.count) {
        NSDictionary *dayDict = (NSDictionary *)self.days[ip.section];
        NSArray *items = (NSArray *)dayDict[@"items"];
        if (ip.item < (NSInteger)items.count) {
            NSDictionary *e = (NSDictionary *)items[ip.item];
            NSNumber *sec = (NSNumber *)e[@"sec"];
            c.timeLab.text = JAGridTimeText(sec.longLongValue);
            [c setImageURL:JAGridImageURL(e[@"ev"])];
        }
    }
    return c;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)ip {
    JAGridHeader *h = [collectionView dequeueReusableSupplementaryViewOfKind:kind
                                                          withReuseIdentifier:@"head"
                                                                 forIndexPath:ip];
    if (ip.section < (NSInteger)self.days.count) {
        NSDictionary *dayDict = (NSDictionary *)self.days[ip.section];
        NSNumber *day = (NSNumber *)dayDict[@"day"];
        h.lab.text = JAGridDayText(day.longLongValue);
    }
    return h;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView.contentSize.height < 1) return;
    if (scrollView.contentOffset.y + scrollView.bounds.size.height >
        scrollView.contentSize.height - 320) {
        [self loadOneMoreDay];
    }
}

// ---------- 点开播放 ----------

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [collectionView deselectItemAtIndexPath:ip animated:NO];
    if (ip.section >= (NSInteger)self.days.count) return;
    NSDictionary *dayDict = (NSDictionary *)self.days[ip.section];
    NSArray *items = (NSArray *)dayDict[@"items"];
    if (ip.item >= (NSInteger)items.count) return;
    NSDictionary *entry = (NSDictionary *)items[ip.item];
    NSInteger gi = [self flatIndexOfEntry:entry];
    if (gi < 0) return;
    [self openPlayerAtIndex:gi];
}

- (NSInteger)flatIndexOfEntry:(NSDictionary *)entry {
    NSNumber *sec = (NSNumber *)entry[@"sec"];
    for (NSInteger i = 0; i < (NSInteger)self.flat.count; i++) {
        NSDictionary *e = (NSDictionary *)self.flat[i];
        NSNumber *s2 = (NSNumber *)e[@"sec"];
        if ([s2 isEqualToNumber:sec]) return i;
    }
    return -1;
}

- (NSIndexPath *)indexPathForFlat:(NSInteger)index {
    NSInteger left = index;
    for (NSInteger s = 0; s < (NSInteger)self.days.count; s++) {
        NSDictionary *dayDict = (NSDictionary *)self.days[s];
        NSArray *items = (NSArray *)dayDict[@"items"];
        if (left < (NSInteger)items.count) return [NSIndexPath indexPathForItem:left inSection:s];
        left -= (NSInteger)items.count;
    }
    return nil;
}

- (void)openPlayerAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.flat.count) return;
    NSDictionary *entry = self.flat[index];
    long long sec = [(NSNumber *)entry[@"sec"] longLongValue];

    Class rtc = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!rtc) return;

    id vc = [[rtc alloc] init];
    @try { [vc setValue:self.myCamera forKey:@"myCamera"]; } @catch (NSException *e) {}
    JASet(vc, @"currentTimeStamp", @(sec));
    JASet(self.myCamera, @"sdSelectiontDay", @(JADayStartSec(@(sec))));

    // 复用 v1.28 定位链路：viewDidAppear 后 3.0s 自动定位到 g_rtcTargetSec
    g_rtcTargetSec = sec;
    g_activeSDPlayer = vc;
    self.playIndex = index;
    self.playingVC = vc;

    NSIndexPath *ip = [self indexPathForFlat:index];
    if (ip) [self.cv scrollToItemAtIndexPath:ip
                           atScrollPosition:UICollectionViewScrollPositionCenteredVertically
                                   animated:NO];

    UINavigationController *nav = self.navigationController;
    if (!nav) return;
    [nav pushViewController:vc animated:YES];

    // 定位 3.0s + 播 35s ≈ 38s 后自动跳下一格
    if (self.autoNext) {
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s) return;
            if (vc != g_activeSDPlayer) return;         // 用户已手动返回或切了别的
            if (nav.topViewController != vc) return;
            [nav popViewControllerAnimated:NO];
            if (index + 1 < (NSInteger)s.flat.count) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [s openPlayerAtIndex:index + 1];
                });
            } else {
                [s loadOneMoreDay];
            }
        });
    }
}

- (void)toggleAutoNext {
    self.autoNext = !self.autoNext;
    self.autoItem.title = self.autoNext ? @"连播 开" : @"连播 关";
}

// ---------- 诊断展示 ----------

- (void)showDiag:(NSString *)text {
    if (!text.length) return;
    self.diag.text = text;
    self.diag.hidden = NO;
    self.hintLab.hidden = YES;
    @try { [[UIPasteboard generalPasteboard] setString:text]; } @catch (NSException *e) {}
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"没读到该日事件列表"
                                                                message:@"诊断信息已自动复制到剪贴板，直接长按粘贴发我就行。也可以在这个黑框里上下滑动看。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    @try { [self presentViewController:ac animated:YES completion:nil]; } @catch (NSException *e) {}
}

- (void)copyDiag {
    NSString *t = self.diag.text;
    if (!t.length) return;
    @try { [[UIPasteboard generalPasteboard] setString:t]; } @catch (NSException *e) {}
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制"
                                                                message:@"诊断信息已在剪贴板，粘贴发我即可。"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    @try { [self presentViewController:ac animated:YES completion:nil]; } @catch (NSException *e) {}
}

@end

// 官方本地回放页右上角加一个「格子」入口（不替换官方任何按钮）
static IMP g_orig_rtc_vwa = NULL;

static void ja_rtc_viewWillAppear(id self, SEL _cmd) {
    if (g_orig_rtc_vwa) ((void (*)(id, SEL))g_orig_rtc_vwa)(self, _cmd);
    @try {
        UIViewController *vc = (UIViewController *)self;
        NSArray *items = vc.navigationItem.rightBarButtonItems;
        for (UIBarButtonItem *it in (items ? items : @[])) {
            if ([it.title isEqualToString:@"格子"]) return;
        }
        UIBarButtonItem *bi = [[UIBarButtonItem alloc] initWithTitle:@"格子"
                                                               style:UIBarButtonItemStylePlain
                                                              target:(id)self
                                                              action:@selector(ja_openGrid:)];
        NSMutableArray *arr = [NSMutableArray arrayWithArray:(items ? items : @[])];
        [arr insertObject:bi atIndex:0];
        vc.navigationItem.rightBarButtonItems = arr;
    } @catch (NSException *e) {}
}

// 打开格子页：沿用当前设备的 camera
static void ja_openGrid(id self, SEL _cmd) {
    id cam = JAVal(self, @"myCamera");
    if (!cam) {
        NSString *src = nil;
        cam = JAFindCamera((UIViewController *)self, nil, &src);
    }
    if (!cam) return;

    JAGridReplayViewController *grid = [[JAGridReplayViewController alloc] init];
    grid.myCamera = cam;
    UINavigationController *nav = [(UIViewController *)self navigationController];
    if (nav) {
        [nav pushViewController:grid animated:YES];
    } else {
        UINavigationController *n2 = [[UINavigationController alloc] initWithRootViewController:grid];
        [(UIViewController *)self presentViewController:n2 animated:YES completion:nil];
    }
}

// ---------- v2.2：首页设备卡片「云存储 / AI分析」中间插入「格子回放」入口 ----------
// 不去绑死某个类名：首页是设备卡片列表（每台一卡），卡片底部一行两个入口、中间空着。
// 这里扫可见视图里「云存储 / 云储存」和「AI分析」两个文字，同一行中间插自己的入口；
// 点击时从这张卡片自身的模型对象里解析 camera（uid → JAGroupManager.getMyCameraWithUid:），
// 所以 5 台设备各进各的，不会串台。

static const NSInteger JAGridEntryTag = 0x1A63;

@interface JAGridEntryHub : NSObject
+ (instancetype)shared;
- (void)tick;
- (void)onTapEntry:(UITapGestureRecognizer *)g;
@end

static id JAGridAsCamera(id o) {
    if (!o) return nil;
    if ([o respondsToSelector:NSSelectorFromString(@"sdSelectiontDay")]) return o;
    if ([o respondsToSelector:NSSelectorFromString(@"setSdSelectiontDay:")]) return o;
    return nil;
}

static NSString *JAGridViewText(UIView *v) {
    if ([v isKindOfClass:UILabel.class]) return ((UILabel *)v).text;
    if ([v isKindOfClass:UIButton.class]) return [((UIButton *)v) currentTitle];
    return nil;
}

static BOOL JAGridIsCloudText(NSString *t) {
    if (!t.length) return NO;
    return ([t rangeOfString:@"云存储"].location != NSNotFound ||
            [t rangeOfString:@"云储存"].location != NSNotFound);
}

static BOOL JAGridIsAIText(NSString *t) {
    if (!t.length) return NO;
    return ([t rangeOfString:@"AI分析"].location != NSNotFound ||
            [t rangeOfString:@"AI 分析"].location != NSNotFound ||
            [t rangeOfString:@"Ai分析"].location != NSNotFound);
}

static void JAGridCollectTexts(UIView *v, int depth, NSMutableArray *out, NSInteger *budget) {
    if (!v || depth > 8 || *budget <= 0) return;
    (*budget)--;
    NSString *t = JAGridViewText(v);
    if (t.length && t.length <= 24 && (JAGridIsCloudText(t) || JAGridIsAIText(t))) {
        [out addObject:v];
    }
    for (UIView *s in v.subviews) {
        JAGridCollectTexts(s, depth + 1, out, budget);
    }
}

static UIView *JAGridCommonAncestor(UIView *a, UIView *b) {
    UIView *x = a;
    while (x) {
        if ([b isDescendantOfView:x]) return x;
        x = x.superview;
    }
    return nil;
}

// 从这张卡片往上找设备对象：先看自有属性，再看 uid 去 JAGroupManager 换 camera
static id JAGridCameraForView(UIView *v) {
    NSArray *keys = @[@"myCamera", @"camera", @"myDevice", @"device", @"deviceModel",
                      @"dataModel", @"model", @"devModel", @"deviceInfo"];
    UIView *x = v;
    int level = 0;
    while (x && level < 8) {
        id owner = x;
        for (NSString *k in keys) {
            id cand = JAVal(owner, k);
            if (!cand) continue;
            id cam = JAGridAsCamera(cand);
            if (cam) return cam;
            id uidRaw = JAVal(cand, @"uid");
            if (!uidRaw) uidRaw = JAVal(cand, @"deviceId");
            NSString *uid = JANormId(uidRaw);
            if (uid.length) {
                id gm = JAGroupManagerShared();
                @try {
                    id c2 = [gm performSelector:NSSelectorFromString(@"getMyCameraWithUid:")
                                      withObject:uidRaw];
                    if (c2) return c2;
                } @catch (NSException *e) {}
            }
        }
        NSString *ownUid = JANormId(JAVal(owner, @"uid"));
        if (ownUid.length) {
            id gm = JAGroupManagerShared();
            @try {
                id c3 = [gm performSelector:NSSelectorFromString(@"getMyCameraWithUid:")
                                  withObject:JAVal(owner, @"uid")];
                if (c3) return c3;
            } @catch (NSException *e) {}
        }
        x = x.superview;
        level++;
    }
    return nil;
}

static void JAGridInstallEntryInRow(UIView *cloud, UIView *ai) {
    if (!cloud || !ai) return;
    if ([cloud isDescendantOfView:ai] || [ai isDescendantOfView:cloud]) return;
    UIView *host = JAGridCommonAncestor(cloud, ai);
    if (!host) return;

    CGRect rc = [cloud convertRect:cloud.bounds toView:host];
    CGRect ra = [ai convertRect:ai.bounds toView:host];
    if (fabs(CGRectGetMidY(rc) - CGRectGetMidY(ra)) > 10) return;   // 不在同一行
    if (CGRectGetMinX(ra) <= CGRectGetMinX(rc)) return;             // AI 应在右边

    CGFloat midX = (CGRectGetMidX(rc) + CGRectGetMidX(ra)) / 2.0;
    CGFloat midY = (CGRectGetMidY(rc) + CGRectGetMidY(ra)) / 2.0;
    for (UIView *sv in host.subviews) {
        if (sv.tag == JAGridEntryTag && fabs(CGRectGetMidX(sv.frame) - midX) < 8) return;
    }

    CGFloat h = MAX(36.0, MAX(CGRectGetHeight(rc), CGRectGetHeight(ra)) + 10.0);
    CGFloat w = 104.0;
    CGFloat hostW = CGRectGetWidth(host.bounds);
    if (hostW > 0 && w > hostW * 0.40) w = hostW * 0.40;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(midX - w / 2.0, midY - h / 2.0, w, h)];
    box.tag = JAGridEntryTag;
    box.backgroundColor = [UIColor clearColor];
    box.userInteractionEnabled = YES;
    box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                           UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;

    // 样式跟「AI分析」那一项走（云存储有时是灰色/红色禁用态）
    UIColor *tint = [UIColor darkGrayColor];
    UIFont *font = [UIFont systemFontOfSize:13.0];
    if ([ai isKindOfClass:UILabel.class]) {
        UILabel *al = (UILabel *)ai;
        if (al.textColor) tint = al.textColor;
        if (al.font) font = al.font;
    } else if ([ai isKindOfClass:UIButton.class]) {
        UIButton *ab = (UIButton *)ai;
        UIColor *c = [ab titleColorForState:UIControlStateNormal];
        if (c) tint = c;
        if (ab.titleLabel.font) font = ab.titleLabel.font;
    }

    UIImageView *icon = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 18, 18)];
    UIImage *img = [UIImage systemImageNamed:@"square.grid.3x3.fill"];
    if (!img) img = [UIImage systemImageNamed:@"square.grid.3x3"];
    icon.image = img;
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
    lab.text = @"格子回放";
    lab.font = font;
    lab.textColor = tint;
    [lab sizeToFit];

    CGFloat totalW = 18 + 4 + CGRectGetWidth(lab.frame);
    CGFloat startX = (w - totalW) / 2.0;
    icon.frame = CGRectMake(startX, (h - 18) / 2.0, 18, 18);
    lab.frame = CGRectMake(startX + 18 + 4, (h - CGRectGetHeight(lab.frame)) / 2.0,
                           CGRectGetWidth(lab.frame), CGRectGetHeight(lab.frame));
    [box addSubview:icon];
    [box addSubview:lab];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[JAGridEntryHub shared]
                                                                         action:@selector(onTapEntry:)];
    [box addGestureRecognizer:tap];
    [host addSubview:box];
}

static UIViewController *JAGridTopVC(void) {
    UIWindow *keyWin = nil;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        if (w.isKeyWindow) { keyWin = w; break; }
    }
    if (!keyWin && wins.count) keyWin = [wins lastObject];
    UIViewController *vc = keyWin.rootViewController;
    int guard = 0;
    while (vc && guard < 8) {
        guard++;
        UIViewController *next = nil;
        if (vc.presentedViewController) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)vc).topViewController;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)vc).selectedViewController;
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static void JAGridScanVisible(void) {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    UIViewController *vc = JAGridTopVC();
    if (!vc || !vc.isViewLoaded) return;
    NSMutableArray *hits = [NSMutableArray array];
    NSInteger budget = 500;
    JAGridCollectTexts(vc.view, 0, hits, &budget);
    if (hits.count < 2) return;

    NSMutableArray *clouds = [NSMutableArray array];
    NSMutableArray *ais = [NSMutableArray array];
    for (UIView *v in hits) {
        NSString *t = JAGridViewText(v);
        if (JAGridIsCloudText(t)) [clouds addObject:v];
        else if (JAGridIsAIText(t)) [ais addObject:v];
    }
    if (clouds.count == 0 || ais.count == 0) return;

    for (UIView *c in clouds) {
        UIView *best = nil;
        CGFloat bestDy = 1e9;
        for (UIView *a in ais) {
            UIView *host = JAGridCommonAncestor(c, a);
            if (!host) continue;
            CGRect rc = [c convertRect:c.bounds toView:host];
            CGRect ra = [a convertRect:a.bounds toView:host];
            if (CGRectGetMinX(ra) <= CGRectGetMinX(rc)) continue;
            CGFloat dy = fabs(CGRectGetMidY(rc) - CGRectGetMidY(ra));
            if (dy < 10 && dy < bestDy) { bestDy = dy; best = a; }
        }
        if (best) JAGridInstallEntryInRow(c, best);
    }
}

@implementation JAGridEntryHub

+ (instancetype)shared {
    static JAGridEntryHub *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[JAGridEntryHub alloc] init]; });
    return s;
}

- (void)tick {
    @try { JAGridScanVisible(); } @catch (NSException *e) {}
}

- (void)onTapEntry:(UITapGestureRecognizer *)g {
    UIView *box = g.view;
    if (!box) return;
    id cam = JAGridCameraForView(box);
    UIViewController *from = JAGridTopVC();
    if (!cam) {
        NSString *src = nil;
        if (from) cam = JAFindCamera(from, nil, &src);
    }
    if (!cam) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"没找到这台设备"
                                                                    message:@"没解析到该卡片的设备对象，先点进设备再试。"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        @try { [from presentViewController:ac animated:YES completion:nil]; } @catch (NSException *e) {}
        return;
    }
    JAGridReplayViewController *grid = [[JAGridReplayViewController alloc] init];
    grid.myCamera = cam;
    if (!from) return;
    if (from.navigationController) {
        @try { [from.navigationController pushViewController:grid animated:YES]; } @catch (NSException *e) {}
    } else {
        UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:grid];
        @try { [from presentViewController:n animated:YES completion:nil]; } @catch (NSException *e) {}
    }
}

@end

static void JAGridStartWatcher(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSTimer *t = [NSTimer timerWithTimeInterval:0.8
                                              target:[JAGridEntryHub shared]
                                            selector:@selector(tick)
                                            userInfo:nil
                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    });
}

// ---------- hook 安装 ----------

static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) return;  // 已是本 hook（幂等，防重复注入）
    if (saved && !*saved) *saved = cur;
    method_setImplementation(m, newImp);
}

static BOOL JAHooked = NO;  // 详情页 hook（clickCloudRecordAction 主链）

static void JAHook(void) {
    // 详情页主链
    if (!JAHooked) {
        Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
        if (detailCls) {
            JASetImp(detailCls, @selector(clickCloudRecordAction:), (IMP)ja_clickCloudRecordAction,
                     &g_orig_clickCloudRecordAction);
            JASetImp(detailCls, @selector(handleJumpToOpenCloud), (IMP)ja_handleJumpToOpenCloud,
                     &g_orig_handleJumpToOpenCloud);
            JAHooked = YES;
        }
    }
    // RTC SD 播放器 hooks（viewDidAppear 自动定位 / viewDidDisappear 返回停流；
    // 类可能晚加载，轮询重试）
    if (!g_rtcHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
            JASetImp(rtcCls, @selector(viewDidDisappear:), (IMP)ja_rtc_viewDidDisappear, &g_orig_rtc_vdd);
            // v2.0：入口 —— 给官方回放页加「格子」按钮（viewWillAppear 可能继承自
            // UIViewController，所以用 class_addMethod 只挂在本类，避免污染全局）
            if (!g_orig_rtc_vwa) {
                Method m = class_getInstanceMethod([UIViewController class], @selector(viewWillAppear:));
                if (m) g_orig_rtc_vwa = method_getImplementation(m);
            }
            if (!class_addMethod(rtcCls, @selector(viewWillAppear:),
                                 (IMP)ja_rtc_viewWillAppear, "v@:B")) {
                JASetImp(rtcCls, @selector(viewWillAppear:), (IMP)ja_rtc_viewWillAppear, &g_orig_rtc_vwa);
            }
            class_addMethod(rtcCls, @selector(ja_openGrid:), (IMP)ja_openGrid, "v@:@");
            g_rtcHooked = YES;
        }
    }
    // v2.2：首页卡片入口（定时扫可见视图，插在「云存储 / AI分析」中间）
    JAGridStartWatcher();
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JAGridStartWatcher();       // v2.2：首页卡片入口不依赖上面这些类，先挂上
    if (NSClassFromString(@"JANewsWarnInfoDetailVC")
        && NSClassFromString(@"JANewRtcSDPlayViewController")) {
        JAHook();
        return;
    }
    __block int tries = 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (tries < 30 && !(JAHooked && g_rtcHooked)) {
            [NSThread sleepForTimeInterval:0.5];
            tries++;
            dispatch_async(dispatch_get_main_queue(), ^{ JAHook(); });
        }
    });
}
