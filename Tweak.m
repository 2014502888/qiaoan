// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.4 时间戳修复版（TrollStore 兼容：纯 runtime hook + C IMP，零类依赖，可直接 clang 编译）
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
//   v1.4 修复（本版）：用户实测跳转成功但"回放画面定位错 / 只能看实时"——
//         根因：时间戳单位错。报警事件时间戳是【秒】（event_file_url 文件名
//         2310111541-1792304458.jpg 内嵌 1792304458 秒 = 2026-10-18 14:20:58 本地），
//         v1.3 传了毫秒（1792304458000）→ SDPlayer.getCurrentEventWithTimeStamp:
//         用 eventTime 与时间戳直接整数比较 → 匹配不到事件 → timeline 无法定位。
//         本版改为秒：优先从 event_file_url 正则提取内嵌秒，兜底 event_date+event_time 拼秒。
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

static void JATryOpenSDReplay(UIViewController *detailVC, id warn, id cam) {
    JALog(@"--- JATryOpenSDReplay (camera=%@ class=%@ uid=%@) ---",
          cam, cam ? NSStringFromClass([cam class]) : @"nil", JAVal(cam, @"uid"));
    Class cls = NSClassFromString(@"JANewSDPlayerViewController");
    if (!cls) {
        JALog(@"!! JANewSDPlayerViewController 类不存在");
        return;
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
        if (!lm) JALog(@"!! JALiveManager 单例未找到（%lu 个 common 名均无响应）", (unsigned long)sels.count);
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

static BOOL JAHooked = NO;

static void JAHook(void) {
    if (JAHooked) return;
    Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
    if (!detailCls) return;

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

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.4 injected");
    if (NSClassFromString(@"JANewsWarnInfoDetailVC")) {
        JAHook();
        return;
    }
    __block int tries = 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (tries < 30 && !JAHooked) {
            [NSThread sleepForTimeInterval:0.5];
            tries++;
            dispatch_async(dispatch_get_main_queue(), ^{ JAHook(); });
        }
        if (!JAHooked) {
            JALog(@"!! 30 次重试后仍未找到 JANewsWarnInfoDetailVC");
        }
    });
}
