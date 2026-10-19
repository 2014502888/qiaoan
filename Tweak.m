// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.17（TrollStore 兼容：纯 runtime hook + C IMP，零类依赖，可直接 clang 编译）
//
// v1.17 修复「时间轴拖条不跟随定位 / 播放时间变成最新」：
//   只读溯源（反汇编 startSDPlayWithSelectTimeStamp: 0x100b07b0c →
//   viewModel startSDPlayShowWithSelectTimeStamp: 0x100b0c730 → block 执行体
//   0x100b0c9cc → isEnterSDPlay ? seekSDPlayWithSelectTimeStamp: : 
//   startSDPlayWithSelectTimeStamp:）确认定位链正确，根因 = 延迟 0.4s 调用时
//   官方播放器未就绪（block 预检查 streamCtx/isSeekingPlay 失败 → 定位不执行，
//   官方默认播最新）→ 时间轴指示器停在最新。
//   修法：延迟 0.4s → 3.0s（等官方建流完成）+ hook respDeviceFirstFrameTimeStamp:
//   （参数是数值 long long，v1.14 定案）确认首帧时间≈报警时间，不匹配自动重试
//   startSDPlayWithSelectTimeStamp:（最多 3 次，间隔 1.5s）→ 时间轴指示器随
//   播放进度自然定位到报警时间点。
//   另确认：RTC 版 viewWillAppear（0x100af4a90）不覆盖 sdSelectiontDay（我们
//   KVC 喂的报警日保留，setupData 按报警日加载事件列表）。
//
// 功能：报警消息详情页点「看录像」→ 不再弹云存储 → 直接 push 官方本地 SD 回放界面
//       JANewRtcSDPlayViewController，并自动定位到报警时间点播放（用户未开通云存储，
//       录像在本地 SD 卡）。
//
// v1.15 定案（用户实测 + 二进制方法列表 + 反汇编）：
//   官方本地 SD 回放界面 = JANewRtcSDPlayViewController（时间轴拖条/日历选日/
//   SD 卡容量检测/变速/录音，即用户手机手动进本地回放看到的界面）。
//   之前 push 的 JANewSDPlayerViewController 是另一播放器（旧版/云回放共用），
//   界面完全不同 → 黑屏。v1.15 起换目标 VC。
//
// 初始化（反汇编 viewDidLoad 0x100af4498 定案）：
//   RTC 版 viewDidLoad 自动：JADevicePlatform.sharedInstance setMyCamera:self.myCamera、
//   setIsSDPlayer:YES、创建 viewModel、setupUI —— 只需喂 myCamera + currentTimeStamp。
//   myCamera 无公开 setter → KVC [vc setValue:cam forKey:@"myCamera"]。
//
// 自动定位（反汇编 startSDPlayWithSelectTimeStamp: 0x100b07b0c 定案）：
//   startSDPlayWithSelectTimeStamp:sec → viewModel startSDPlayShowWithSelectTimeStamp:sec
//   → 官方建流播放并定位到 sec。本 dylib hook viewDidAppear，官方展示完成后延迟 0.4s
//   调 startSDPlayWithSelectTimeStamp:（报警时间戳）→ 直达报警时间点。
//   闸门：RTC 版是官方完整播放器，官方链自己建流 → 不做任何状态强制（v1.10~v1.14
//   的 isEnterBackPlayer/isStarBackPlayer/detectType 强制、p2p 建流修复全部移除）。
//
// 实测（v1.15，jasdreplay (8).log）：
//   连续 6 次点「看录像」全部成功 —— 时间戳全部秒级提取、push RTC 播放器、
//   viewDidAppear 后自动 startSDPlayWithSelectTimeStamp: 报警秒；两台设备
//   （WY5NT5B3ANSDAGV1111A / NBDEWTHYAZ6YG1R7111A）均正常。
//
// 历史决策链（git 有完整提交记录）：
//   v1.0~v1.3：弹云存储根因 = 旧 dylib 未删双层加载 / 拦截方法还原；改 method_setImplementation 幂等。
//   v1.4：时间戳单位错（毫秒→秒），event_file_url 内嵌秒提取。
//   v1.5~v1.7：旧 VC 事件列表不拉取（sdSelectiontDay==0）→ 强制 pendingReload。
//   v1.8~v1.9：MYEventModel 字段 dump、seekTo 两道闸门（isEnterBackPlayer/detectType）。
//   v1.10：getter 层开闸，seekTo 首次被官方消费（sec=1792378567）但画面仍无录像。
//   v1.11：崩溃（dispatch_after 补拉闭包 receiver=0x20）→ v1.11.1 移除 setIsSDPlayer:YES。
//   v1.12：移除补拉闭包；v1.13：p2p_starPlayBack 建流分支（startReplay vs seekReplay）。
//   v1.14：崩溃根治 —— respDeviceSDPlayerStatus:/respDeviceFirstFrameTimeStamp: 参数是
//           数值不是对象（IPS 124424 + 反汇编 cmp w20,#0x21 跳表定案），旧签名向 32 发消息 SIGSEGV。
//   v1.15：定案跳错界面 → 换 RTC 播放器，全链路打通（见上）。
//   v1.16：清理 v1.5~v1.14 在旧 VC 上的全部残留 hook/闸门/建流代码，只保留 RTC 链路。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------- 日志 ----------

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

// ---------- KVC 工具 ----------

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

// 从秒级时间戳算"报警日 0 点秒"（本地时区语义 = 北京时间 00:00）
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

// ---------- 核心：打开官方本地 SD 回放并定位 ----------

// 前置声明（实现位于下方 hook 区，JATryOpenSDReplay 需提前引用）
static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved);
static void ja_rtc_viewDidAppear(id self, SEL _cmd);
static void ja_rtc_viewWillDisappear(id self, SEL _cmd, BOOL animated);
static void ja_rtc_respFirstFrame(id self, SEL _cmd, long long ts);
static void JATimeLineSyncToSec(id sdVC, long long sec);

// v1.15：当前活跃 RTC SD 播放器指针（纯 C 比较守卫，不向对象发消息）
static id g_activeSDPlayer = nil;
static BOOL g_rtcHooked = NO;        // JANewRtcSDPlayViewController viewDidAppear hook 已装
static IMP g_orig_rtc_vda = NULL;    // 原 viewDidAppear: IMP
static long long g_rtcTargetSec = 0; // 报警时间戳（秒），viewDidAppear 后自动定位播放
// v1.17：首帧确认 + 自动重试（时间轴拖条不跟随定位的根治）
static BOOL g_rtcFirstFrameHooked = NO;  // respDeviceFirstFrameTimeStamp: hook 已装
static IMP g_orig_rtc_firstframe = NULL; // 原 respDeviceFirstFrameTimeStamp: IMP（数值签名）
static BOOL g_rtcLocated = NO;           // 首帧已确认定位到报警时间点
static int  g_rtcRetryCount = 0;         // 重试次数（最多 3 次）
// v1.20：离开回放页时停官方 SD 播放（stopSDPlay）释放底层流 → 下次进入重新建流定位；
// viewDidAppear 去重（官方可能多次触发 viewDidAppear → 只保留最后一次的 3.0s 定位）。
static IMP g_orig_rtc_vwd = NULL;              // 原 viewWillDisappear: IMP
static unsigned long long g_rtcVdaGen = 0;     // viewDidAppear 世代计数（去重）

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    JALog(@"--- JATryOpenSDReplay (camera=%@ class=%@ uid=%@) ---",
          cam, cam ? NSStringFromClass([cam class]) : @"nil", JAVal(cam, @"uid"));
    // 目标界面 = 官方本地 SD 回放 JANewRtcSDPlayViewController（RTC 完整播放器，
    // 时间轴/日历/SD 卡检测/播放控制；用户手动进本地回放看到的就是它）。
    Class cls = NSClassFromString(@"JANewRtcSDPlayViewController");
    if (!cls) {
        JALog(@"!! JANewRtcSDPlayViewController 类不存在");
        return;
    }
    // RTC viewDidAppear hook 补装（类晚加载/轮询错过场景兜底）
    if (!g_rtcHooked) {
        JASetImp(cls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
        JASetImp(cls, @selector(viewWillDisappear:), (IMP)ja_rtc_viewWillDisappear, &g_orig_rtc_vwd);
        g_rtcHooked = YES;
    }
    // v1.17：respDeviceFirstFrameTimeStamp: hook 补装（数值签名 (id,SEL,long long)，
    // 首帧时间确认 + 不匹配自动重试，时间轴拖条跟随定位的根治）
    if (!g_rtcFirstFrameHooked) {
        JASetImp(cls, @selector(respDeviceFirstFrameTimeStamp:), (IMP)ja_rtc_respFirstFrame,
                 &g_orig_rtc_firstframe);
        g_rtcFirstFrameHooked = YES;
    }
    id vc = [[cls alloc] init];
    JALog(@"已创建 SDPlayer(RTC): %@ class=%@", vc, NSStringFromClass([vc class]));

    // 1) myCamera 用 KVC（RTC 版无 setMyCamera: 公开方法）。
    // 官方 viewDidLoad 会自己读 self.myCamera → setMyCamera: 到 JADevicePlatform.sharedInstance
    //（反汇编 0x100af461c 定案），这里只需把 camera 挂到 VC 上。
    @try {
        [vc setValue:cam forKey:@"myCamera"];
        id chk = [vc valueForKey:@"myCamera"];
        JALog(@"setMyCamera(KVC) 后 RTC.myCamera=%@ uid=%@", chk, JAVal(chk, @"uid"));
    } @catch (NSException *e) {
        JALog(@"!! setValue myCamera 异常: %@", e);
    }

    // 2) 事件与时间戳
    if (warn) {
        JASet(vc, @"currentEvent", warn);
        NSNumber *ts = JABuildTimestamp(warn);
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        // 校验秒范围：10 位秒级（1.0e9 ~ 9.9e9），防止再传毫秒
        long long tv = ts ? ts.longLongValue : 0;
        JALog(@"currentTimeStamp=%@ (%lld 秒 → %@)", ts, tv,
              tv >= 1000000000LL && tv < 10000000000LL
              ? @"秒级 ✓" : @"⚠ 非秒级！");
        // 记录报警时间戳（秒），RTC viewDidAppear 后自动 startSDPlayWithSelectTimeStamp:
        if (tv >= 1000000000LL && tv < 10000000000LL) g_rtcTargetSec = tv;
        // 补设设备 SD 选中日期 = 报警日 0 点秒 —— RTC setupData（0x100af6104）会
        // 读 myCamera.sdSelectiontDay → setCurrentSelectedSDDay:（选中日）→ 加载该日事件列表
        long long dayStart = JADayStartSec(ts);
        if (dayStart > 0 && cam) {
            JASet(cam, @"sdSelectiontDay", @(dayStart));
            JALog(@"已设 myCamera.sdSelectiontDay=%lld (报警日0点UTC)", dayStart);
        }
        JALog(@"已设置 currentEvent/currentTimeStamp (RTC)");
    }

    // 3) push
    UINavigationController *nav = detailVC.navigationController;
    if (!nav) nav = JATopVC().navigationController;
    if (nav) {
        g_activeSDPlayer = vc;  // 登记当前活跃 RTC SD 播放器（viewDidAppear hook 守卫用）
        [nav pushViewController:vc animated:YES];
        // RTC 版是官方完整播放器，官方链自己建流 → 不做任何状态强制
        JALog(@"已 push SDPlayer(RTC)（官方原生链播放，不做状态强制）");
    } else {
        JALog(@"!! 无 navigationController，改为 present");
        [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:vc animated:YES completion:nil];
    }
}

// ---------- 诊断 dump ----------

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
// v1.18：用户实测画面已播报警时间，但底部时间轴拖条指示器仍停最新 ——
// 反汇编定案：VC setCurrentTimeStamp:（0x100b0bf30）是纯 ivar setter（str x2
// → ivar，ret），官方播放进度从不驱动时间轴；时间轴指示器唯一更新入口 =
// JATimeLineView changeCurrentTimeStamp:（0x1000ff834：setCurrentSec: +
// adjustScrollViewOffsetAtCurrentSec 滚动 + setLastDisplaySec: + 更新顶部时间标签）。
// 修法：定位调用后再延迟 1.0s，主动调 timeLineView changeCurrentTimeStamp:sec
// → 指示器/滚动位置/时间标签全部拨到报警时间点。
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
    // 重置 v1.17 重试状态（每次进入页面重新开始）
    g_rtcLocated = NO;
    g_rtcRetryCount = 0;
    // v1.20：世代去重 —— 官方可能多次触发 viewDidAppear（(5).log 首次进入触发 3 次，
    // 每次都生成 3.0s 定位 → 建流/seek 竞争导致后续进入播最新），只保留最后一次生效
    unsigned long long myGen = ++g_rtcVdaGen;
    JALog(@"[RTC-SD viewDidAppear] 官方展示完成，3.0s 后自动 startSDPlayWithSelectTimeStamp: %lld (gen=%llu)", sec, myGen);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) {
            JALog(@"[RTC-SD] 延迟触发时已离开页面/已有更新触发（gen=%llu vs %llu），跳过", myGen, g_rtcVdaGen);
            return;
        }
        JALog(@"[RTC-SD] 调 startSDPlayWithSelectTimeStamp: %lld（直达报警时间点）", sec);
        SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
        if ([self respondsToSelector:s]) {
            ((void(*)(id, SEL, long long))objc_msgSend)(self, s, sec);
        } else {
            JALog(@"!! RTC-SD 无 startSDPlayWithSelectTimeStamp:");
        }
        // v1.18：播放定位已发出，再等 1.0s 拨时间轴指示器到报警时间点
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) {
                JALog(@"[RTC-SD] 拨时间轴时已离开页面/已有更新触发，跳过");
                return;
            }
            JATimeLineSyncToSec(self, sec);
        });
    });
}

// v1.20：离开回放页时停官方 SD 播放 → 释放底层流。
// 背景：第二次起偶发"定位不生效、直接播最新"——底层 JALiveManager 流被复用，
// startSDPlayWithSelectTimeStamp: 走 seekSDPlay 分支有前置闸门（0x103429ee0 bit0），
// 复用场景闸门不过 → seek 被跳过 → 播最新。修法：每次离开页把流停掉，
// 下次进入官方像第一次一样全新建流定位（startSDPlay 分支），可靠跳到报警时间点。
static void ja_rtc_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    if (g_orig_rtc_vwd) ((void(*)(id, SEL, BOOL))g_orig_rtc_vwd)(self, _cmd, animated);
    if (self == g_activeSDPlayer) {
        SEL s = NSSelectorFromString(@"stopSDPlay");
        if ([self respondsToSelector:s]) {
            JALog(@"[RTC-SD] viewWillDisappear: 调官方 stopSDPlay（释放底层流，下次进入重新建流）");
            ((void(*)(id, SEL))objc_msgSend)(self, s);
        } else {
            JALog(@"!! viewWillDisappear: RTC-SD 无 stopSDPlay 方法");
        }
        g_activeSDPlayer = nil;
    }
}

// v1.18：把官方时间轴指示器/滚动位置/时间标签同步到指定秒。
// 链：VC.timeLineView（懒加载 getter，自动创建并初始化）→
//     [timeLineView changeCurrentTimeStamp:sec]（官方 API 0x1000ff834：
//     内部 setCurrentSec: + adjustScrollViewOffsetAtCurrentSec + setLastDisplaySec:）。
// v1.19 关键修正：changeCurrentTimeStamp: 的入参是「当日内的相对秒」（0~86399），
// 不是绝对 Unix 秒！v1.18 实测传 1792407777（绝对秒）→ 官方按 秒/3600 算小时
// → 标签显示 497891:02:57（应为 19:02:57），指示器滚出当日范围 → 拖动无录像。
// 修正：相对秒 = 报警秒 - 北京当日0点（= myCamera.sdSelectiontDay，日志确认
// 1792407777 - 1792339200 = 68577 = 19:02:57）。兜底公式 (sec + 28800) % 86400。
static void JATimeLineSyncToSec(id sdVC, long long sec) {
    @autoreleasepool {
        long long dayStart = 0;
        @try {
            dayStart = [[sdVC valueForKeyPath:@"myCamera.sdSelectiontDay"] longLongValue];
        } @catch (NSException *e) {
            JALog(@"!! 读 sdSelectiontDay 异常: %@", e);
        }
        if (dayStart < 1000000000LL) {
            // 兜底：北京当日0点（UTC 秒）= sec - ((sec + 28800) % 86400)
            dayStart = sec - ((sec + 28800LL) % 86400LL);
            JALog(@"[RTC-SD] sdSelectiontDay 不可读，兜底 dayStart=%lld", dayStart);
        }
        long long rel = sec - dayStart;   // 当日相对秒 0~86399
        if (rel < 0) rel = 0;
        if (rel > 86399) rel = 86399;
        JALog(@"[RTC-SD] 时间轴参数: 绝对=%lld 当日0点=%lld → 相对秒=%lld (应≈时:分:秒)", sec, dayStart, rel);

        id tl = nil;
        @try { tl = [sdVC valueForKey:@"timeLineView"]; }
        @catch (NSException *e) { JALog(@"!! timeLineView KVC 异常: %@", e); }
        if (!tl) {
            JALog(@"!! timeLineView 为 nil，无法拨时间轴");
            return;
        }
        SEL c = NSSelectorFromString(@"changeCurrentTimeStamp:");
        if ([tl respondsToSelector:c]) {
            ((void(*)(id, SEL, long long))objc_msgSend)(tl, c, rel);
            JALog(@"[RTC-SD] changeCurrentTimeStamp: 已调用（相对秒 %lld → 指示器/标签应正确）", rel);
        } else {
            JALog(@"!! timeLineView 无 changeCurrentTimeStamp:");
        }
    }
}

// v1.17 核心：respDeviceFirstFrameTimeStamp: hook —— 首帧时间确认 + 自动重试。
// 注意：该回调参数 x2 是数值（long long 秒），不是对象（v1.14 反汇编 0x100b77d64 /
// 0x100afdd0c + IPS 124424 定案），hook 必须用数值签名，严禁 (id,SEL,id)。
// 首帧时间 ≈ 报警时间 → 定位成功（时间轴指示器随播放进度自然到位）；
// 首帧时间 ≠ 报警时间（官方播了最新）→ 1.5s 后重试 startSDPlayWithSelectTimeStamp:，
// 最多 3 次，成功后停止。
static void ja_rtc_respFirstFrame(id self, SEL _cmd, long long ts) {
    if (g_orig_rtc_firstframe) {
        ((void(*)(id, SEL, long long))g_orig_rtc_firstframe)(self, _cmd, ts);
    }
    if (self != g_activeSDPlayer || g_rtcTargetSec < 1000000000LL || g_rtcLocated) {
        return;
    }
    long long diff = ts - g_rtcTargetSec;
    if (diff < 0) diff = -diff;
    if (diff <= 2) {
        g_rtcLocated = YES;
        JALog(@"[RTC-SD 首帧] ts=%lld == 报警 %lld ✓ 已定位（时间轴应已指向报警时间点）", ts, g_rtcTargetSec);
        return;
    }
    JALog(@"[RTC-SD 首帧] ts=%lld ≠ 报警 %lld（差 %llds）→ 官方播了其他时间，准备重试", ts, g_rtcTargetSec, diff);
    if (g_rtcRetryCount >= 3) {
        JALog(@"[RTC-SD] 重试次数用尽（3/3），保持现状（可能该日无录像）");
        return;
    }
    g_rtcRetryCount++;
    JALog(@"[RTC-SD] 第 %d 次重试：1.5s 后再调 startSDPlayWithSelectTimeStamp:", g_rtcRetryCount);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self != g_activeSDPlayer || g_rtcLocated) return;
        JALog(@"[RTC-SD] 重试 startSDPlayWithSelectTimeStamp: %lld（第 %d 次）", g_rtcTargetSec, g_rtcRetryCount);
        SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
        if ([self respondsToSelector:s]) {
            ((void(*)(id, SEL, long long))objc_msgSend)(self, s, g_rtcTargetSec);
        }
    });
}

// 防抖：同一详情页实例 2 秒内只 push 一次（官方可能触发两次点击事件 → 双 push 闪烁）
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

// 原 selector：clickCloudRecordAction:（点「看录像」按钮，官方原逻辑弹云存储）
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

// ---------- hook 安装 ----------

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
}

static BOOL JAHooked = NO;  // 详情页 hook（clickCloudRecordAction 主链）

static void JAHook(void) {
    // 详情页主链
    if (!JAHooked) {
        Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
        if (detailCls) {
            // 检测旧版本（exchange 式 swizzle）残留的 _jasd_ selector → 提示用户清理 TrollFools 旧项
            if ([detailCls instancesRespondToSelector:NSSelectorFromString(@"_jasd_clickCloudRecordAction:")]) {
                JALog(@"!! 检测到旧版 dylib 残留的 _jasd_ 方法，建议 TrollFools 删除旧项只留最新（本版幂等，不影响）");
            }

            JASetImp(detailCls, @selector(clickCloudRecordAction:), (IMP)ja_clickCloudRecordAction,
                     &g_orig_clickCloudRecordAction);
            JASetImp(detailCls, @selector(handleJumpToOpenCloud), (IMP)ja_handleJumpToOpenCloud,
                     &g_orig_handleJumpToOpenCloud);

            JAHooked = YES;
        }
    }
    // RTC SD 播放器 viewDidAppear hook（自动定位报警时间，类可能晚加载，轮询重试）
    if (!g_rtcHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
            // v1.20：viewWillDisappear hook —— 离开时 stopSDPlay 释放底层流
            JASetImp(rtcCls, @selector(viewWillDisappear:), (IMP)ja_rtc_viewWillDisappear, &g_orig_rtc_vwd);
            g_rtcHooked = YES;
            JALog(@"RTC-SD viewDidAppear/viewWillDisappear hook 已装（轮询补装）");
        } else {
            JALog(@"!! JANewRtcSDPlayViewController 尚未加载（轮询重试）");
        }
    }
    // v1.17：RTC SD 播放器 respDeviceFirstFrameTimeStamp: hook（首帧确认+重试）
    if (!g_rtcFirstFrameHooked) {
        Class rtcCls = NSClassFromString(@"JANewRtcSDPlayViewController");
        if (rtcCls) {
            JASetImp(rtcCls, @selector(respDeviceFirstFrameTimeStamp:), (IMP)ja_rtc_respFirstFrame,
                     &g_orig_rtc_firstframe);
            g_rtcFirstFrameHooked = YES;
            JALog(@"RTC-SD respDeviceFirstFrameTimeStamp: hook 已装（数值签名，首帧确认）");
        }
    }
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.20 injected");
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
        if (!JAHooked) {
            JALog(@"!! 30 次重试后仍未找到 JANewsWarnInfoDetailVC");
        }
        if (!g_rtcHooked) {
            JALog(@"!! 30 次重试后仍未找到 JANewRtcSDPlayViewController（点看录像时会再补装）");
        }
    });
}
