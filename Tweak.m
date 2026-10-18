// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.9 闸门修复版（TrollStore 兼容：纯 runtime hook + C IMP，零类依赖，可直接 clang 编译）
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
static void ja_vm_seekTo_duration(id self, SEL _cmd, long long sec, long long dur);  // v1.9：viewModel.seekTo:duration:
static void JASetImp(Class cls, SEL sel, IMP newImp, IMP *saved);
static BOOL JASDHooked = NO;
static IMP g_orig_sd_vwa = NULL;  // JANewSDPlayerViewController viewWillAppear: 原 IMP
static IMP g_orig_sd_vda = NULL;  // JANewSDPlayerViewController viewDidAppear: 原 IMP
static IMP g_orig_sd_respEventList = NULL;  // v1.6：respDeviceSdEventList: 原 IMP
static IMP g_orig_getEventList = NULL;      // v1.6：getEventListWithSelectiontDay:detectionType: 原 IMP
static IMP g_orig_getCurrentEvent = NULL;   // v1.8：getCurrentEventWithTimeStamp: 原 IMP
static IMP g_orig_seekTo = NULL;            // v1.8：seekTo:duration: 原 IMP（SDPlayer 类，非消费链实际调用者）
static IMP g_orig_live_detectType = NULL;   // v1.9：JALiveManager.detectType getter 原 IMP
static IMP g_orig_live_isEnterBackPlayer = NULL;  // v1.9：JALiveManager.isEnterBackPlayer getter 原 IMP
static IMP g_orig_vm_seekTo = NULL;         // v1.9：viewModel.seekTo:duration: 原 IMP（官方消费链实际调用者）

// v1.5：从秒级时间戳算"报警日 0 点秒"（UTC 语义 = 本地 00:00）
// ts - (ts % 86400)：对 epoch 秒取 UTC 当天 0 点。例：1792339861 → 1792281600
// = 2026-10-19 00:00:00 UTC+8（与官方 getTodayStartTimestamp / timeIntervalSince1970 语义一致）
static long long JADayStartSec(NSNumber *ts) {
    if (!ts) return 0;
    long long v = ts.longLongValue;
    if (v >= 1000000000LL && v < 10000000000LL) {
        return v - (v % 86400LL);
    }
    return 0;
}

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    JALog(@"--- JATryOpenSDReplay (camera=%@ class=%@ uid=%@) ---",
          cam, cam ? NSStringFromClass([cam class]) : @"nil", JAVal(cam, @"uid"));
    Class cls = NSClassFromString(@"JANewSDPlayerViewController");
    if (!cls) {
        JALog(@"!! JANewSDPlayerViewController 类不存在");
        return;
    }
    // v1.5：类此刻已加载（NSClassFromString 触发），若启动轮询错过（15s 内未点入），
    // 在这里立即补装生命周期 hook，确保 viewWillAppear/viewDidAppear 生效
    if (!JASDHooked) {
        JASetImp(cls, @selector(viewWillAppear:), (IMP)ja_sd_viewWillAppear, &g_orig_sd_vwa);
        JASetImp(cls, @selector(viewDidAppear:), (IMP)ja_sd_viewDidAppear, &g_orig_sd_vda);
        JASetImp(cls, @selector(respDeviceSdEventList:), (IMP)ja_sd_respDeviceSdEventList,
                 &g_orig_sd_respEventList);
        JASetImp(cls, @selector(getCurrentEventWithTimeStamp:), (IMP)ja_sd_getCurrentEventWithTimeStamp,
                 &g_orig_getCurrentEvent);
        JASetImp(cls, @selector(seekTo:duration:), (IMP)ja_sd_seekTo_duration,
                 &g_orig_seekTo);
        JAHookLiveGates();
        JASDHooked = YES;
        JALog(@"点看录像时补装 SDPlayer 生命周期 hook（轮询错过场景兜底）");
    }
    id vc = [[cls alloc] init];
    JALog(@"已创建 SDPlayer: %@ class=%@", vc, NSStringFromClass([vc class]));

    // 1) 官方配置：setMyCamera:（崩溃修复关键）
    @try {
        [vc performSelector:NSSelectorFromString(@"setMyCamera:") withObject:cam];
        id chk = [vc valueForKey:@"myCamera"];
        JALog(@"setMyCamera 后 SDPlayer.myCamera=%@ uid=%@", chk, JAVal(chk, @"uid"));
    } @catch (NSException *e) {
        JALog(@"!! setMyCamera 异常: %@", e);
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
            // v1.6 诊断：打印类方法列表，定位真正单例名（下次对齐）
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
        // v1.5：补设设备 SD 选中日期 = 报警日 0 点秒（UTC 语义，非 0 值）
        // 官方 respDeviceSdEventList: 定位偏移 = currentTimeStamp - sdSelectiontDay；
        // 且官方 viewWillAppear 的 pendingReload 判定在 sdSelectiontDay==0 时直接置 0
        // （不拉列表）—— 这里先给非 0 值打底（后续 viewWillAppear 会无条件覆盖为今天，
        // 我们的 hook 再强制 pendingReload=报警日 0 点）。
        long long dayStart = JADayStartSec(ts);
        if (dayStart > 0 && cam) {
            JASet(cam, @"sdSelectiontDay", @(dayStart));
            JALog(@"已设 myCamera.sdSelectiontDay=%lld (报警日0点UTC)", dayStart);
        }
        id evtList = JAVal(detailVC, @"warnInfoListArr");
        if (evtList) JASet(vc, @"eventList", evtList);
        JALog(@"已设置 currentEvent/currentTimeStamp/eventList");
    }

    // 4) push
    UINavigationController *nav = detailVC.navigationController;
    if (!nav) nav = JATopVC().navigationController;
    if (nav) {
        [nav pushViewController:vc animated:YES];
        JALog(@"已 push SDPlayer");
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
static void JASDForcePullEventList(long long dayStart, double delaySec) {
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
    }
    Class vmCls = NSClassFromString(@"JANewRtcSDPlayViewModel");
    if (vmCls) {
        JASetImp(vmCls, NSSelectorFromString(@"seekTo:duration:"), (IMP)ja_vm_seekTo_duration,
                 &g_orig_vm_seekTo);
    }
    JALiveHooked = YES;
}

// v1.9 修复：设备回传消费链有两道闸门（反汇编 0x100b76d48 起）：
//   闸门1：cbz [live isEnterBackPlayer] → 0x100b7741c（不消费）
//   闸门2：cmn [live detectType],#1 → b.eq 0x100b77374（不 seekTo）
// 我们直接 push SDPlayer 未走官方初始化，这两个状态大概率是 0/-1 → 永远不 seekTo。
// 对策：调原实现前强制设 detectType=0 + isEnterBackPlayer=1（带日志确认当前值）。
static void JASetLiveGates(void) {
    Class lmCls = NSClassFromString(@"JALiveManager");
    if (!lmCls) return;
    // JALiveManager 单例：尝试常见类方法名
    NSArray *names = @[@"sharedInstance", @"shared", @"shareManager", @"defaultManager"];
    id lm = nil;
    for (NSString *sn in names) {
        SEL s = NSSelectorFromString(sn);
        if (s && [lmCls respondsToSelector:s]) {
            lm = ((id(*)(id, SEL))objc_msgSend)((id)lmCls, s);
            if (lm) break;
        }
    }
    if (!lm) return;
    // detectType → 0（走 seekTo 分支的必要条件：!= -1）
    SEL setDT = NSSelectorFromString(@"setDetectType:");
    if (setDT && [lm respondsToSelector:setDT]) {
        long long cur = 0;
        SEL getDT = NSSelectorFromString(@"detectType");
        if (getDT && [lm respondsToSelector:getDT])
            cur = ((long long(*)(id, SEL))objc_msgSend)(lm, getDT);
        ((void(*)(id, SEL, long long))objc_msgSend)(lm, setDT, 0);
        JALog(@"[JALiveManager] setDetectType:0 (原值=%lld)", cur);
    }
    // isEnterBackPlayer → YES（消费链闸门1）
    SEL setIBP = NSSelectorFromString(@"setIsEnterBackPlayer:");
    if (setIBP && [lm respondsToSelector:setIBP]) {
        BOOL cur = NO;
        SEL getIBP = NSSelectorFromString(@"isEnterBackPlayer");
        if (getIBP && [lm respondsToSelector:getIBP])
            cur = ((BOOL(*)(id, SEL))objc_msgSend)(lm, getIBP);
        ((void(*)(id, SEL, BOOL))objc_msgSend)(lm, setIBP, YES);
        JALog(@"[JALiveManager] setIsEnterBackPlayer:YES (原值=%d)", cur);
    }
}

// v1.9 兜底：官方消费链若仍不 seekTo，直接对 viewModel 强制定位播放。
// 反汇编：seekTo:duration: receiver = SDPlayer+0x28（JANewRtcSDPlayViewModel），
// 参数 x2=时间戳（绝对秒）、x3=0。
static void JAFallbackSeek(id sdPlayer) {
    if (!sdPlayer) return;
    NSNumber *ts = JAVal(sdPlayer, @"currentTimeStamp");
    if (!ts || ts.longLongValue <= 0) return;
    NSArray *vmKeys = @[@"viewModel", @"rtcSDPlayViewModel", @"sdkPlayViewModel",
                        @"playerViewModel", @"liveViewModel", @"playViewModel"];
    id vm = nil;
    for (NSString *k in vmKeys) {
        @try { vm = [sdPlayer valueForKey:k]; } @catch (NSException *e) { vm = nil; }
        if (vm) break;
    }
    if (!vm) {
        // ivar 偏移 0x28 兜底（class_getInstanceVariable 不可靠时用 object_getIvar 列表探测）
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList([sdPlayer class], &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *t = ivar_getTypeEncoding(ivs[i]);
            if (t && t[0] == '@') {
                id obj = object_getIvar(sdPlayer, ivs[i]);
                if (obj && [obj respondsToSelector:@selector(seekTo:duration:)]) {
                    vm = obj;
                    JALog(@"[兜底] 经 ivar %s 找到 viewModel=%@",
                          ivar_getName(ivs[i]), NSStringFromClass([obj class]));
                    break;
                }
            }
        }
        free(ivs);
    }
    if (!vm) { JALog(@"[兜底] 未找到 SDPlayer 的 viewModel，无法强制定位"); return; }
    SEL seek = NSSelectorFromString(@"seekTo:duration:");
    if (seek && [vm respondsToSelector:seek]) {
        JALog(@"[兜底] 强制定位 viewModel.seekTo:duration:(%lld, 0)", ts.longLongValue);
        ((void(*)(id, SEL, long long, long long))objc_msgSend)(vm, seek, ts.longLongValue, 0);
    } else {
        JALog(@"[兜底] viewModel=%@ 不响应 seekTo:duration:", NSStringFromClass([vm class]));
    }
}

static void ja_sd_respDeviceSdEventList(id self, SEL _cmd, id arg) {
    // v1.9：先放开两道闸门（在消费链执行前）
    JASetLiveGates();
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
        for (NSUInteger i = 0; i < n && i < 3; i++) {
            // v1.8：全量 dump 属性（前 3 条），MYEventModel 字段名与报警模型不同
            JADumpEventModel([arg objectAtIndex:i], i);
        }
    } else if ([arg isKindOfClass:NSDictionary.class]) {
        JALog(@"  字典 keys=%@", [arg allKeys]);
    }
    if (g_orig_sd_respEventList) ((void(*)(id, SEL, id))g_orig_sd_respEventList)(self, _cmd, arg);
    // v1.9：原实现执行后（消费链可能因闸门/分支未 seekTo），强制兜底定位
    JAFallbackSeek(self);
}

// v1.8 诊断：官方按时间戳在 eventList 里找事件（respDeviceSdEventList: 消费链关键一步）
static id ja_sd_getCurrentEventWithTimeStamp(id self, SEL _cmd, long long ts) {
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
static void ja_sd_seekTo_duration(id self, SEL _cmd, long long sec, double dur) {
    JALog(@"[seekTo:duration:] sec=%lld duration=%.1f (定位执行 ✓)", sec, dur);
    if (g_orig_seekTo) ((void(*)(id, SEL, long long, double))g_orig_seekTo)(self, _cmd, sec, dur);
}

// v1.9 诊断：JALiveManager.detectType getter —— 确认闸门2 当前值
static long long ja_live_detectType(id self, SEL _cmd) {
    long long ret = g_orig_live_detectType
        ? ((long long(*)(id, SEL))g_orig_live_detectType)(self, _cmd)
        : -1;
    JALog(@"[JALiveManager.detectType] 当前值=%lld (官方消费链闸门2: -1 会跳过 seekTo)", ret);
    return ret;
}

// v1.9 诊断：JALiveManager.isEnterBackPlayer getter —— 确认闸门1 当前值
static long long ja_live_isEnterBackPlayer(id self, SEL _cmd) {
    long long ret = g_orig_live_isEnterBackPlayer
        ? ((long long(*)(id, SEL))g_orig_live_isEnterBackPlayer)(self, _cmd)
        : 0;
    JALog(@"[JALiveManager.isEnterBackPlayer] 当前值=%lld (官方消费链闸门1: 0 会跳过消费)", ret);
    return ret;
}

// v1.9 诊断：viewModel.seekTo:duration: —— 官方消费链实际调用者（receiver=SDPlayer+0x28）
// 签名 (id, SEL, long long, long long)：x2=绝对秒、x3=0
static void ja_vm_seekTo_duration(id self, SEL _cmd, long long sec, long long dur) {
    JALog(@"[viewModel seekTo:duration:] self=%@ sec=%lld dur=%lld (定位执行 ✓)",
          NSStringFromClass([self class]), sec, dur);
    if (g_orig_vm_seekTo) ((void(*)(id, SEL, long long, long long))g_orig_vm_seekTo)(self, _cmd, sec, dur);
}

// v1.5：viewWillAppear hook —— 原实现后强制打开"拉取开关"
// 官方 viewWillAppear 判定：设备 sdSelectiontDay==0 → pendingReloadTodaySDSelectiontDay=0
// （不拉列表）→ 时间戳永远没机会被消费。这里强制设 = 报警日 0 点秒，
// 官方 viewDidAppear 就会走 getEventListWithSelectiontDay: 主动拉对应日期事件列表。
static void ja_sd_viewWillAppear(id self, SEL _cmd) {
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

// v1.5：viewDidAppear hook —— 原实现后延迟 3s 主动补拉一次
// 官方 viewDidAppear 里 getEventListWithSelectiontDay: 在建链刚发起时调用，
// 设备可能尚未连上（拉取失败/丢弃）。3s 后设备通常已连接，补拉一次兜底。
static void ja_sd_viewDidAppear(id self, SEL _cmd) {
    if (g_orig_sd_vda) ((void(*)(id, SEL))g_orig_sd_vda)(self, _cmd);
    NSNumber *ts = JAVal(self, @"currentTimeStamp");
    long long dayStart = JADayStartSec(ts);
    if (dayStart <= 0) {
        JALog(@"!! SDPlayer viewDidAppear: 无有效秒级时间戳，跳过补拉");
        return;
    }
    // v1.6：多轮补拉（3s/7s/12s），提高设备连接完成后拉取命中率
    JASDForcePullEventList(dayStart, 3);
    JASDForcePullEventList(dayStart, 7);
    JASDForcePullEventList(dayStart, 12);
    JALog(@"SDPlayer viewDidAppear: 已排定 3/7/12s 三轮补拉事件列表 dayStart=%lld", dayStart);
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
        Class sdCls = NSClassFromString(@"JANewSDPlayerViewController");
        if (sdCls) {
            JASetImp(sdCls, @selector(viewWillAppear:), (IMP)ja_sd_viewWillAppear, &g_orig_sd_vwa);
            JASetImp(sdCls, @selector(viewDidAppear:), (IMP)ja_sd_viewDidAppear, &g_orig_sd_vda);
            // v1.6 诊断：hook 设备回传事件列表回调
            JASetImp(sdCls, @selector(respDeviceSdEventList:), (IMP)ja_sd_respDeviceSdEventList,
                     &g_orig_sd_respEventList);
            // v1.8 诊断：hook 定位消费链（找事件 + seekTo 播放）
            JASetImp(sdCls, @selector(getCurrentEventWithTimeStamp:), (IMP)ja_sd_getCurrentEventWithTimeStamp,
                     &g_orig_getCurrentEvent);
            JASetImp(sdCls, @selector(seekTo:duration:), (IMP)ja_sd_seekTo_duration,
                     &g_orig_seekTo);
            JAHookLiveGates();
            JASDHooked = YES;
        } else {
            JALog(@"!! JANewSDPlayerViewController 尚未加载（轮询重试）");
        }
    }
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.9 injected");
    if (NSClassFromString(@"JANewsWarnInfoDetailVC")
        && NSClassFromString(@"JANewSDPlayerViewController")) {
        JAHook();
        return;
    }
    __block int tries = 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (tries < 30 && !(JAHooked && JASDHooked)) {
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
    });
}
