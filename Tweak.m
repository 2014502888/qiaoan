// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1.1 崩溃修复版（TrollStore 兼容：纯 runtime swizzle + C IMP，零类依赖，可直接 clang 编译）
//
// v1 实测结论（用户回传 jasdreplay.log + 崩溃报告 Joolink-2026-10-18-132645.ips）：
//   * hook 生效：不弹云存储、SDPlayer alloc/init + push 成功
//   * 闪退根因（已符号化）：SIGABRT + ObjC 异常
//       viewDidAppear: → ja_ReallySetupLiveDelegate → JALiveManager delegateCamera:isSDCardPage:
//       → connectionDevice → MYP2PChannel connectionDeviceCamera: → MYOpenSDK 抛 NSException
//   * 设备对象（MyCamera）未传入：JALiveManager.sharedInstance.myCamera == nil
//   * eventTimeUTC = nil（时间在 event_date=2026-10-18 + event_time=13:26:10）
//   * 详情页 self.deviceId/devicePwd = nil；viewModel = JAAIFaceViewModel（AI 人脸报警）
//
// v1.1 修复：
//   1) 【崩溃修复】创建 SDPlayer 后调用官方配置 [SDPlayer setMyCamera:<MyCamera>]，
//      并同步 JALiveManager.sharedInstance.myCamera（官方 JANewCloudRecordListVC
//      toSDReplayTopView 的完整创建流程 = alloc + init + setMyCamera: + pushViewController:animated:）
//   2) 【camera 获取】多级获取设备对象：
//        a. detailVC.myCamera（官方属性，viewDidLoad 内 [self myCamera] 确认存在）
//        b. JALiveManager.sharedInstance.myCamera（最近直播/回放设备）
//        c. 导航栈回溯各 VC 的 myCamera
//   3) 【时间戳】eventTimeUTC 为 nil 时用 event_date + event_time 拼 "yyyy-MM-dd HH:mm:ss"
//      → 本地时区解析 → 毫秒 NSNumber 设给 currentTimeStamp
//   4) 【兜底】拿不到 camera → 恢复官方逻辑（调原实现，保留云存储引导），不再强行 push（防崩）
//   5) 【handleJumpToOpenCloud】不再全拦截，改为转发原实现
//
// 官方关键桩（arm64）：
//   0x103462da0 = myCamera getter   0x103510b20 = setMyCamera:
//   0x10348b360 = pushViewController:animated:
//   0x10354f880 = sharedInstance    0x1033cee40 = delegateCamera:isSDCardPage:
//   0x10344d000 = live              0x10357efa0 = uid

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

// ---------- camera（设备对象 MyCamera）获取 ----------

// 多级获取设备对象：详情页官方属性 → JALiveManager 单例 → 导航栈
static id JAFindCamera(UIViewController *detailVC, NSString **src) {
    // a. 详情页官方属性 myCamera（viewDidLoad 内 [self myCamera] 确认存在）
    id cam = JAVal(detailVC, @"myCamera");
    if (cam) {
        *src = @"detailVC.myCamera";
        return cam;
    }

    // b. JALiveManager 单例
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

    // c. 导航栈回溯
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

// eventTimeUTC 为 nil 时用 event_date + event_time 拼接，返回毫秒 NSNumber
static NSNumber *JABuildTimestamp(id warn) {
    id t = JAVal(warn, @"eventTimeUTC");
    if (t) {
        if ([t isKindOfClass:NSNumber.class]) return t;
        if ([t isKindOfClass:NSString.class]) {
            return @((long long)([t doubleValue] * 1000.0)); // 秒字符串 → 毫秒
        }
        return nil;
    }
    NSString *d = JAVal(warn, @"event_date");
    NSString *tm = JAVal(warn, @"event_time");
    if (d.length && tm.length) {
        NSString *s = [NSString stringWithFormat:@"%@ %@", d, tm];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        fmt.timeZone = [NSTimeZone localTimeZone];
        NSDate *date = [fmt dateFromString:s];
        if (date) return @((long long)([date timeIntervalSince1970] * 1000.0));
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
    if (lmCls) {
        id lm = JAVal(lmCls, @"sharedInstance");
        if (lm) {
            @try {
                [lm setValue:cam forKey:@"myCamera"];
                id chk = [lm valueForKey:@"myCamera"];
                JALog(@"已同步 JALiveManager.myCamera=%@ uid=%@", chk, JAVal(chk, @"uid"));
            } @catch (NSException *e) {
                JALog(@"!! 同步 JALiveManager.myCamera 失败: %@", e);
            }
        } else {
            JALog(@"!! JALiveManager sharedInstance 为 nil");
        }
    }

    // 3) 事件与时间戳
    if (warn) {
        JASet(vc, @"currentEvent", warn);
        NSNumber *ts = JABuildTimestamp(warn);
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        JALog(@"currentTimeStamp=%@", ts);
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

// 原 selector：clickCloudRecordAction:
static void ja_clickCloudRecordAction(id self, SEL _cmd, id sender) {
    JADumpWarnInfo(self, @"clickCloudRecordAction: 已拦截（不再弹云存储）");
    NSString *src = nil;
    id cam = JAFindCamera(self, &src);
    JALog(@"camera 来源: %@  camera=%@", src, cam);
    if (cam) {
        JATryOpenSDReplay(self, JAVal(self, @"warnInfoEntityModelEx"), cam);
    } else {
        JALog(@"!! 无可用 camera，恢复官方逻辑（保留云存储引导，防崩溃）");
        SEL orig = NSSelectorFromString(@"_jasd_clickCloudRecordAction:");
        if ([self respondsToSelector:orig]) {
            ((void(*)(id, SEL, id))objc_msgSend)(self, orig, sender);
        }
    }
}

// 原 selector：handleJumpToOpenCloud —— 不再拦截，转发原实现
static void ja_handleJumpToOpenCloud(id self, SEL _cmd) {
    SEL orig = NSSelectorFromString(@"_jasd_handleJumpToOpenCloud");
    if ([self respondsToSelector:orig]) {
        ((void(*)(id, SEL))objc_msgSend)(self, orig);
    }
}

// ---------- swizzle 工具 ----------

static void JASwz(Class cls, SEL orig, IMP newImp, const char *types) {
    NSString *newSelName = [NSString stringWithFormat:@"_jasd_%@", NSStringFromSelector(orig)];
    SEL newSel = NSSelectorFromString(newSelName);
    class_addMethod(cls, newSel, newImp, types);
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, newSel);
    if (m1 && m2) {
        method_exchangeImplementations(m1, m2);
        JALog(@"swizzle %@ OK", NSStringFromSelector(orig));
    } else {
        JALog(@"swizzle %@ 失败 m1=%p m2=%p", NSStringFromSelector(orig), m1, m2);
    }
}

static BOOL JAHooked = NO;

static void JAHook(void) {
    if (JAHooked) return;
    Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
    if (!detailCls) return;

    JASwz(detailCls, @selector(clickCloudRecordAction:), (IMP)ja_clickCloudRecordAction, "v@:@");
    JASwz(detailCls, @selector(handleJumpToOpenCloud), (IMP)ja_handleJumpToOpenCloud, "v@:");

    JAHooked = YES;
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.1 injected");
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
