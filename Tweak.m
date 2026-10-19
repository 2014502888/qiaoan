// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.15 换对界面：官方本地 SD 回放 = JANewRtcSDPlayViewController（RTC 完整播放器）
// （TrollStore 兼容：纯 runtime hook + C IMP，零类依赖，可直接 clang 编译）
//
// v1.15 定案（用户实测 + 二进制方法列表 + 反汇编）：
//   用户手动进本地回放看到的界面（时间轴拖条/日历选日/SD 卡容量/变速/录音）
//   = JANewRtcSDPlayViewController（321 个方法：timeLineView、calendarPopViewHelper、
//   switchToSDDay:dateString:、getSDCapcity、startSDPlayWithSelectTimeStamp:、
//   startPlay/pausePlay/changeSDPlaySpeed:、respDeviceSDPlayerStatus:、
//   respDeviceFirstFrameTimeStamp:、seekTo:duration:、noneVideoViewIsShow:dayEnd:）。
//   之前 push 的 JANewSDPlayerViewController 是另一播放器（旧版/云回放共用），
//   界面完全不同 → 黑屏。v1.15 换目标：clickCloudRecordAction → push RTC SD 播放器。
// 初始化（反汇编 viewDidLoad 0x100af4498 定案）：
//   viewDidLoad 自动：JADevicePlatform.sharedInstance setMyCamera:self.myCamera、
//   setIsSDPlayer:YES、创建 viewModel、setupUI —— 只需喂 myCamera + currentTimeStamp。
//   myCamera 无公开 setter（getter stub=0x103462da0）→ 用 KVC [vc setValue:cam forKey:@"myCamera"]。
// 自动定位（反汇编 startSDPlayWithSelectTimeStamp: 0x100b07b0c 定案）：
//   startSDPlayWithSelectTimeStamp:sec → viewModel startSDPlayShowWithSelectTimeStamp:sec
//   → 官方建流播放并定位到 sec。本版 hook viewDidAppear，官方完成后延迟 0.4s
//   调 startSDPlayWithSelectTimeStamp:（报警时间戳）→ 直达报警时间点。
// 闸门：RTC 版是官方完整播放器，官方链自己建流 → JASDPlayerActive 全程 NO，
//   isEnterBackPlayer/isStarBackPlayer/detectType 强制全关，不干扰官方逻辑。
//
// v1.14 崩溃根治（IPS 124424 定案，保留）：
//   respDeviceSDPlayerStatus:（0x100b75ecc）与 respDeviceFirstFrameTimeStamp:（0x100b77d64）
//   参数【不是对象】而是数值（respDeviceSDPlayerStatus 内部 cmp w20,#0x21 + 跳表 = int 状态码）。
//   旧签名 (id, SEL, id) 把 32 当对象指针发 [arg class] → SIGSEGV（PC=hook+0x44）。
//   v1.14 起两个 hook 按数值打印，不再向参数发消息。
//
// v1.13 根因（已并入，保留备查）：
//   seekTo 已命中但播放不启动 —— 官方 SD 回放必须先【建流】再【定位】：
//   MYP2PChannel p2p_starPlayBack(0x100c7feac)：isEnterBackPlayer==0 且 isStarBackPlayer==0
//   → startReplay 建流；否则 seekReplay 仅定位。旧版强制 isEnterBackPlayer=1 → 只 seek 不建流。
//
// 实测问题链：
//   v1：闪退（设备对象未传入，JALiveManager.myCamera=nil → MYOpenSDK 异常）
//   v1.1：仍弹云存储（AI 报警详情页 myCamera 恒 nil，走兜底）
//   v1.2：仍弹云存储 —— 根因：TrollFools 里旧 dylib（v1.0）未删除，新旧 dylib 同时加载。
//         v1.0 先 exchange（clickCloudRecordAction: → v1.0 hook，原实现挪到 _jasd_），
//         v1.2 后 exchange 时 class_addMethod 发现 _jasd_ 已存在不覆盖，再 exchange
//         又把 clickCloudRecordAction: 交换回【原实现】→ hook 被还原 → 弹云存储。
//   v1.3 修复：改 method_setImplementation 直接覆盖（幂等），原 IMP 存全局变量兜底。
//         重复注入只检测到"已是本 hook"就跳过，绝不破坏已有 hook。防抖修双 push。
//   v1.4 修复：用户实测跳转成功但"回放画面定位错 / 只能看实时"——
//         根因：时间戳单位错。报警事件时间戳是【秒】（event_file_url 文件名
//         2310111541-1792304458.jpg 内嵌 1792304458 秒 = 2026-10-18 14:20:58 本地），
//         v1.3 传了毫秒（1792304458000）→ SDPlayer.getCurrentEventWithTimeStamp:
//         用 eventTime 与时间戳直接整数比较 → 匹配不到事件 → timeline 无法定位。
//         v1.4 改为秒：优先从 event_file_url 正则提取内嵌秒，兜底 event_date+event_time 拼秒。
//         （用户实测：currentTimeStamp=1792339861 秒级 ✓、单 push ✓，但回放仍"一直闪"）
//   v1.5 修复（本版）：用户实测"一直闪"（SDPlayer 打开后停在"当前时间无录像"+实时流，
//         时间轴恒 00:00:00）——逆向确认真正卡点：SD 事件列表从未被拉取。
//         官方定位链：viewWillAppear（getTodayStartTimestamp 与设备 sdSelectiontDay 比较）
//         → 决定 pendingReloadTodaySDSelectiontDay → viewDidAppear 若 !=0 就主动
//         [live getEventListWithSelectiontDay:detectionType:] 拉事件列表 → 设备回调
//         respDeviceSdEventList: → 读 currentTimeStamp（≥1）→ 减 sdSelectiontDay
//         → ≤86400 则 [self seekTo:duration:] 定位播放。
//         官方判定：设备 sdSelectiontDay==0 → pendingReload=0 → 不拉列表。
//         我们直接 push 的设备对象 sdSelectiontDay 恰为 0 → 事件列表从不拉 → 时间戳
//         没机会被消费 → 只播实时。本版 hook viewWillAppear 强制设
//         pendingReloadTodaySDSelectiontDay = 报警日 0 点秒（UTC 语义），
//         并 hook viewDidAppear 延迟 3s 主动补拉 getEventListWithSelectiontDay:，
//         push 时补设 myCamera.sdSelectiontDay（防 0 值 + 配合偏移计算）。
//
// v1.2 逆向结论（设备来源）：
//   * AI 人脸报警详情页 myCamera 是父类 JABasicViewController 普通属性，恒 nil
//   * JAGroupManager（设备/分组管理单例）：getMyCameraWithUid: = myCameraMap[eid] 直查；
//     getAllMyCamera = 全部设备；报警模型 eid 即设备唯一标识
//
// v1.4 逆向结论（SD 回放自包含，无需额外模式标志）：
//   * JANewSDPlayerViewController viewDidLoad 自己会：
//       JALiveManager.sharedInstance setMyCamera:/setCurrentCamera:/setIsSDPlayer:YES
//     viewDidAppear → ja_ReallySetupLiveDelegate → delegateCamera:isSDCardPage:YES
//     → JALiveManager 建链（P2P/ims）→ 设备回传 SD 事件/记录列表 → timeline
//   * 我们 push 前只需 setMyCamera: + currentEvent + currentTimeStamp(秒) + eventList
//
// 官方关键桩（arm64）：
//   0x103462da0 = myCamera getter   0x103510b20 = setMyCamera:
//   0x10348b360 = pushViewController:animated:
//   0x10354f880 = sharedInstance    0x1033cee40 = delegateCamera:isSDCardPage:
//   0x10344d000 = live              0x10357efa0 = uid
//   0x1034fd080 = setIsSDPlayer:（SDPlayer viewDidLoad 自己设，无需我们设）

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *JALogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    return [paths[0] stringByAppendingPathComponent:@"jasdreplay.log"];
}

static void JALog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[JASDReplay] %@", msg);
    @autoreleasepool {
        NSString *p = JALogPath();
        if (p) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:p]) {
                [fm createFileAtPath:p contents:nil attributes:nil];
            }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
    }
}

static id JAVal(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static void JASet(id obj, NSString *key, id val) {
    if (!obj || !val) return;
    @try { [obj setValue:val forKey:key]; }
    @catch (NSException *e) { JALog(@"set %@ failed: %@", key, e); }
}

static UIViewController *JATopVC(void) {
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:UINavigationController.class]) {
        vc = ((UINavigationController *)vc).topViewController;
    }
    return vc;
}

// ---------- JAGroupManager 单例（设备/分组管理核心） ----------

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
            if (obj) {
                JALog(@"JAGroupManager 单例命中: +[JAGroupManager %@] -> %@", sn, obj);
                return obj;
            }
        }
    }
    JALog(@"!! JAGroupManager 单例未找到（common 单例名均无响应）");
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

    id map = JAVal(gm, @"myCameraMap");
    JALog(@"myCameraMap=%@ count=%lu", map, (unsigned long)[map count]);

    NSString *eid = JANormId(JAVal(warn, @"eid"));
    JALog(@"warn.eid=%@", eid);

    // 1) getMyCameraWithUid:eid 直查（myCameraMap[eid]）
    if (eid) {
        id cam = nil;
        @try {
            cam = [gm performSelector:NSSelectorFromString(@"getMyCameraWithUid:")
                           withObject:JAVal(warn, @"eid")];
        } @catch (NSException *e) {
            JALog(@"!! getMyCameraWithUid: 异常: %@", e);
        }
        if (cam) {
            *src = [NSString stringWithFormat:@"JAGroupManager.getMyCameraWithUid(eid=%@)", eid];
            return cam;
        }
        JALog(@"getMyCameraWithUid(eid=%@) 未命中", eid);
    }

    // 2) 遍历 getAllMyCamera 比对 uid
    id all = nil;
    @try {
        all = [gm performSelector:NSSelectorFromString(@"getAllMyCamera")];
    } @catch (NSException *e) {
        JALog(@"!! getAllMyCamera 异常: %@", e);
    }
    if ([all isKindOfClass:NSArray.class]) {
        NSUInteger n = [all count];
        JALog(@"getAllMyCamera 共 %lu 台设备", (unsigned long)n);
        for (NSUInteger i = 0; i < n; i++) {
            id cam = [all objectAtIndex:i];
            NSString *uid = JANormId(JAVal(cam, @"uid"));
            if (i < 5) JALog(@"  设备[%lu] uid=%@ class=%@", (unsigned long)i, uid, NSStringFromClass([cam class]));
            if (eid && uid && [uid isEqualToString:eid]) {
                *src = [NSString stringWithFormat:@"getAllMyCamera uid==eid(%@)", eid];
                return cam;
            }
        }
        JALog(@"getAllMyCamera 未匹配到 eid=%@", eid);
    } else {
        JALog(@"!! getAllMyCamera 返回非数组: %@", all);
    }
    return nil;
}

// ---------- camera（设备对象 MyCamera）获取 ----------

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
            JALog(@"时间戳来源: event_file_url 内嵌秒 %@", sec);
            return @(sec.longLongValue);
        }
    }
    // ② eventTimeUTC
    id t = JAVal(warn, @"eventTimeUTC");
    if (t) {
        if ([t isKindOfClass:NSNumber.class]) {
            JALog(@"时间戳来源: eventTimeUTC NSNumber %@", t);
            return t; // 原样（秒）
        }
        if ([t isKindOfClass:NSString.class]) {
            JALog(@"时间戳来源: eventTimeUTC 字符串 %@", t);
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
            long long sec = (long long)[date timeIntervalSince1970];
            JALog(@"时间戳来源: event_date+event_time 拼秒 %lld", sec);
            return @(sec);
        }
    }
    return nil;
}

// ---------- 核心逻辑 ----------

// 前置声明 + 提前定义（hook 实现区在下方；JATryOpenSDReplay 里需补装生命周期 hook）
static void ja_sd_viewWillAppear(id self, SEL _cmd);
static void ja_sd_viewDidAppear(id self, SEL _cmd);
static void ja_sd_respDeviceSdEventList(id self, SEL _cmd, id arg);  // v1.6 诊断
static void ja_getEventList(id self, SEL _cmd, id day, id type);     // v1.6 诊断
static id ja_sd_getCurrentEventWithTimeStamp(id self, SEL _cmd, long long ts);  // v1.8
static void ja_sd_seekTo_duration(id self, SEL _cmd, long long sec, double dur);  // v1.8
static long long ja_live_detectType(id self, SEL _cmd);              // v1.9 诊断：JALiveManager.detectType
static long long ja_live_isEnterBackPlayer(id self, SEL _cmd);       // v1.9 诊断：JALiveManager.isEnterBackPlayer
static long long ja_live_isStarBackPlayer(id self, SEL _cmd);        // v1.14：JALiveManager.isStarBackPlayer（建流路径全开）
static void ja_sd_viewWillDisappear(id self, SEL _cmd);  // v1.10：离开 SD 回放时关闭闸门强制
static void ja_vm_seekTo_duration(id self, SEL _cmd, long long sec, long long dur);  // v1.9：viewModel.seekTo:duration:
static void JAHookLiveGates(void);   // v1.9：统一安装 JALiveManager 闸门 getter + viewModel seekTo hook（幂等）
static void ja_p2p_starPlayBack(id self, SEL _cmd);          // v1.13：MYP2PChannel 建流/定位分支 hook
static void ja_sd_respFirstFrame(id self, SEL _cmd, long long ts); // v1.13/v1.14：首帧回调确认（参数是时间戳数值）
static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved);
static void JASDInstallHooks(void);   // v1.13：统一安装 SDPlayer 生命周期/消费链 hook
static void JAHookP2PChannel(void);   // v1.13：MYP2PChannel p2p_starPlayBack hook（类晚加载幂等）
static void ja_rtc_viewDidAppear(id self, SEL _cmd);  // v1.15：RTC SD 播放器 viewDidAppear（官方后自动定位报警时间）
static BOOL JASDHooked = NO;
static BOOL JASDPlayerActive = NO;   // v1.10：我们的 SDPlayer 是否活跃（活跃期间 getter 开闸）
// v1.15：目标界面改为官方本地 SD 回放 JANewRtcSDPlayViewController（时间轴/日历/播放控制）。
// RTC 版是官方完整播放器，viewDidLoad 自动 setMyCamera/setIsSDPlayer/建 viewModel，
// 官方链自己建流播放 → JASDPlayerActive 全程 NO（闸门强制全关，不干扰官方逻辑）。
static BOOL g_rtcHooked = NO;        // v1.15：RTC SD 播放器 hook 已装
static IMP g_orig_rtc_vda = NULL;    // v1.15：JANewRtcSDPlayViewController viewDidAppear: 原 IMP
static long long g_rtcTargetSec = 0; // v1.15：报警时间戳（秒），viewDidAppear 后自动定位播放
// v1.11.1：当前活跃 SDPlayer 指针（纯 C 比较守卫，不向对象发消息）。
// 修复闪退：回放页返回详情后再点看录像（第二次 push）时，官方 resp 回调可能携带
// 已释放的旧 SDPlayer A → hook 对野指针 A 做偏移读 + 向残留值发消息 → SIGSEGV。
// 所有 SDPlayer hook 开头先判 self==g_activeSDPlayer，不是就直接透传原实现。
static id g_activeSDPlayer = nil;
static IMP g_orig_sd_vwa = NULL;  // JANewSDPlayerViewController viewWillAppear: 原 IMP
static IMP g_orig_sd_vda = NULL;  // JANewSDPlayerViewController viewDidAppear: 原 IMP
static IMP g_orig_sd_vwd = NULL;  // v1.10：viewWillDisappear: 原 IMP
static IMP g_orig_sd_respEventList = NULL;  // v1.6：respDeviceSdEventList: 原 IMP
static IMP g_orig_getEventList = NULL;      // v1.6：getEventListWithSelectiontDay:detectionType: 原 IMP
static IMP g_orig_getCurrentEvent = NULL;   // v1.8：getCurrentEventWithTimeStamp: 原 IMP
static IMP g_orig_seekTo = NULL;            // v1.8：seekTo:duration: 原 IMP（SDPlayer 类，非消费链实际调用者）
static IMP g_orig_live_detectType = NULL;   // v1.9：JALiveManager.detectType getter 原 IMP
static IMP g_orig_live_isEnterBackPlayer = NULL;  // v1.9：JALiveManager.isEnterBackPlayer getter 原 IMP
static IMP g_orig_live_isStarBackPlayer = NULL;   // v1.14：JALiveManager.isStarBackPlayer getter 原 IMP（建流路径全开）
static IMP g_orig_vm_seekTo = NULL;         // v1.9：viewModel.seekTo:duration: 原 IMP（官方消费链实际调用者）
static IMP g_orig_noneVideoViewIsShow = NULL; // v1.11：noneVideoViewIsShow:dayEnd: 原 IMP（"当前时间无录像"提示）
static IMP g_orig_respSDPlayerStatus = NULL;  // v1.11：respDeviceSDPlayerStatus: 原 IMP（播放状态回调）
// v1.13：建流修复相关
static IMP g_orig_p2p_starPlayBack = NULL;    // MYP2PChannel p2p_starPlayBack 原 IMP
static IMP g_orig_respFirstFrame = NULL;      // respDeviceFirstFrameTimeStamp: 原 IMP（首帧回调）
static BOOL g_p2pHooked = NO;                 // MYP2PChannel hook 是否已装（类可能晚加载）
static long long g_lastRealEnterBack = -1;    // isEnterBackPlayer 最近一次真实值（getter hook 里记录）
static long long g_lastRealStarBack = -1;      // v1.14：isStarBackPlayer 最近一次真实值（getter hook 里记录）
static BOOL g_startReplaySent = NO;           // 本次回放会话是否已发出建流（startReplay）
static BOOL g_forceStarZero = NO;             // v1.14：p2p_starPlayBack 建流窗口内强制 isStarBackPlayer 返回 0（官方建流条件需 enter==0 && star==0）

// v1.5：从秒级时间戳算"报警日 0 点秒"（本地时区语义 = 北京时间 00:00）
// v1.11 修正：原实现取 UTC 0 点（北京 08:00），比官方"今日 0 点"（北京 00:00）偏 8 小时。
// 官方 getTodayStartTimestamp / resp 内部 setSdSelectiontDay 均按本地（北京）0 点。
// 正确公式：epoch 秒先取 UTC 当天 0 点，再减 28800（东八区）→ 北京 00:00。
// 例：1792378567（北京 10-19 10:56:07）→ (1792378567-1792378567%86400)-28800 = 1792339200
static long long JADayStartSec(NSNumber *ts) {
    if (!ts) return 0;
    long long v = ts.longLongValue;
    if (v >= 1000000000LL && v < 10000000000LL) {
        long long utcMid = v - (v % 86400LL);  // UTC 当天 0 点
        return utcMid - 28800LL;               // 减 8 小时 → 北京当天 00:00
    }
    return 0;
}

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    JALog(@"--- JATryOpenSDReplay (camera=%@ class=%@ uid=%@) ---",
          cam, cam ? NSStringFromClass([cam class]) : @"nil", JAVal(cam, @"uid"));
    // v1.15：目标界面 = 官方本地 SD 回放 JANewRtcSDPlayViewController（RTC 完整播放器，
    // 时间轴/日历/SD 卡检测/播放控制；用户手动进本地回放看到的就是它）。
    Class cls = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!cls) {
        JALog(@"!! JANewRtcSDPlayViewController 类不存在");
        return;
    }
    // v1.5：类此刻已加载（NSClassFromString 触发），若启动轮询错过（15s 内未点入），
    // 在这里立即补装生命周期 hook，确保 viewWillAppear/viewDidAppear 生效
    if (!JASDHooked) {
        JASDInstallHooks();
        JALog(@"点看录像时补装 SDPlayer 生命周期 hook（轮询错过场景兜底）");
    }
    // v1.13：p2p_starPlayBack 建流 hook 无条件补装（幂等）——保留（RTC 场景 JASDPlayerActive=NO 时透传，无副作用）
    JAHookP2PChannel();
    // v1.15：RTC viewDidAppear hook 补装（自动定位报警时间）
    if (!g_rtcHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
            g_rtcHooked = YES;
        }
    }
    id vc = [[cls alloc] init];
    JALog(@"已创建 SDPlayer(RTC): %@ class=%@", vc, NSStringFromClass([vc class]));

    // 1) v1.15：myCamera 用 KVC（RTC 版无 setMyCamera: 公开方法，performSelector 会崩）。
    // 官方 viewDidLoad 会自己读 self.myCamera → setMyCamera: 到 JADevicePlatform.sharedInstance
    //（0x100af461c 定案），这里只需把 camera 挂到 VC 上。
    @try {
        [vc setValue:cam forKey:@"myCamera"];
        id chk = [vc valueForKey:@"myCamera"];
        JALog(@"setMyCamera(KVC) 后 RTC.myCamera=%@ uid=%@", chk, JAVal(chk, @"uid"));
    } @catch (NSException *e) {
        JALog(@"!! setValue myCamera 异常: %@", e);
    }

    // 2) 同步 JALiveManager 单例（delegateCamera:/connectionDevice 内部从它取 myCamera）
    Class lmCls = NSClassFromString(@"JALiveManager");
    id lm = nil;
    if (lmCls) {
        NSArray *sels = @[@"sharedInstance", @"shared", @"shareManager", @"defaultManager"];
        for (NSString *sn in sels) {
            SEL s = NSSelectorFromString(sn);
            if (class_respondsToSelector(lmCls, s)) {
                lm = ((id(*)(id, SEL))objc_msgSend)((id)lmCls, s);
                if (lm) {
                    JALog(@"JALiveManager 单例命中: +[JALiveManager %@]", sn);
                    break;
                }
            }
        }
        if (!lm) {
            JALog(@"!! JALiveManager 单例未找到（%lu 个 common 名均无响应）", (unsigned long)sels.count);
            unsigned int mc = 0;
            Method *methods = class_copyMethodList(object_getClass(lmCls), &mc);
            JALog(@"JALiveManager 类方法共 %u 个：", mc);
            for (unsigned int i = 0; i < mc && i < 60; i++) {
                JALog(@"  +[JALiveManager %@]", NSStringFromSelector(method_getName(methods[i])));
            }
            free(methods);
        }
    }
    if (lm) {
        @try {
            [lm setValue:cam forKey:@"myCamera"];
            id chk = [lm valueForKey:@"myCamera"];
            JALog(@"已同步 JALiveManager.myCamera=%@ uid=%@", chk, JAVal(chk, @"uid"));
        } @catch (NSException *e) {
            JALog(@"!! 同步 JALiveManager.myCamera 失败: %@", e);
        }
    }

    // 3) 事件与时间戳
    if (warn) {
        JASet(vc, @"currentEvent", warn);
        NSNumber *ts = JABuildTimestamp(warn);
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        // 校验秒范围：10 位秒级（1.0e9 ~ 9.9e9），防止再传毫秒
        long long tv = ts ? ts.longLongValue : 0;
        JALog(@"currentTimeStamp=%@ (%lld 秒 → %@)", ts, tv,
              tv >= 1000000000LL && tv < 10000000000LL
              ? @"秒级 ✓" : @"⚠ 非秒级！");
        // v1.15：记录报警时间戳（秒），RTC viewDidAppear 后自动 startSDPlayWithSelectTimeStamp:
        if (tv >= 1000000000LL && tv < 10000000000LL) g_rtcTargetSec = tv;
        // v1.5：补设设备 SD 选中日期 = 报警日 0 点秒 —— RTC setupData（0x100af6104）会
        // 读 myCamera.sdSelectiontDay → setCurrentSelectedSDDay:（选中日）→ 加载该日事件列表
        long long dayStart = JADayStartSec(ts);
        if (dayStart > 0 && cam) {
            JASet(cam, @"sdSelectiontDay", @(dayStart));
            JALog(@"已设 myCamera.sdSelectiontDay=%lld (报警日0点UTC)", dayStart);
        }
        id evtList = JAVal(detailVC, @"warnInfoListArr");
        if (evtList) JASet(vc, @"eventList", evtList);
        JALog(@"已设置 currentEvent/currentTimeStamp/eventList (RTC)");
    }

    // 4) push
    UINavigationController *nav = detailVC.navigationController;
    if (!nav) nav = JATopVC().navigationController;
    if (nav) {
        g_activeSDPlayer = vc;  // v1.11.1：登记当前活跃 SDPlayer（resp/seekTo hook 守卫用）
        [nav pushViewController:vc animated:YES];
        // v1.15：RTC 版是官方完整播放器，官方链自己建流 → 闸门强制保持关闭
        JASDPlayerActive = NO;
        JALog(@"已 push SDPlayer(RTC)（闸门强制关闭，由官方原生链播放）");
    } else {
        JALog(@"!! 无 navigationController，改为 present");
        [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:vc animated:YES completion:nil];
    }
}

static void JADumpWarnInfo(UIViewController *detailVC, NSString *from) {
    JALog(@"=== %@ ===", from);
    JALog(@"self=%p class=%@", detailVC, NSStringFromClass(detailVC.class));
    JALog(@"deviceId=%@ devicePwd=%@",
          JAVal(detailVC, @"deviceId"), JAVal(detailVC, @"devicePwd"));

    id cam = JAVal(detailVC, @"myCamera");
    JALog(@"self.myCamera=%@ class=%@ uid=%@", cam, cam ? NSStringFromClass([cam class]) : @"nil", JAVal(cam, @"uid"));

    id warn = JAVal(detailVC, @"warnInfoEntityModelEx");
    JALog(@"warnModel=%@", warn);
    if (warn) {
        id ts = JAVal(warn, @"eventTimeUTC");
        JALog(@"  eventTimeUTC=%@ (%@)", ts, ts ? NSStringFromClass([ts class]) : @"nil");
        JALog(@"  event_time=%@  event_date=%@  event_type=%@  eid=%@",
              JAVal(warn, @"event_time"), JAVal(warn, @"event_date"), JAVal(warn, @"event_type"), JAVal(warn, @"eid"));
        JALog(@"  warn_record_type=%@  cs_status=%@  isAli=%@",
              JAVal(warn, @"warn_record_type"), JAVal(warn, @"cs_status"), JAVal(warn, @"isAli"));
        JALog(@"  event_file_url=%@  eventPicThumbUrl=%@  rowKey=%@",
              JAVal(warn, @"event_file_url"), JAVal(warn, @"eventPicThumbUrl"), JAVal(warn, @"rowKey"));
        JALog(@"  event_id=%@  bucket_name=%@  end_point=%@",
              JAVal(warn, @"event_id"), JAVal(warn, @"bucket_name"), JAVal(warn, @"end_point"));
    }

    id vm = JAVal(detailVC, @"viewModel");
    JALog(@"viewModel=%@ class=%@", vm, NSStringFromClass([vm class]));
    if (vm) {
        NSArray *keys = @[@"device", @"myCamera", @"camera", @"devID", @"deviceId", @"deviceID", @"dev", @"cameraModel"];
        for (NSString *k in keys) {
            id v = JAVal(vm, k);
            if (v) JALog(@"  viewModel.%@ = %@ (%@)", k, v, NSStringFromClass([v class]));
        }
    }

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(detailVC.class, &pc);
    for (unsigned int i = 0; i < pc; i++) {
        const char *name = property_getName(props[i]);
        NSString *pn = [NSString stringWithUTF8String:name];
        id v = JAVal(detailVC, pn);
        if (v && [NSStringFromClass([v class]) containsString:@"Camera"]) {
            JALog(@"  self.%@ = %@ (%@)", pn, v, NSStringFromClass([v class]));
        }
    }
    free(props);
}

// ---------- hook 实现（C IMP，无类依赖） ----------

// 原实现保存（兜底用）—— 必须在使用前定义
static IMP g_orig_clickCloudRecordAction = NULL;
static IMP g_orig_handleJumpToOpenCloud = NULL;

// v1.5：JANewSDPlayerViewController 生命周期 hook 原 IMP 已在核心逻辑区前置定义
// （g_orig_sd_vwa / g_orig_sd_vda，JATryOpenSDReplay 补装逻辑需提前使用）

// v1.6 诊断：拦截 getEventListWithSelectiontDay:detectionType:，打印官方/我们的调用参数
static void ja_getEventList(id self, SEL _cmd, id day, id type) {
    JALog(@"[getEventListWithSelectiontDay:detectionType:] self=%@ class=%@ day=%@ type=%@",
          self, NSStringFromClass([self class]), day, type);
    if (g_orig_getEventList) ((void(*)(id, SEL, id, id))g_orig_getEventList)(self, _cmd, day, type);
}

// v1.6 诊断：确保 getEventList hook 已装到 live 实际类上（类可能晚加载）
static void JASDEnsureGetEventListHook(id live) {
    if (!live) return;
    Class liveCls = [live class];
    if (!liveCls) return;
    SEL s = NSSelectorFromString(@"getEventListWithSelectiontDay:detectionType:");
    if (![live respondsToSelector:s]) return;
    JASetImp(liveCls, s, (IMP)ja_getEventList, &g_orig_getEventList);
}

// v1.5：主动拉取 SD 事件列表（官方链：JADevicePlatform.sharedInstance.live）
// getEventListWithSelectiontDay:detectionType: —— 设备返回后走官方
// respDeviceSdEventList: 回调 → 读 currentTimeStamp → seekTo: 定位播放
// v1.6：delaySec 延迟秒数（多轮补拉），detectType 传 0（比 -1 更可能命中通用列表）
// v1.5~v1.11：主动拉取 SD 事件列表 —— v1.12 起不再调用（官方 viewDidAppear 自行拉取已成功，
// 本闭包是 v1.11/v1.11.2 崩溃源：dispatch_after 补拉时 JADevicePlatform.live=0x20 → SIGSEGV）。
// 保留定义备查。
static void JASDForcePullEventList(long long dayStart, double delaySec) __attribute__((unused)) {
    if (dayStart <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class dp = NSClassFromString(@"JADevicePlatform");
        if (!dp) {
            JALog(@"!! JADevicePlatform 类不存在");
            return;
        }
        id inst = nil;
        @try {
            inst = ((id(*)(id, SEL))objc_msgSend)((id)dp, NSSelectorFromString(@"sharedInstance"));
        } @catch (NSException *e) {
            JALog(@"!! JADevicePlatform.sharedInstance 异常: %@", e);
        }
        if (!inst) {
            JALog(@"!! JADevicePlatform.sharedInstance=nil");
            return;
        }
        id live = JAVal(inst, @"live");
        if (!live) {
            JALog(@"!! live=nil");
            return;
        }
        // v1.11.2 保险：live 必须是 JALiveManager 才继续（防状态异常时读到非预期对象）
        Class liveCls = [live class];
        if (liveCls != NSClassFromString(@"JALiveManager")) {
            JALog(@"!! live 类型异常 class=%@（预期 JALiveManager），跳过补拉",
                  liveCls ? NSStringFromClass(liveCls) : @"nil");
            return;
        }
        JASDEnsureGetEventListHook(live);
        SEL s = NSSelectorFromString(@"getEventListWithSelectiontDay:detectionType:");
        if (![live respondsToSelector:s]) {
            JALog(@"!! live 无 getEventListWithSelectiontDay:detectionType:");
            return;
        }
        long long d = 0;  // v1.6：detectType 用 0（-1 可能被设备端视为无效过滤条件）
        @try {
            // 直接用 objc_msgSend 调 2 参方法，避免 ARC performSelector leak 警告
            ((void(*)(id, SEL, id, id))objc_msgSend)(live, s, @(dayStart), @(d));
            JALog(@"主动拉取 SD 事件列表: dayStart=%lld detectType=%lld (延迟 %.1fs)", dayStart, d, delaySec);
        } @catch (NSException *e) {
            JALog(@"!! 拉取异常: %@", e);
        }
    });
}

// v1.8 诊断：dump MYEventModel 真实属性与值（前几条）
static void JADumpEventModel(id item, NSUInteger idx) {
    if (!item) return;
    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList([item class], &pc);
    NSMutableString *line = [NSMutableString stringWithFormat:@"事件[%lu] class=%@ ",
                             (unsigned long)idx, NSStringFromClass([item class])];
    for (unsigned int i = 0; i < pc; i++) {
        const char *name = property_getName(props[i]);
        NSString *pn = [NSString stringWithUTF8String:name];
        id v = nil;
        @try { v = [item valueForKey:pn]; } @catch (NSException *e) { v = @"<异常>"; }
        if (v) [line appendFormat:@"%@=%@ ", pn, v];
    }
    free(props);
    JALog(@"  %@", line);
}

// v1.8 诊断：拦截设备回传事件列表回调，确认设备到底回没回列表、时间戳是否被消费
// v1.7：调用原实现前强制 sdSelectiontDay=报警日0点 —— 铁证：官方 viewWillAppear
// 会把设备 sdSelectiontDay 覆盖为"今天 0 点"，跨天报警（报警日≠今天）时定位偏移
// currentTimeStamp - sdSelectiontDay 会落到"今天"的错误时段（无录像）。
// 在设备回传消费点前强设回报警日，官方 respDeviceSdEventList: 内部即可正确 seekTo。
// v1.9：统一安装 JALiveManager 两闸门 getter + viewModel seekTo 诊断 hook（幂等）
static BOOL JALiveHooked = NO;
static void JAHookLiveGates(void) {
    if (JALiveHooked) return;
    Class lmCls = NSClassFromString(@"JALiveManager");
    if (lmCls) {
        JASetImp(lmCls, NSSelectorFromString(@"detectType"), (IMP)ja_live_detectType,
                 &g_orig_live_detectType);
        JASetImp(lmCls, NSSelectorFromString(@"isEnterBackPlayer"), (IMP)ja_live_isEnterBackPlayer,
                 &g_orig_live_isEnterBackPlayer);
        // v1.14：isStarBackPlayer —— 建流前强制 0（让 p2p selectTimeStamp: 走建流路径）
        JASetImp(lmCls, NSSelectorFromString(@"isStarBackPlayer"), (IMP)ja_live_isStarBackPlayer,
                 &g_orig_live_isStarBackPlayer);
    }
    Class vmCls = NSClassFromString(@"JANewRtcSDPlayViewModel");
    if (vmCls) {
        JASetImp(vmCls, NSSelectorFromString(@"seekTo:duration:"), (IMP)ja_vm_seekTo_duration,
                 &g_orig_vm_seekTo);
    }
    JALiveHooked = YES;
}

// v1.10 修复：设备回传消费链有两道闸门（反汇编 0x100b76d48 起）：
//   闸门1：cbz [live isEnterBackPlayer] → 0x100b7741c（不消费）
//   闸门2：cmn [live detectType],#1 → b.eq 0x100b77374（不 seekTo）
// 我们直接 push SDPlayer 未走官方初始化，这两个状态是 0/-1 → 永远不 seekTo。
// v1.9 尝试 setDetectType:/setIsEnterBackPlayer: 强设 —— 实测 JALiveManager
// 无 sharedInstance 单例（4 个 common 名均无响应），setter 方案失效。
// v1.10 改为在 getter 层开闸（见 ja_live_detectType / ja_live_isEnterBackPlayer）：
// 我们的 SDPlayer 活跃期间（JASDPlayerActive）强制返回 0 / YES，其余场景透传原值。

// v1.10 兜底：官方消费链若仍不 seekTo，按反汇编事实（receiver = SDPlayer+0x28）直接定位。
// v1.9 的 KVC/ivar 遍历全部落空 → 改为按偏移 0x28 直读对象（最可靠）。
// v1.11.1：不再被调用（官方链已自证 seekTo，且偏移读在野指针 receiver 时会 SIGSEGV）。
// 保留定义备查；标记 unused 避免编译警告。
__attribute__((unused))
static void JAFallbackSeek(id sdPlayer) {
    if (!sdPlayer) return;
    NSNumber *ts = JAVal(sdPlayer, @"currentTimeStamp");
    if (!ts || ts.longLongValue <= 0) return;
    SEL seek = NSSelectorFromString(@"seekTo:duration:");
    // 1) 按偏移 0x28 直读（反汇编：seekTo receiver = self+0x28，且该对象持 currentTimeStamp）
    // ARC 下 ObjC 指针不能裸转 C 指针/id*：用整数算术 + __bridge id 完全避开 cast 禁令
    id vm = nil;
    @try {
        uintptr_t base = (uintptr_t)(__bridge void *)sdPlayer;
        vm = (__bridge id)(*(void **)(base + 0x28));
    } @catch (NSException *e) { vm = nil; }
    if (vm) {
        JALog(@"[兜底] self+0x28 = %@ (类=%@) seekTo响应=%d",
              vm, NSStringFromClass([vm class]),
              [vm respondsToSelector:seek] ? 1 : 0);
        if (seek && [vm respondsToSelector:seek]) {
            JALog(@"[兜底] 强制定位 viewModel.seekTo:duration:(%lld, 0)", ts.longLongValue);
            ((void(*)(id, SEL, long long, long long))objc_msgSend)(vm, seek, ts.longLongValue, 0);
            return;
        }
    }
    // 2) 老方案：KVC 常用名探测（保底）
    NSArray *vmKeys = @[@"viewModel", @"rtcSDPlayViewModel", @"sdkPlayViewModel",
                        @"playerViewModel", @"liveViewModel", @"playViewModel"];
    for (NSString *k in vmKeys) {
        id o = nil;
        @try { o = [sdPlayer valueForKey:k]; } @catch (NSException *e) { o = nil; }
        if (o && seek && [o respondsToSelector:seek]) {
            JALog(@"[兜底] KVC %@ → %@ 强制定位 seekTo:duration:(%lld, 0)",
                  k, NSStringFromClass([o class]), ts.longLongValue);
            ((void(*)(id, SEL, long long, long long))objc_msgSend)(o, seek, ts.longLongValue, 0);
            return;
        }
    }
    JALog(@"[兜底] 未找到可定位的 viewModel（偏移0x28无对象且KVC全空）");
}

static void ja_sd_respDeviceSdEventList(id self, SEL _cmd, id arg) {
    // v1.11.1：守卫——resp 回调的 receiver 必须仍是当前活跃 SDPlayer。
    // 实测闪退：返回详情后再点看录像（第二次 push），官方回调携带已释放的旧 SDPlayer，
    // hook 对野指针做偏移读 + 向残留值(1792368000)发消息 → SIGSEGV。
    // 指针比较是纯 C，不向对象发消息，绝对安全。
    if (self != g_activeSDPlayer) {
        JALog(@"[respDeviceSdEventList:] ⚠ receiver≠当前活跃SDPlayer（self=%p active=%p），直接透传原实现",
              self, g_activeSDPlayer);
        if (g_orig_sd_respEventList) ((void(*)(id, SEL, id))g_orig_sd_respEventList)(self, _cmd, arg);
        return;
    }
    // v1.10：标记 SD 回放活跃（getter 层开闸依赖此标志；JALiveManager 无单例，setter 方案已弃）
    JASDPlayerActive = YES;
    NSNumber *ts = JAVal(self, @"currentTimeStamp");
    long long dayStart = JADayStartSec(ts);
    id cam = JAVal(self, @"myCamera");
    if (dayStart > 0 && cam) {
        JASet(cam, @"sdSelectiontDay", @(dayStart));
        JALog(@"[respDeviceSdEventList:] 消费前强制设回 cam.sdSelectiontDay=%lld", dayStart);
    }
    id sd = cam ? JAVal(cam, @"sdSelectiontDay") : nil;
    JALog(@"[respDeviceSdEventList:] self=%p class=%@ arg=%@ (%@)",
          self, NSStringFromClass([self class]), arg,
          [arg isKindOfClass:NSArray.class]
          ? [NSString stringWithFormat:@"数组 count=%lu", (unsigned long)[arg count]]
          : NSStringFromClass([arg class]));
    JALog(@"  SDPlayer.currentTimeStamp=%@ cam.sdSelectiontDay=%@", ts, sd);
    if ([arg isKindOfClass:NSArray.class]) {
        NSUInteger n = [arg count];
        for (NSUInteger i = 0; i < n; i++) {
            // v1.8：全量 dump 属性（v1.11 取消 3 条限制，确认报警点是否被某事件段覆盖）
            JADumpEventModel([arg objectAtIndex:i], i);
        }
    } else if ([arg isKindOfClass:NSDictionary.class]) {
        JALog(@"  字典 keys=%@", [arg allKeys]);
    }
    if (g_orig_sd_respEventList) ((void(*)(id, SEL, id))g_orig_sd_respEventList)(self, _cmd, arg);
    // v1.11.1：不再调用 JAFallbackSeek —— v1.10 已证明官方消费链自己会 seekTo，
    // 兜底对 self+0x28 偏移读在"receiver=已释放旧SDPlayer"时会向残留值发消息 → SIGSEGV。
    // （兜底从未成功定位过：+0x28 实测是 UINavigationItem，KVC 全空，纯风险无收益）
}

// v1.8 诊断：官方按时间戳在 eventList 里找事件（respDeviceSdEventList: 消费链关键一步）
// v1.11.1：守卫——receiver 必须仍是当前活跃 SDPlayer（防官方回调已释放旧实例）
static id ja_sd_getCurrentEventWithTimeStamp(id self, SEL _cmd, long long ts) {
    if (self != g_activeSDPlayer) {
        if (g_orig_getCurrentEvent) return ((id(*)(id, SEL, long long))g_orig_getCurrentEvent)(self, _cmd, ts);
        return nil;
    }
    id ret = g_orig_getCurrentEvent
        ? ((id(*)(id, SEL, long long))g_orig_getCurrentEvent)(self, _cmd, ts)
        : nil;
    JALog(@"[getCurrentEventWithTimeStamp:] ts=%lld 返回=%@ (%@)",
          ts, ret, ret ? NSStringFromClass([ret class]) : @"nil");
    if (ret) {
        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList([ret class], &pc);
        NSMutableString *line = [NSMutableString stringWithFormat:@"  命中事件属性: "];
        for (unsigned int i = 0; i < pc && i < 20; i++) {
            const char *name = property_getName(props[i]);
            NSString *pn = [NSString stringWithUTF8String:name];
            id v = nil;
            @try { v = [ret valueForKey:pn]; } @catch (NSException *e) { v = @"<异常>"; }
            if (v) [line appendFormat:@"%@=%@ ", pn, v];
        }
        free(props);
        JALog(@"  %@", line);
    }
    return ret;
}

// v1.8 诊断：seekTo:duration: —— 定位播放是否执行（官方消费链最后一步）
// v1.11.1：守卫——receiver 必须仍是当前活跃 SDPlayer（防官方回调已释放旧实例）
static void ja_sd_seekTo_duration(id self, SEL _cmd, long long sec, double dur) {
    if (self != g_activeSDPlayer) {
        if (g_orig_seekTo) ((void(*)(id, SEL, long long, double))g_orig_seekTo)(self, _cmd, sec, dur);
        return;
    }
    JALog(@"[seekTo:duration:] sec=%lld duration=%.1f (定位执行 ✓)", sec, dur);
    if (g_orig_seekTo) ((void(*)(id, SEL, long long, double))g_orig_seekTo)(self, _cmd, sec, dur);
}

// v1.9/v1.10 诊断+修复：JALiveManager.detectType getter
// v1.10：官方消费链闸门2（detectType==-1 跳过 seekTo）。JALiveManager 无单例
// （sharedInstance 等均无响应），setter 方案失效 → 直接在 getter 层开闸：
// 我们的 SDPlayer 活跃期间强制返回 0，其余场景透传原值。
static long long ja_live_detectType(id self, SEL _cmd) {
    long long ret = g_orig_live_detectType
        ? ((long long(*)(id, SEL))g_orig_live_detectType)(self, _cmd)
        : -1;
    if (JASDPlayerActive) {
        if (ret != 0) JALog(@"[JALiveManager.detectType] 原值=%lld → 强制返回 0（SD 回放开闸）", ret);
        return 0;
    }
    JALog(@"[JALiveManager.detectType] 当前值=%lld (非SD回放)", ret);
    return ret;
}

// v1.9/v1.10 诊断+修复：JALiveManager.isEnterBackPlayer getter
// v1.10：官方消费链闸门1（==0 跳过消费）→ 活跃期强制返回 YES
// v1.13：每次先记录真实值到 g_lastRealEnterBack（p2p_starPlayBack 建流分支判断用）
static long long ja_live_isEnterBackPlayer(id self, SEL _cmd) {
    long long ret = g_orig_live_isEnterBackPlayer
        ? ((long long(*)(id, SEL))g_orig_live_isEnterBackPlayer)(self, _cmd)
        : 0;
    g_lastRealEnterBack = ret;  // v1.13：记录真实值（建流判断依据）
    if (JASDPlayerActive) {
        if (ret != 1) JALog(@"[JALiveManager.isEnterBackPlayer] 原值=%lld → 强制返回 1（SD 回放开闸）", ret);
        return 1;
    }
    JALog(@"[JALiveManager.isEnterBackPlayer] 当前值=%lld (非SD回放)", ret);
    return ret;
}

// v1.14：JALiveManager.isStarBackPlayer getter —— 建流路径全开
// MYP2PChannel selectTimeStamp:（0x100c7fa20）分支：isStarBackPlayer==1 → "播放中定位"
// （setRecordTimeStamp + 10s 超时，不调 p2p_starPlayBack → 永不建流）；==0 → 建流路径。
// 设备可能残留 isStarBackPlayer=1 状态（上次回放未清），导致 p2p_starPlayBack 永不触发。
// 本 hook：SD 回放活跃且本次会话还没建流（!g_startReplaySent）→ 强制返回 0，
// 让官方走 setSelectTimeStamp + p2p_starPlayBack 建流路径；建流后透传真实值
// （播放中 seek 定位路径恢复）。真实值始终记录到 g_lastRealStarBack 供 p2p hook 判断。
static long long ja_live_isStarBackPlayer(id self, SEL _cmd) {
    long long ret = g_orig_live_isStarBackPlayer
        ? ((long long(*)(id, SEL))g_orig_live_isStarBackPlayer)(self, _cmd)
        : -1;
    g_lastRealStarBack = ret;
    if (g_forceStarZero) return 0;   // v1.14：建流窗口内强制 0（官方读到 star==0 才走 startReplay 建流）
    if (JASDPlayerActive && !g_startReplaySent) {
        if (ret != 0) JALog(@"[JALiveManager.isStarBackPlayer] 原值=%lld → 强制返回 0（建流前）", ret);
        return 0;
    }
    return ret;
}

// v1.9 诊断：viewModel.seekTo:duration: —— 官方消费链实际调用者（receiver=SDPlayer+0x28）
// 签名 (id, SEL, long long, long long)：x2=绝对秒、x3=0
static void ja_vm_seekTo_duration(id self, SEL _cmd, long long sec, long long dur) {
    JALog(@"[viewModel seekTo:duration:] self=%@ sec=%lld dur=%lld (定位执行 ✓)",
          NSStringFromClass([self class]), sec, dur);
    if (g_orig_vm_seekTo) ((void(*)(id, SEL, long long, long long))g_orig_vm_seekTo)(self, _cmd, sec, dur);
}

// v1.11 诊断：noneVideoViewIsShow:dayEnd: —— "当前时间无录像"大字提示的触发时机与参数
// 反汇编 0x100b77360：[self+0x28 noneVideoViewIsShow:1 dayEnd:0]（receiver 实际挂 SDPlayer）
// 打印调用时刻、参数（dayStart/dayEnd）与当前 currentTimeStamp，判断是"无录像数据"还是"播放未起"
static void ja_sd_noneVideoViewIsShow(id self, SEL _cmd, long long dayStart, long long dayEnd) {
    // v1.11.1：守卫——非当前活跃 SDPlayer 直接透传（防野指针 receiver）
    if (self != g_activeSDPlayer) {
        if (g_orig_noneVideoViewIsShow) {
            ((void(*)(id, SEL, long long, long long))g_orig_noneVideoViewIsShow)(self, _cmd, dayStart, dayEnd);
        }
        return;
    }
    NSNumber *ts = JAVal(self, @"currentTimeStamp");
    JALog(@"[noneVideoViewIsShow:dayEnd:] dayStart=%lld dayEnd=%lld currentTimeStamp=%@ (⚠ 当前时间无录像提示)",
          dayStart, dayEnd, ts);
    if (g_orig_noneVideoViewIsShow) {
        ((void(*)(id, SEL, long long, long long))g_orig_noneVideoViewIsShow)(self, _cmd, dayStart, dayEnd);
    }
}

// v1.11 诊断：respDeviceSDPlayerStatus: —— SD 播放器状态回调（播放是否真正启动/切源）
// v1.14 崩溃根治：参数【不是对象】是 int 状态码（0x100b75ecc 内 cmp w20,#0x21 + 跳表）。
// 旧签名 (id, SEL, id) 把 32 当对象指针 [arg class] → SIGSEGV（IPS 124424 定案）。
// 现在按数值打印，不再向参数发任何消息。
static void ja_sd_respDeviceSDPlayerStatus(id self, SEL _cmd, long long status) {
    // v1.11.1：守卫——非当前活跃 SDPlayer 直接透传（防野指针 receiver）
    if (self != g_activeSDPlayer) {
        if (g_orig_respSDPlayerStatus) ((void(*)(id, SEL, long long))g_orig_respSDPlayerStatus)(self, _cmd, status);
        return;
    }
    JALog(@"[respDeviceSDPlayerStatus:] status=%lld (SD 播放状态回调)", status);
    if (g_orig_respSDPlayerStatus) ((void(*)(id, SEL, long long))g_orig_respSDPlayerStatus)(self, _cmd, status);
}

// v1.13 核心修复：MYP2PChannel p2p_starPlayBack（IMP 0x100c7feac）
// 官方分支（反汇编定案）：
//   isEnterBackPlayer==0 && isStarBackPlayer==0 → startReplay:selectTimeStamp:complete:（建流）
//   否则 → seekReplay:selectTimeStamp:complete:（仅定位）
// v1.10 强制 isEnterBackPlayer=1 → 永远走 seekReplay → 无流可 seek → 设备不回播放回调。
// 本 hook：SD 回放活跃且本次会话还没建过流且真实 isEnterBackPlayer==0（官方尚未进入回放模式）
// → 临时关闭闸门强制 + 强制 isStarBackPlayer=0（g_forceStarZero，覆盖设备残留 star=1）
// → 调原 IMP 让官方读到 enter==0 && star==0 → startReplay 建流分支
// （startReplay 自带 [cam selectTimeStamp] = 报警时间戳，设备直接从报警时间起播）→ 恢复。
// 建流后 g_startReplaySent=YES：后续 seekTo 走原 IMP（isEnterBackPlayer 强制 1）→ seekReplay 定位 ✓
static void ja_p2p_starPlayBack(id self, SEL _cmd) {
    if (JASDPlayerActive && !g_startReplaySent && g_lastRealEnterBack == 0) {
        // v1.14：isStarBackPlayer 真实值记录在 g_lastRealStarBack（getter hook 记录），仅打日志参考；
        // 不论真实值是 0 还是 1，建流窗口都强制按 0 走（官方建流条件 enter==0 && star==0）
        JALog(@"[p2p_starPlayBack] 首次路径判定: 真实isEnterBackPlayer=%lld isStarBackPlayer=%lld → 构造建流窗口",
              g_lastRealEnterBack, g_lastRealStarBack);
        BOOL savedActive = JASDPlayerActive;
        JASDPlayerActive = NO;      // enter getter 透传真实值 0 → 原 IMP 读到 isEnterBackPlayer=0
        g_forceStarZero = YES;      // star getter 强制 0 → 原 IMP 读到 isStarBackPlayer=0 → startReplay 分支
        JALog(@"[p2p_starPlayBack] 已临时关闭闸门强制（enter=0, star=0），调原 IMP（官方将发 startReplay 建流）");
        if (g_orig_p2p_starPlayBack) ((void(*)(id, SEL))g_orig_p2p_starPlayBack)(self, _cmd);
        g_forceStarZero = NO;
        JASDPlayerActive = savedActive;
        g_startReplaySent = YES;
        JALog(@"[p2p_starPlayBack] 建流指令已发出（g_startReplaySent=YES），恢复闸门强制");
        return;
    }
    if (g_orig_p2p_starPlayBack) ((void(*)(id, SEL))g_orig_p2p_starPlayBack)(self, _cmd);
}

// v1.13 确认：respDeviceFirstFrameTimeStamp:（IMP 0x100b77d64）—— 设备回传首帧时间戳
// 出现即证明 SD 回放流已建立、画面开始渲染（"当前时间无录像"提示随之消除）
// v1.14 崩溃根治：参数是 long long 时间戳（0x100b77d64 内 x2 直接传下游），不是对象。
static void ja_sd_respFirstFrame(id self, SEL _cmd, long long ts) {
    if (self != g_activeSDPlayer) {
        if (g_orig_respFirstFrame) ((void(*)(id, SEL, long long))g_orig_respFirstFrame)(self, _cmd, ts);
        return;
    }
    JALog(@"[respDeviceFirstFrameTimeStamp:] ts=%lld (SD 回放流已建立，首帧到达 ✓)", ts);
    if (g_orig_respFirstFrame) ((void(*)(id, SEL, long long))g_orig_respFirstFrame)(self, _cmd, ts);
}

// v1.5：viewWillAppear hook —— 原实现后强制打开"拉取开关"
// 官方 viewWillAppear 判定：设备 sdSelectiontDay==0 → pendingReloadTodaySDSelectiontDay=0
// （不拉列表）→ 时间戳永远没机会被消费。这里强制设 = 报警日 0 点秒，
// 官方 viewDidAppear 就会走 getEventListWithSelectiontDay: 主动拉对应日期事件列表。
static void ja_sd_viewWillAppear(id self, SEL _cmd) {
    // v1.11.1：守卫——只有当前活跃 SDPlayer 才做强制重载（防官方回调已释放旧实例）
    if (self != g_activeSDPlayer) {
        if (g_orig_sd_vwa) ((void(*)(id, SEL))g_orig_sd_vwa)(self, _cmd);
        return;
    }
    JASDPlayerActive = YES;  // v1.10：进入 SD 回放 → getter 层开闸
    if (g_orig_sd_vwa) ((void(*)(id, SEL))g_orig_sd_vwa)(self, _cmd);
    NSNumber *ts = JAVal(self, @"currentTimeStamp");
    long long dayStart = JADayStartSec(ts);
    if (dayStart <= 0) {
        JALog(@"!! SDPlayer viewWillAppear: 无有效秒级时间戳，跳过强制重载");
        return;
    }
    JASet(self, @"pendingReloadTodaySDSelectiontDay", @(dayStart));
    JALog(@"SDPlayer viewWillAppear: 强制 pendingReloadTodaySDSelectiontDay=%lld (报警日0点UTC)", dayStart);
    // v1.7 双保险：官方 viewWillAppear 原实现已把设备 sdSelectiontDay 覆盖为"今天 0 点"，
    // 这里设回报警日 0 点，保证后续 reloadTimeLine / 消费偏移都按报警日算
    id cam = JAVal(self, @"myCamera");
    if (cam) {
        JASet(cam, @"sdSelectiontDay", @(dayStart));
        JALog(@"SDPlayer viewWillAppear: 设回 myCamera.sdSelectiontDay=%lld (防官方覆盖为今天)", dayStart);
    }
}

// v1.10：离开 SD 回放 → 关闭闸门强制（getter 恢复透传，避免影响官方其他页面）
// v1.11.1：若离开的是当前活跃 SDPlayer，同步清空守卫指针（防官方回调旧实例野指针）
// v1.13：重置建流标志（下次进入重新走 startReplay 建流）
static void ja_sd_viewWillDisappear(id self, SEL _cmd) {
    if (self == g_activeSDPlayer) {
        g_activeSDPlayer = nil;
        g_startReplaySent = NO;  // v1.13：会话结束，重置建流标志
    }
    JASDPlayerActive = NO;
    JALog(@"SDPlayer viewWillDisappear: 关闭闸门强制（JASDPlayerActive=NO, g_activeSDPlayer=%@, startReplaySent=%@）",
          g_activeSDPlayer ? NSStringFromClass([g_activeSDPlayer class]) : @"nil",
          g_startReplaySent ? @"YES" : @"NO");
    if (g_orig_sd_vwd) ((void(*)(id, SEL))g_orig_sd_vwd)(self, _cmd);
}

// v1.5：viewDidAppear hook —— 原实现后延迟 3s 主动补拉一次
// 官方 viewDidAppear 里 getEventListWithSelectiontDay: 在建链刚发起时调用，
// 设备可能尚未连上（拉取失败/丢弃）。3s 后设备通常已连接，补拉一次兜底。
static void ja_sd_viewDidAppear(id self, SEL _cmd) {
    // v1.11.1：守卫——只有当前活跃 SDPlayer 才做补拉（防官方回调已释放旧实例）
    if (self != g_activeSDPlayer) {
        if (g_orig_sd_vda) ((void(*)(id, SEL))g_orig_sd_vda)(self, _cmd);
        return;
    }
    if (g_orig_sd_vda) ((void(*)(id, SEL))g_orig_sd_vda)(self, _cmd);
    // v1.12：移除 3/7/12s 主动补拉。
    // 崩溃铁证（v1.11 110809 / v1.11.2 111655）：两次 EXC_BAD_ACCESS 地址 0x20，
    // 栈均为 libdispatch(dispatch_after) → dylib → objc_msgSend（receiver=0x20），
    // dylib 内唯一 dispatch_after = 本补拉闭包。补拉在 [live class]/valueForKey 处
    // 拿到 JADevicePlatform.live=0x20（官方消费链中 live 状态异常）→ SIGSEGV。
    // v1.11.2 实测日志证明官方 viewDidAppear 自己拉取列表已成功（resp 12 条、事件齐全、
    // seekTo 命中、getCurrentEventWithTimeStamp 命中），补拉（v1.5 设备未连上兜底）已无必要。
    // 官方链：viewWillAppear 强制 pendingReload → viewDidAppear 官方拉取 → resp → seekTo → 播放。
    JALog(@"SDPlayer viewDidAppear: 已由官方自行拉取事件列表（viewWillAppear 已强制 pendingReload=%lld）",
          JADayStartSec(JAVal(self, @"currentTimeStamp")));
}

// v1.15 核心：JANewRtcSDPlayViewController viewDidAppear（官方本地 SD 回放界面）
// 官方 viewDidLoad/setupData 已自动：setMyCamera 到 sharedInstance、setIsSDPlayer:YES、
// 建 viewModel、按 myCamera.sdSelectiontDay 设选中日、加载事件列表。
// 本 hook：官方 viewDidAppear 完成后，延迟 0.4s 调 startSDPlayWithSelectTimeStamp:
//（报警时间戳）→ viewModel startSDPlayShowWithSelectTimeStamp: → 官方建流播放并定位。
// 延迟理由：官方 UI/连接初始化需要时间，过早调用可能被官方 viewDidAppear 自己的
// 播放逻辑（默认今天当前时间）覆盖。g_rtcTargetSec 在 JATryOpenSDReplay 已记录。
static void ja_rtc_viewDidAppear(id self, SEL _cmd) {
    if (g_orig_rtc_vda) ((void(*)(id, SEL))g_orig_rtc_vda)(self, _cmd);
    if (self != g_activeSDPlayer) {
        JALog(@"[RTC-SD viewDidAppear] 非当前活跃实例，跳过自动定位");
        return;
    }
    long long sec = g_rtcTargetSec;
    if (sec < 1000000000LL) {
        JALog(@"[RTC-SD viewDidAppear] 无有效报警时间戳（%lld），跳过自动定位", sec);
        return;
    }
    JALog(@"[RTC-SD viewDidAppear] 官方展示完成，0.4s 后自动 startSDPlayWithSelectTimeStamp: %lld", sec);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer) {
            JALog(@"[RTC-SD] 延迟触发时已离开页面，跳过");
            return;
        }
        JALog(@"[RTC-SD] 调 startSDPlayWithSelectTimeStamp: %lld（直达报警时间点）", sec);
        SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
        if ([self respondsToSelector:s]) {
            ((void(*)(id, SEL, long long))objc_msgSend)(self, s, sec);
        } else {
            JALog(@"!! RTC-SD 无 startSDPlayWithSelectTimeStamp:");
        }
    });
}

// 防抖：同一详情页实例 2 秒内只 push 一次 SDPlayer（官方可能触发两次点击事件 → 双 push 闪烁）
// 裸指针存地址，不持有对象
static void *g_lastDetailVC = NULL;
static NSTimeInterval g_lastPushTime = 0;

static BOOL JADebounce(UIViewController *detailVC) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ((__bridge void *)detailVC == g_lastDetailVC && (now - g_lastPushTime) < 2.0) {
        JALog(@"!! 2 秒内重复触发（防抖拦截，避免双 push 闪烁）");
        return YES;
    }
    return NO;
}

// 原 selector：clickCloudRecordAction:
static void ja_clickCloudRecordAction(id self, SEL _cmd, id sender) {
    JADumpWarnInfo(self, @"clickCloudRecordAction: 已拦截（不再弹云存储）");
    if (JADebounce(self)) return;
    NSString *src = nil;
    id cam = JAFindCamera(self, JAVal(self, @"warnInfoEntityModelEx"), &src);
    JALog(@"camera 来源: %@  camera=%@", src, cam);
    if (cam) {
        JATryOpenSDReplay(self, JAVal(self, @"warnInfoEntityModelEx"), cam);
        g_lastDetailVC = (__bridge void *)self;
        g_lastPushTime = [NSDate timeIntervalSinceReferenceDate];
    } else {
        JALog(@"!! 无可用 camera，恢复官方逻辑（保留云存储引导，防崩溃）");
        if (g_orig_clickCloudRecordAction) {
            ((void(*)(id, SEL, id))g_orig_clickCloudRecordAction)(self, _cmd, sender);
        }
    }
}

// 原 selector：handleJumpToOpenCloud —— 不再拦截，转发原实现
static void ja_handleJumpToOpenCloud(id self, SEL _cmd) {
    if (g_orig_handleJumpToOpenCloud) {
        ((void(*)(id, SEL))g_orig_handleJumpToOpenCloud)(self, _cmd);
    }
}

// ---------- hook 安装（幂等：method_setImplementation 直接覆盖，防重复注入破坏） ----------

// 幂等安装：method_setImplementation 直接覆盖；重复注入不会把 hook 交换回原实现
static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        JALog(@"!! 方法不存在: %@", NSStringFromSelector(sel));
        return;
    }
    IMP cur = method_getImplementation(m);
    if (cur == newImp) {
        JALog(@"方法 %@ 已是本 hook（检测到重复注入，跳过，不破坏）", NSStringFromSelector(sel));
        return;
    }
    if (saved && !*saved) *saved = cur;
    method_setImplementation(m, newImp);
    JALog(@"hook %@ OK (old=%p new=%p)", NSStringFromSelector(sel), (void *)cur, (void *)newImp);
}

// v1.13：统一安装 SDPlayer 生命周期/消费链 hook（JAHook 轮询与 JATryOpenSDReplay 补装共用）
static void JASDInstallHooks(void) {
    if (JASDHooked) return;
    Class sdCls = NSClassFromString(@"JANewSDPlayerViewController");
    if (!sdCls) return;
    JASetImp(sdCls, @selector(viewWillAppear:), (IMP)ja_sd_viewWillAppear, &g_orig_sd_vwa);
    JASetImp(sdCls, @selector(viewDidAppear:), (IMP)ja_sd_viewDidAppear, &g_orig_sd_vda);
    JASetImp(sdCls, @selector(viewWillDisappear:), (IMP)ja_sd_viewWillDisappear, &g_orig_sd_vwd);
    // v1.6 诊断：hook 设备回传事件列表回调
    JASetImp(sdCls, @selector(respDeviceSdEventList:), (IMP)ja_sd_respDeviceSdEventList,
             &g_orig_sd_respEventList);
    // v1.8 诊断：hook 定位消费链（找事件 + seekTo 播放）
    JASetImp(sdCls, @selector(getCurrentEventWithTimeStamp:), (IMP)ja_sd_getCurrentEventWithTimeStamp,
             &g_orig_getCurrentEvent);
    JASetImp(sdCls, @selector(seekTo:duration:), (IMP)ja_sd_seekTo_duration,
             &g_orig_seekTo);
    // v1.11 诊断：无录像提示 + 播放状态回调（确认 seekTo 后播放链路状态）
    JASetImp(sdCls, @selector(noneVideoViewIsShow:dayEnd:), (IMP)ja_sd_noneVideoViewIsShow,
             &g_orig_noneVideoViewIsShow);
    JASetImp(sdCls, @selector(respDeviceSDPlayerStatus:), (IMP)ja_sd_respDeviceSDPlayerStatus,
             &g_orig_respSDPlayerStatus);
    // v1.13：首帧回调（确认建流成功后播放已启动）
    JASetImp(sdCls, @selector(respDeviceFirstFrameTimeStamp:), (IMP)ja_sd_respFirstFrame,
             &g_orig_respFirstFrame);
    JAHookLiveGates();
    JASDHooked = YES;
}

// v1.13：MYP2PChannel p2p_starPlayBack hook（类可能晚加载，幂等）
static void JAHookP2PChannel(void) {
    if (g_p2pHooked) return;
    Class p2pCls = NSClassFromString(@"MYP2PChannel");
    if (!p2pCls) return;
    JASetImp(p2pCls, NSSelectorFromString(@"p2p_starPlayBack"), (IMP)ja_p2p_starPlayBack,
             &g_orig_p2p_starPlayBack);
    g_p2pHooked = YES;
}

static BOOL JAHooked = NO;    // 详情页 hook（clickCloudRecordAction 主链）
// JASDHooked 已在核心逻辑区前置声明处定义（v1.5 SDPlayer 生命周期 hook 标志）

static void JAHook(void) {
    // 详情页主链
    if (!JAHooked) {
        Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
        if (detailCls) {
            // 检测旧版本（exchange 式 swizzle）残留的 _jasd_ selector → 提示用户清理 TrollFools 旧项
            if ([detailCls instancesRespondToSelector:NSSelectorFromString(@"_jasd_clickCloudRecordAction:")]) {
                JALog(@"!! 检测到旧版 dylib 残留的 _jasd_ 方法，建议 TrollFools 删除旧项只留最新（v1.3 本身幂等，不影响）");
            }

            JASetImp(detailCls, @selector(clickCloudRecordAction:), (IMP)ja_clickCloudRecordAction,
                     &g_orig_clickCloudRecordAction);
            JASetImp(detailCls, @selector(handleJumpToOpenCloud), (IMP)ja_handleJumpToOpenCloud,
                     &g_orig_handleJumpToOpenCloud);

            JAHooked = YES;
        }
    }
    // v1.5：SDPlayer 生命周期 hook（类可能晚加载，轮询重试）
    if (!JASDHooked) {
        JASDInstallHooks();
        if (!JASDHooked) {
            JALog(@"!! JANewSDPlayerViewController 尚未加载（轮询重试）");
        }
    }
    // v1.13：MYP2PChannel p2p_starPlayBack 建流 hook（类可能晚加载，轮询重试）
    if (!g_p2pHooked) {
        JAHookP2PChannel();
        if (!g_p2pHooked) {
            JALog(@"!! MYP2PChannel 尚未加载（轮询重试）");
        }
    }
    // v1.15：JANewRtcSDPlayViewController viewDidAppear hook（自动定位报警时间，类可能晚加载）
    if (!g_rtcHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
            g_rtcHooked = YES;
            JALog(@"RTC-SD viewDidAppear hook 已装（轮询补装）");
        } else {
            JALog(@"!! JANewRtcSDPlayViewController 尚未加载（轮询重试）");
        }
    }
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.15 injected");
    if (NSClassFromString(@"JANewsWarnInfoDetailVC")
        && NSClassFromString(@"JANewRtcSDPlayViewController")) {
        JAHook();
        return;
    }
    __block int tries = 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // v1.13：轮询条件含 g_p2pHooked（MYP2PChannel 建流 hook 必须装上才停）
        while (tries < 30 && !(JAHooked && JASDHooked && g_p2pHooked && g_rtcHooked)) {
            [NSThread sleepForTimeInterval:0.5];
            tries++;
            dispatch_async(dispatch_get_main_queue(), ^{ JAHook(); });
        }
        if (!JAHooked) {
            JALog(@"!! 30 次重试后仍未找到 JANewsWarnInfoDetailVC");
        }
        if (!JASDHooked) {
            JALog(@"!! 30 次重试后仍未找到 JANewSDPlayerViewController（v1.5 生命周期 hook 未装）");
        }
        if (!g_p2pHooked) {
            JALog(@"!! 30 次重试后仍未找到 MYP2PChannel（v1.13 建流 hook 未装，点看录像时会再补装）");
        }
    });
}
