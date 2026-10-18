// JoolinkSDReplay — 乔安智联 4.4.67 报警消息 → 直达本地 SD 卡录像
// v1 诊断版（TrollStore 兼容：纯 runtime swizzle，不依赖 CydiaSubstrate）
//
// 逆向定位（Joolink 4.4.67, arm64, cryptid=0）：
//   报警详情页     JANewsWarnInfoDetailVC
//   看录像按钮     clickCloudRecordAction:  → 原逻辑查云存储，未开通则弹开通引导
//   开通引导       handleJumpToOpenCloud
//   报警模型       JAEMWarnInfoEntityModel（eventTimeUTC / event_time / event_date / warn_record_type ...）
//   本地SD回放页   JANewSDPlayerViewController
//                 seekTo:duration:（按时间戳定位）respDeviceSdRecordList:type:（SD录像列表）
//                 currentEvent / currentTimeStamp / eventList 属性
//
// v1 行为：
//   1) 拦截"看录像"，不再弹云存储引导；
//   2) 打印报警模型时间戳、设备ID、viewModel 等运行时信息（系统日志 + 沙盒 Documents/jasdreplay.log）；
//   3) 尝试创建并 push JANewSDPlayerViewController。
//   装上一轮拿日志，确认设备对象来源/时间戳格式后升级 v2 完整版。

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

// ---------- 核心逻辑 ----------

static void JATryOpenSDReplay(UIViewController *detailVC, id warn) {
    JALog(@"--- JATryOpenSDReplay ---");
    Class cls = NSClassFromString(@"JANewSDPlayerViewController");
    if (!cls) {
        JALog(@"!! JANewSDPlayerViewController 类不存在");
        return;
    }
    id vc = [[cls alloc] init];
    JALog(@"已创建 SDPlayer: %@ class=%@", vc, NSStringFromClass([vc class]));

    if (warn) {
        JASet(vc, @"currentEvent", warn);
        id ts = JAVal(warn, @"eventTimeUTC");
        if (ts) JASet(vc, @"currentTimeStamp", ts);
        id evtList = JAVal(detailVC, @"warnInfoListArr");
        if (evtList) JASet(vc, @"eventList", evtList);
        JALog(@"已设置 currentEvent/currentTimeStamp/eventList");
    }

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

    id warn = JAVal(detailVC, @"warnInfoEntityModelEx");
    JALog(@"warnModel=%@", warn);
    if (warn) {
        id ts = JAVal(warn, @"eventTimeUTC");
        JALog(@"  eventTimeUTC=%@ (%@)", ts, ts ? NSStringFromClass([ts class]) : @"nil");
        JALog(@"  event_time=%@  event_date=%@  event_type=%@",
              JAVal(warn, @"event_time"), JAVal(warn, @"event_date"), JAVal(warn, @"event_type"));
        JALog(@"  warn_record_type=%@  cs_status=%@  isAli=%@",
              JAVal(warn, @"warn_record_type"), JAVal(warn, @"cs_status"), JAVal(warn, @"isAli"));
        JALog(@"  event_file_url=%@  eventPicThumbUrl=%@",
              JAVal(warn, @"event_file_url"), JAVal(warn, @"eventPicThumbUrl"));
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

// ---------- hook 实现（Category + swizzle） ----------

@interface JANewsWarnInfoDetailVC (JASDReplay)
- (void)ja_swz_clickCloudRecordAction:(id)sender;
- (void)ja_swz_handleJumpToOpenCloud;
@end

@implementation JANewsWarnInfoDetailVC (JASDReplay)

- (void)ja_swz_clickCloudRecordAction:(id)sender {
    JADumpWarnInfo(self, @"clickCloudRecordAction: 已拦截（不再弹云存储）");
    JATryOpenSDReplay(self, JAVal(self, @"warnInfoEntityModelEx"));
}

- (void)ja_swz_handleJumpToOpenCloud {
    JADumpWarnInfo(self, @"handleJumpToOpenCloud: 已拦截");
    JATryOpenSDReplay(self, JAVal(self, @"warnInfoEntityModelEx"));
}

@end

// ---------- 注入入口 ----------

static BOOL JAHooked = NO;

static void JAHook(void) {
    if (JAHooked) return;

    Class detailCls = NSClassFromString(@"JANewsWarnInfoDetailVC");
    if (!detailCls) return;

    Method m1 = class_getInstanceMethod(detailCls, @selector(clickCloudRecordAction:));
    Method m2 = class_getInstanceMethod(detailCls, @selector(ja_swz_clickCloudRecordAction:));
    if (m1 && m2) {
        method_exchangeImplementations(m1, m2);
        JALog(@"hook clickCloudRecordAction: OK");
    } else {
        JALog(@"hook clickCloudRecordAction: 失败 m1=%p m2=%p", m1, m2);
    }

    Method m3 = class_getInstanceMethod(detailCls, @selector(handleJumpToOpenCloud));
    Method m4 = class_getInstanceMethod(detailCls, @selector(ja_swz_handleJumpToOpenCloud));
    if (m3 && m4) {
        method_exchangeImplementations(m3, m4);
        JALog(@"hook handleJumpToOpenCloud OK");
    } else {
        JALog(@"hook handleJumpToOpenCloud 失败 m3=%p m4=%p", m3, m4);
    }

    JAHooked = YES;
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 20 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JALog(@"JoolinkSDReplay v1.0 injected");
    if (NSClassFromString(@"JANewsWarnInfoDetailVC")) {
        JAHook();
        return;
    }
    __block int tries = 0;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (tries < 20 && !JAHooked) {
            [NSThread sleepForTimeInterval:0.5];
            tries++;
            dispatch_async(dispatch_get_main_queue(), ^{ JAHook(); });
        }
        if (!JAHooked) {
            JALog(@"!! 20 次重试后仍未找到 JANewsWarnInfoDetailVC");
        }
    });
}
