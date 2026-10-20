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
            g_rtcHooked = YES;
        }
    }
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
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
