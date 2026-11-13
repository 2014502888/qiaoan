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
// v2.4（云存储设备定位排查，日志版）：
//   现象：某台开通云存储（后续关闭、SD 可正常回放）的设备，点「看录像」后弹
//   「当前时间无录像」，时间轴固定停在 16:23:33，画面为实时流；其它设备正常。
//   已确认进入的是本地 SD 回放页（有时间轴；云回放页是按天格子列表，界面不同），
//   按钮 hook 生效。本版曾加诊断日志 Documents/jasdreplay2.log（v2.6 已整段删除）。
// v2.5（定案：报警时间解析错误）：
//   日志实测 warn ts=1326615813 → 2012-01-15 16:23:33，正是用户看到的"固定
//   16:23:33"；而 eid 里嵌着真实时间 ...2026111323:06:09...（=2026-11-13 23:06:09）。
//   根因：该设备（云存储报警模型）字段结构与其它设备不同，旧解析链把非时间字段
//   当成了秒 → 去查 2012-01-15 的 SD 录像（events=0）→ 官方定位失败 → 弹「当前
//   时间无录像」→ 退回实时流；拖动任何时间点都同样失败，所以恒定停在 16:23:33。
//   修复：① 所有候选秒过合理性闸（早于 2018-01-01 / 晚于当前 +2 天一律丢弃）；
//   ② 时间字段扩到 eventTime/alarmTime/createTime/pushTime 等并加毫秒归一；
//         ③ 兜底用 eid 内嵌 yyyyMMddHH:mm:ss 解析；④ 定位仍用报警秒原值
//   （撤掉 v2.4"取最近段起点替换"的尝试：报警常落在段中间，替换会挪错画面）；
//   ⑤ events=0（该日列表还没拉回来）时 2s 后补定位一次。
// v2.6（格子回放体验修正 + 清理）：
//   ① 入口按钮出现慢：watcher 首 tick 1.5s→0.2s，间隔 0.8s→0.3s；
//   ② 「正在读取该日录像…」提示改居中（textAlignment 居中 + frame 落在页面正中）；
//   ③ 格子顺序改「最新在最上」（appendDay 里按 sec 降序）；
//   ④ 封面：JAGridImageURL 键名扩到常见封面/抓拍字段 + URL 归一；加磁盘缓存
//      （Caches/JAGridCovers，重启后仍秒出图）；无封面显示浅灰底「无封面」占位；
//   ⑤ 播放片段化：进官方播放页 1s 后隐藏 timeLineView（无拖动条），35s 自动回格子
//      并连播下一格 —— 观感对齐云回放的「看一小段」；
//   ⑥ 清理：删除 v2.3/v2.4 遗留的整套诊断（JALog/jasdreplay2.log、JAGridProbeText
//      结构快照、自动复制剪贴板、「复制」按钮、黑框 TextView、lastProbe）。
// v2.7（格子页按小时归类 + 取数修正）：
//   ① 分组改「天 → 小时」两级：一天一个大标题（右侧虚线），小时内小标题（蓝色时钟 +
//      HH:00），一小时一组 3 列格子 —— 样式对齐官方云回放页；
//   ② 顶部被压：collectionView 按 safeAreaInsets 布局，「2026年11月13日」这类日期
//      分组不再被顶部「回放 / 连播」那条导航栏遮住；
//   ③ 跨天串数据：借用官方对象取数时列表可能还是上一天的，appendDay 只收落在本天
//      00:00~24:00 的事件，并按秒去重、同一天重复出现则整体替换（修掉「12 号显示
//      13 号内容」与「同一天重复」）；
//   ④ 条数偏少：gridTryFetch 改为多次采样、取「该天有效条数最多」的那次，连续两次
//      不再增长才收工（官方列表异步/分段回来，一拿到非空就返回会少条）。
// v2.8 / v2.8.1（数据源改「报警消息」+ 当日空态）：
//   ① 抓拍图优先 eventPicThumbUrl；新增按天消息源 JAGridFetchMessageDay（直连
//      JAMessageModel）+ 按天磁盘缓存 Caches/JAGridDays；
//   ② 入口去重改窗口坐标 ±14 判定；播放页补 RTC hooks 与「目标 HH:mm:ss」角标；
//   ③ 过了 24 点当天还没有报警时不再误报「往前 3 天都没录像」，改成保留当天
//      抬头 + 灰色说明「当日还没有任何报警消息」，往上拉才去读前一天。
// v2.9（定案：数据 100% 照搬官方「消息列表」页）：
//   之前是自己照着消息列表的行为重写一遍（接口参数只能猜），一猜错就整体不对，
//   所以怎么修都不完美。本版直接把官方那个页面拉起来当数据引擎：
//     · 类：JANewDevWarnInfoListVC（前面几版 dump 已确认：44 个 ivar 里没有
//       camera/device 字段，设备来自父类 JABasicViewController 的 myCamera）；
//     · 塞成子控制器 + 挪到屏幕外 + hidden，让它 viewDidLoad/布局照常跑完，
//       但一个像素都不显示；
//     · 日期走它自己的 currentDateStr（yyyy-MM-dd，北京时区）；
//     · 首屏调它自己的 loadDataFirstWithDate:showHud:isTableRefresh:finish:；
//     · 补分页替它调 loadMoreFirstDateWithShowHud:isTableRefresh:finish:；
//     · 结果直接读它的 warnInfoListArr（= 它 tableView 的数据源），
//       isSelfEndMoreData 判「还有更多」、isSelfNoData 判「这天真没有」。
//   这样条数、抓拍图、跨天、分页结果与用户在消息列表里看到的完全一致；
//   格子页只负责「3 列 + 小时分隔」重排。官方通道不通时才依次退回直连消息
//   模型、官方 SD 段（v2.7 原链路），保证不会比之前更差。
// v2.9.1（修 v2.9 闪退）：
//   v2.9 是「新建一个隐藏实例当引擎」，实测点格子回放、数据刚开始读就闪退 ——
//   官方这页的 viewDidLoad 要建 tableView/顶部条/日历，依赖真实导航栈与窗口尺寸，
//   屏外隐藏跑不干净。改成「捕获 + 复用」：hook 它的 viewDidLoad，把用户真打开过
//   的那个实例按设备分桶留下来（强引用，最多 8 台），格子页直接借它自己的
//   loadDataFirstWithDate: / loadMoreFirstDateWith... 取数。实例生命周期由官方
//   自己管理，不再新建，从根上不会闪退；没捕获到时退回 v2.8 直连 + SD 段。
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
#import <stdarg.h>

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

// v2.5：秒值合理性校验。某台开通过云存储的设备，报警模型字段与其它设备不同，
// 旧解析链把非时间字段当成了秒 → 得到 2012-01-15 16:23:33（正是用户实测
// 「时间轴固定停在 16:23:33」的来源），于是去查 2012 年的 SD 录像（必然 events=0）
// → 官方定位失败 → 弹「当前时间无录像」→ 退回实时流。
// 现在任何候选秒都要过这道闸：不合理就丢弃，继续找下一个候选。
static BOOL JASecSane(long long v) {
    if (v <= 0) return NO;
    if (v > 1000000000000LL) v /= 1000;      // 毫秒 → 秒
    if (v < 1514764800LL) return NO;         // 早于 2018-01-01 → 可疑
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    if (v > now + 2 * 86400LL) return NO;    // 晚于当前 2 天 → 可疑
    return YES;
}

// 数值 / 字符串 / "2026-11-13 23:06:09" 形式统一转秒，不合理返回 nil
static NSNumber *JASecFromValue(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:NSNumber.class]) {
        long long n = [(NSNumber *)v longLongValue];
        if (n > 1000000000000LL) n /= 1000;
        return JASecSane(n) ? @(n) : nil;
    }
    if (![v isKindOfClass:NSString.class]) return nil;
    NSString *s = (NSString *)v;
    if (!s.length) return nil;
    long long n = s.longLongValue;
    if (n > 1000000000000LL) n /= 1000;
    if (JASecSane(n)) return @(n);
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    for (NSString *pat in @[@"yyyy-MM-dd HH:mm:ss", @"yyyy/MM/dd HH:mm:ss",
                            @"yyyy-MM-dd'T'HH:mm:ss", @"yyyy-MM-dd HH:mm"]) {
        fmt.dateFormat = pat;
        NSDate *d = [fmt dateFromString:s];
        if (!d) continue;
        long long t = (long long)[d timeIntervalSince1970];
        if (JASecSane(t)) return @(t);
    }
    return nil;
}

// v2.5：eid 内嵌时间兜底。实测云存储设备的 eid 形如
//   f7054dad63177d78e8ee4ddb17b6941e2026111323:06:094f867671
// （服务器生成，含 yyyyMMddHH:mm:ss），而它的 eventTimeUTC 给的是不可用值。
// 这是这台设备唯一能拿到的权威时间，放在解析链最后兜底。
static NSNumber *JASecFromEID(id warn) {
    id e = JAVal(warn, @"eid");
    if (![e isKindOfClass:NSString.class]) e = JAVal(warn, @"eventId");
    if (![e isKindOfClass:NSString.class]) return nil;
    NSString *s = (NSString *)e;
    if (s.length < 14) return nil;
    NSArray *pats = @[@"(20\\d{2})(\\d{2})(\\d{2})(\\d{2}):(\\d{2}):(\\d{2})",
                      @"(20\\d{2})-(\\d{2})-(\\d{2})\\s+(\\d{2}):(\\d{2}):(\\d{2})",
                      @"(20\\d{2})(\\d{2})(\\d{2})(\\d{2})(\\d{2})(\\d{2})"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone localTimeZone];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    for (NSString *p in pats) {
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:p
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (!m || m.numberOfRanges < 7) continue;
        NSString *built = [NSString stringWithFormat:@"%@-%@-%@ %@:%@:%@",
                           [s substringWithRange:[m rangeAtIndex:1]],
                           [s substringWithRange:[m rangeAtIndex:2]],
                           [s substringWithRange:[m rangeAtIndex:3]],
                           [s substringWithRange:[m rangeAtIndex:4]],
                           [s substringWithRange:[m rangeAtIndex:5]],
                           [s substringWithRange:[m rangeAtIndex:6]]];
        NSDate *d = [fmt dateFromString:built];
        if (!d) continue;
        long long t = (long long)[d timeIntervalSince1970];
        if (JASecSane(t)) return @(t);
    }
    return nil;
}

// 报警事件时间戳：秒（NSNumber）
// v2.5 链路（每一项都过 JASecSane，不合理继续下一项）：
//  ① event_file_url 文件名内嵌 10 位秒（服务器权威，如 -1792304458.jpg）
//  ② eventTimeUTC / eventTime / alarmTime / createTime / eventCreateTime / pushTime / time
//  ③ event_date + event_time 拼本地秒
//  ④ eid 内嵌 yyyyMMddHH:mm:ss（云存储设备兜底）
// 报警事件时间戳：秒（NSNumber）
static NSNumber *JABuildTimestamp(id warn) {
    if (!warn) return nil;
    // ① event_file_url 文件名内嵌秒：xxx/2310111541-1792304458.jpg
    id url = JAVal(warn, @"event_file_url");
    if ([url isKindOfClass:NSString.class]) {
        NSString *u = (NSString *)url;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"-(\\d{10})\\."
                                                                            options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:u options:0
                                                   range:NSMakeRange(0, u.length)];
        if (m && m.numberOfRanges > 1) {
            long long v = [u substringWithRange:[m rangeAtIndex:1]].longLongValue;
            if (JASecSane(v)) return @(v);
        }
    }
    // ② 明确的时间字段（按可信度排序，逐个校验）
    for (NSString *k in @[@"eventTimeUTC", @"eventTime", @"alarmTime", @"eventCreateTime",
                          @"createTime", @"pushTime", @"time", @"timestamp"]) {
        NSNumber *n = JASecFromValue(JAVal(warn, k));
        if (n) return n;
    }
    // ③ event_date + event_time 拼秒（本地时区；兼容 "HH:mm" 缺秒）
    id d = JAVal(warn, @"event_date");
    id tm = JAVal(warn, @"event_time");
    if ([d isKindOfClass:NSString.class] && [tm isKindOfClass:NSString.class] &&
        [(NSString *)d length] >= 8 && [(NSString *)tm length] >= 5) {
        NSString *ts = (NSString *)tm;
        if (ts.length == 5) ts = [ts stringByAppendingString:@":00"];
        NSString *s = [NSString stringWithFormat:@"%@ %@", d, ts];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        fmt.timeZone = [NSTimeZone localTimeZone];
        NSDate *date = [fmt dateFromString:s];
        if (date) {
            long long t = (long long)[date timeIntervalSince1970];
            if (JASecSane(t)) return @(t);
        }
    }
    // ④ eid 内嵌时间兜底
    return JASecFromEID(warn);
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
static NSArray *JAGridFindEvents(id vc);
static NSNumber *JAGridTimestamp(id ev);

// v2.6：统计该 VC 当前拿到的有效 SD 录像段条数（只用于判断列表是否已拉回来）
static NSInteger JAGridValidEventCount(id vc) {
    NSArray *evs = JAGridFindEvents(vc);
    NSInteger n = 0;
    for (id ev in evs) {
        NSNumber *t = JAGridTimestamp(ev);
        if (!t) continue;
        long long s = t.longLongValue;
        if (s >= 1000000000LL && s < 10000000000LL) n++;
    }
    return n;
}

// v2.7：某天内的有效事件条数（采样比较用）
static NSInteger JAGridDayEventCount(NSArray *evs, long long day) {
    NSInteger n = 0;
    for (id ev in evs) {
        NSNumber *t = JAGridTimestamp(ev);
        if (!t) continue;
        long long s = t.longLongValue;
        if (s >= day && s < day + 86400LL) n++;
    }
    return n;
}

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
            // v2.5 定案：定位一律用报警秒原值（不用"最近一段"替换 —— 报警常落在
            // 某段中间，替换会把画面挪到段起点）。v2.6 只保留"列表是否已回来"的判断：
            // 列表为空时 2s 后补一次定位，避免该日事件网络拉取稍慢导致定位失败。
            NSInteger evCount = JAGridValidEventCount(self);
            SEL s = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
            if ([self respondsToSelector:s]) {
                ((void(*)(id, SEL, long long))objc_msgSend)(self, s, sec);
            }
            if (evCount > 0) {
                // v1.18：播放定位已发出，再等 1.5s 拨时间轴指示器到定位时间点
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
                    JATimeLineSyncToSec(self, sec);
                });
            } else {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
                    NSInteger c2 = JAGridValidEventCount(self);
                    if (c2 > 0) {
                        SEL s2 = NSSelectorFromString(@"startSDPlayWithSelectTimeStamp:");
                        if ([self respondsToSelector:s2]) {
                            ((void(*)(id, SEL, long long))objc_msgSend)(self, s2, sec);
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     (int64_t)(1.5 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            if (self != g_activeSDPlayer || myGen != g_rtcVdaGen) return;
                            JATimeLineSyncToSec(self, sec);
                        });
                    } else {
                        JATimeLineSyncToSec(self, sec);
                    }
                });
            }
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

// ---------- 事件字段读取 ----------

// v2.6：封面地址归一化（补协议 / 丢弃无法解析的相对路径）
static NSString *JAGridNormalizeURL(NSString *u) {
    if (![u isKindOfClass:NSString.class]) return nil;
    if (u.length < 9) return nil;
    if ([u hasPrefix:@"http://"] || [u hasPrefix:@"https://"]) return u;
    if ([u hasPrefix:@"//"]) return [@"https:" stringByAppendingString:u];
    if ([u hasPrefix:@"file://"]) return u;
    return nil;
}

static NSString *JAGridImageURL(id ev) {
    // v2.8：消息模型（JAEMWarnInfoEntityModel）的抓拍图就是消息列表里那张缩略图，
    // 键名 eventPicThumbUrl 优先；其次 event_file_url（原图/大图）。
    id thumb = JAVal(ev, @"eventPicThumbUrl");
    if ([thumb isKindOfClass:NSString.class]) {
        NSString *u = JAGridNormalizeURL((NSString *)thumb);
        if (u) return u;
    }
    // v2.6：键名扩到常见的封面/抓拍字段（不同设备的报警模型字段不一样）
    NSArray *keys = @[@"event_file_url", @"event_pic_url", @"event_pic", @"picUrl",
                      @"pic_url", @"event_img", @"imageUrl", @"snapUrl", @"eventImagePath",
                      @"recordFileUrl", @"record_file_url", @"fileUrl", @"file_url",
                      @"coverUrl", @"thumbUrl", @"imgUrl", @"eventPicUrl",
                      @"pic", @"cover", @"coverImg", @"coverPic", @"coverPicUrl",
                      @"videoCoverUrl", @"eventCoverUrl", @"eventCover", @"snapshotUrl",
                      @"snapPic", @"snapPicUrl", @"thumb", @"image", @"eventImage",
                      @"eventImageUrl", @"img", @"picPath", @"imagePath", @"localCoverPath"];
    for (NSString *k in keys) {
        NSString *u = JAGridNormalizeURL(JAVal(ev, k));
        if (u) return u;
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

// ---------- v2.8：报警消息数据源（与「消息列表」同源，自带抓拍图） ----------
// 为什么换源：官方 SD 事件列表只对「当前选中那天」生效，跨天拉取拿到的是上一天的旧
// 数组（v2.6「12 号显示 13 号内容」、v2.7「往前 3 天都没录像」都是它）；而且它走本地
// 缓存（isLoadCacheEventList），首读不全、翻过报警消息后才变全（「条数比报警消息少、
// 翻完再回来变多」）。报警消息接口本身按天查询、可分页、每条都带 eventPicThumbUrl，
// 所以格子页的数据源优先走它，失败再回退官方 SD 段（不会比 v2.7 更差）。

static NSString *JAGridDayStr(long long day) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    df.dateFormat = @"yyyy-MM-dd";
    return [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)day]];
}

static NSString *JAGridDeviceId(id cam) {
    for (NSString *k in @[@"uid", @"deviceId", @"devId", @"sn", @"deviceSn", @"snStr", @"iotId"]) {
        NSString *s = JANormId(JAVal(cam, k));
        if (s.length >= 6) return s;
    }
    return nil;
}

// ---------- v2.9.1：复用用户真实打开过的「消息列表」页 ----------
// v2.9 是新建一个隐藏实例当数据引擎，实测点格子回放后闪退：官方这页的
// viewDidLoad 要建 tableView/顶部条/日历，依赖真实导航栈与窗口尺寸，屏外隐藏
// 跑不干净。改成「捕获 + 复用」：用户真打开过一次这页，就把这个实例留下来
// （强引用、按设备分桶），格子页直接借它自己的 loadDataFirstWithDate: /
// loadMoreFirstDateWith... 去取数。实例生命周期是官方自己管理的，最稳，
// 而且它内部就是消息列表正在用的那份数据与分页，天然一致。
// 注意：这里的定义必须排在 JAGridDeviceId 之后（它要按设备 id 分桶）。
static NSMutableDictionary *g_msgListVCs = nil;
static IMP g_orig_msgList_vdl = NULL;

static NSString *JAMsgListKey(id cam) {
    NSString *k = JAGridDeviceId(cam);
    return k.length ? k : nil;
}

static id JAMsgListVCFor(id cam) {
    if (!g_msgListVCs) return nil;
    NSString *k = JAMsgListKey(cam);
    if (!k.length) return nil;
    @try { return g_msgListVCs[k]; } @catch (NSException *e) { return nil; }
}

static NSString *JAGridDeviceName(id cam) {
    for (NSString *k in @[@"name", @"deviceName", @"devName", @"nickName", @"remark"]) {
        id v = JAVal(cam, k);
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return (NSString *)v;
    }
    return @"";
}

// 一条报警消息 → 格子 entry（sec 复用 v2.5 已验证的解析链）
static NSDictionary *JAGridEntryFromMessage(id msg, long long day) {
    if (!msg) return nil;
    NSNumber *ts = JABuildTimestamp(msg);
    if (!ts) return nil;
    long long sec = ts.longLongValue;
    if (sec < day || sec >= day + 86400LL) return nil;     // 只收本天
    NSMutableDictionary *e = [NSMutableDictionary dictionary];
    e[@"sec"] = @(sec);
    e[@"day"] = @(day);
    e[@"ev"] = msg;
    NSString *u = JAGridImageURL(msg);
    if (u) e[@"img"] = u;
    id im = JAVal(msg, @"thumbImg");
    if ([im isKindOfClass:UIImage.class]) e[@"imgObj"] = im;
    return e;
}

// 消息数组 → 按天过滤 + 按秒去重 + 最新在上
static NSArray *JAGridEntriesFromMessages(NSArray *list, long long day) {
    if (![list isKindOfClass:NSArray.class] || list.count == 0) return nil;
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id m in list) {
        NSDictionary *e = JAGridEntryFromMessage(m, day);
        if (!e) continue;
        NSNumber *sec = (NSNumber *)e[@"sec"];
        if ([seen containsObject:sec]) continue;
        [seen addObject:sec];
        [items addObject:e];
    }
    if (items.count == 0) return nil;
    [items sortUsingComparator:^NSComparisonResult(id a, id b) {
        long long sa = [(NSNumber *)[(NSDictionary *)a objectForKey:@"sec"] longLongValue];
        long long sb = [(NSNumber *)[(NSDictionary *)b objectForKey:@"sec"] longLongValue];
        if (sa == sb) return NSOrderedSame;
        return sa > sb ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
}

// 官方消息模型是异步网络拉取：warnMessageList 会分段变长，连续 2 次不再增长才收工
static void JAGridPollMessageModel(id model, long long day, NSInteger round,
                                   NSArray *best, NSInteger bestN, NSInteger stable,
                                   void (^cb)(NSArray *items)) {
    if (round > 10) { if (cb) cb(bestN > 0 ? best : nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray *list = nil;
        @try { list = [model valueForKey:@"warnMessageList"]; } @catch (NSException *e) {}
        NSArray *items = JAGridEntriesFromMessages(list, day);
        NSInteger n = items ? (NSInteger)items.count : 0;
        __block NSArray *cand = best;
        __block NSInteger bn = bestN;
        __block NSInteger st = stable;
        if (n > bn) { cand = items; bn = n; st = 0; }
        else { st += 1; }
        if (bn > 0 && st >= 2) { if (cb) cb(cand); return; }
        JAGridPollMessageModel(model, day, round + 1, cand, bn, st, cb);
    });
}

// 拉「某设备某天」的报警消息；cb(nil) 表示这条通道走不通（调用方回退官方 SD 段）
static void JAGridFetchMessageDay(id cam, long long day, void (^cb)(NSArray *items)) {
    Class mc = NSClassFromString(@"JAMessageModel");
    NSString *devId = JAGridDeviceId(cam);
    if (!mc || !devId.length) { if (cb) cb(nil); return; }
    id model = nil;
    @try { model = [[mc alloc] init]; } @catch (NSException *e) { model = nil; }
    if (!model) { if (cb) cb(nil); return; }

    NSString *ds = JAGridDayStr(day);
    NSString *dn = JAGridDeviceName(cam);
    @try { [model setValue:cam forKey:@"selectedCamera"]; } @catch (NSException *e) {}
    @try { [model setValue:ds forKey:@"selectedDayString"]; } @catch (NSException *e) {}
    @try { [model setValue:@(0) forKey:@"searchFrom"]; } @catch (NSException *e) {}

    SEL f1 = NSSelectorFromString(@"fetchJooanMessagesWithDay:searchFrom:devId:devName:");
    SEL f2 = NSSelectorFromString(@"fetchAliMessagesWithDay:searchFrom:iotId:devName:");
    __block BOOL triedAli = NO;
    BOOL sent = NO;
    if ([model respondsToSelector:f1]) {
        @try {
            ((void (*)(id, SEL, id, int, id, id))objc_msgSend)(model, f1, ds, 0, devId, dn);
            sent = YES;
        } @catch (NSException *e) { sent = NO; }
    }
    if (!sent && [model respondsToSelector:f2]) {
        @try {
            ((void (*)(id, SEL, id, int, id, id))objc_msgSend)(model, f2, ds, 1, devId, dn);
            sent = YES;
            triedAli = YES;
        } @catch (NSException *e) { sent = NO; }
    }
    if (!sent) { if (cb) cb(nil); return; }

    JAGridPollMessageModel(model, day, 0, nil, 0, 0, ^(NSArray *items) {
        if (items.count > 0 || triedAli || ![model respondsToSelector:f2]) {
            if (cb) cb(items);
            return;
        }
        // Jooan 通道空了再换 Ali 通道试一次（部分设备是阿里云存量）
        triedAli = YES;
        @try { [model setValue:[NSMutableArray array] forKey:@"warnMessageList"]; }
        @catch (NSException *e) {}
        BOOL ok = NO;
        @try {
            ((void (*)(id, SEL, id, int, id, id))objc_msgSend)(model, f2, ds, 1, devId, dn);
            ok = YES;
        } @catch (NSException *e) { ok = NO; }
        if (!ok) { if (cb) cb(nil); return; }
        JAGridPollMessageModel(model, day, 0, nil, 0, 0, cb);
    });
}

// ---------- v2.8：按天磁盘缓存（第二次进格子页秒开） ----------

static NSString *JAGridDayCacheDir(NSString *devKey) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES) firstObject];
    if (!caches.length || !devKey.length) return nil;
    NSString *dir = [[caches stringByAppendingPathComponent:@"JAGridDays"]
                     stringByAppendingPathComponent:devKey];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *JAGridDayCachePath(NSString *devKey, long long day) {
    NSString *dir = JAGridDayCacheDir(devKey);
    if (!dir.length) return nil;
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld.plist", day]];
}

static NSArray *JAGridDayCacheRead(NSString *devKey, long long day) {
    NSString *p = JAGridDayCachePath(devKey, day);
    if (!p.length) return nil;
    NSArray *arr = [NSArray arrayWithContentsOfFile:p];
    if (![arr isKindOfClass:NSArray.class] || arr.count == 0) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id o in arr) {
        if (![o isKindOfClass:NSDictionary.class]) continue;
        NSNumber *sec = ((NSDictionary *)o)[@"sec"];
        if (![sec isKindOfClass:NSNumber.class]) continue;
        NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)o];
        e[@"day"] = @(day);
        [out addObject:e];
    }
    return out.count ? out : nil;
}

static void JAGridDayCacheWrite(NSString *devKey, long long day, NSArray *items) {
    if (!items.count || !devKey.length) return;
    NSString *p = JAGridDayCachePath(devKey, day);
    if (!p.length) return;
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *e in items) {
        NSNumber *sec = e[@"sec"];
        if (![sec isKindOfClass:NSNumber.class]) continue;
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        o[@"sec"] = sec;
        NSString *img = e[@"img"];
        if ([img isKindOfClass:NSString.class]) o[@"img"] = img;
        [arr addObject:o];
    }
    [arr writeToFile:p atomically:YES];
}

// 官方 SD 段数组 → 格子 entry（回退路径用；按天过滤 + 去重 + 最新在上）
static NSArray *JAGridEntriesFromEvents(NSArray *events, long long day) {
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id ev in events) {
        NSNumber *ts = JAGridTimestamp(ev);
        if (!ts) continue;
        long long sec = ts.longLongValue;
        if (sec < day || sec >= day + 86400LL) continue;
        if ([seen containsObject:@(sec)]) continue;
        [seen addObject:@(sec)];
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        e[@"sec"] = @(sec);
        e[@"day"] = @(day);
        e[@"ev"] = ev;
        NSString *u = JAGridImageURL(ev);
        if (u) e[@"img"] = u;
        [items addObject:e];
    }
    if (items.count == 0) return nil;
    [items sortUsingComparator:^NSComparisonResult(id a, id b) {
        long long sa = [(NSNumber *)[(NSDictionary *)a objectForKey:@"sec"] longLongValue];
        long long sb = [(NSNumber *)[(NSDictionary *)b objectForKey:@"sec"] longLongValue];
        if (sa == sb) return NSOrderedSame;
        return sa > sb ? NSOrderedAscending : NSOrderedDescending;
    }];
    return items;
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

// ---------- 图片缓存（内存 + 磁盘 + 网络） ----------

// v2.6：磁盘缓存路径（FNV-1a 对 URL 取哈希做文件名，避免再次进页面/重启后重新下载）
static NSString *JAGridDiskPathForKey(NSString *key) {
    if (!key.length) return nil;
    uint32_t h = 2166136261u;
    for (NSUInteger i = 0; i < key.length; i++) {
        h ^= (uint32_t)[key characterAtIndex:i];
        h *= 16777619u;
    }
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES) firstObject];
    NSString *dir = [caches stringByAppendingPathComponent:@"JAGridCovers"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%08x.img", h]];
}

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
    UIImage *m = [self.mem objectForKey:key];
    if (m) return m;
    // v2.6：内存没有就查磁盘（这样重启 App 后格子也有封面）
    NSString *dp = JAGridDiskPathForKey(key);
    if (dp.length && [[NSFileManager defaultManager] fileExistsAtPath:dp]) {
        UIImage *d = [UIImage imageWithContentsOfFile:dp];
        if (d) { [self.mem setObject:d forKey:key]; return d; }
    }
    return nil;
}
- (void)loadURL:(NSString *)url completion:(void (^)(UIImage *, NSString *))cb {
    if (!url.length || ![url hasPrefix:@"http"]) { if (cb) cb(nil, url); return; }
    UIImage *c = [self imageForKey:url];
    if (c) { if (cb) cb(c, url); return; }
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { if (cb) cb(nil, url); return; }
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            UIImage *img = nil;
            if (data) { @autoreleasepool { img = [UIImage imageWithData:data]; } }
            if (img) {
                [self.mem setObject:img forKey:url];
                NSString *dp = JAGridDiskPathForKey(url);
                if (dp.length) [data writeToFile:dp atomically:YES];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(img, url); });
        }];
    [t resume];
}
@end

// ---------- 单元格 ----------

@interface JAGridCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *thumb;
@property (nonatomic, strong) UILabel *timeLab;
@property (nonatomic, strong) UILabel *noneLab;      // v2.6：没有封面时的占位文字
@property (nonatomic, strong) UIView *playDot;
@property (nonatomic, copy) NSString *imgURL;
- (void)setImageURL:(NSString *)url;
- (void)showImage:(UIImage *)img;   // v2.8：消息模型自带 thumbImg，直接显示
@end

@implementation JAGridCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _thumb = [[UIImageView alloc] initWithFrame:CGRectZero];
        _thumb.contentMode = UIViewContentModeScaleAspectFill;
        _thumb.clipsToBounds = YES;
        // v2.6：无封面时用浅灰底 + "无封面"占位，不再是纯黑块
        _thumb.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1.0];
        _thumb.layer.cornerRadius = 8;
        [self.contentView addSubview:_thumb];

        _noneLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _noneLab.text = @"无封面";
        _noneLab.font = [UIFont systemFontOfSize:11];
        _noneLab.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
        _noneLab.textAlignment = NSTextAlignmentCenter;
        _noneLab.hidden = YES;
        [self.contentView addSubview:_noneLab];

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
    self.noneLab.frame = CGRectMake(0, 0, w, thumbH);
    self.playDot.frame = CGRectMake(w - 24, thumbH - 24, 18, 18);
    self.timeLab.frame = CGRectMake(0, thumbH + 5, w, h - thumbH - 5);
}
- (void)prepareForReuse {
    [super prepareForReuse];
    self.imgURL = nil;
    self.thumb.image = nil;
    self.noneLab.hidden = YES;
    self.timeLab.text = nil;
}
- (void)setImageURL:(NSString *)url {
    self.imgURL = [url copy];
    if (!url) {
        self.thumb.image = nil;
        self.noneLab.hidden = NO;
        return;
    }
    UIImage *cached = [[JAGridImageCache shared] imageForKey:url];
    if (cached) {
        self.thumb.image = cached;
        self.noneLab.hidden = YES;
        return;
    }
    self.thumb.image = nil;
    self.noneLab.hidden = NO;          // 下载期间先显示占位，不留纯黑
    __weak typeof(self) ws = self;
    NSString *key = [url copy];
    [[JAGridImageCache shared] loadURL:url completion:^(UIImage *img, NSString *k) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        if (!key || ![s.imgURL isEqualToString:key]) return;
        if (img) { s.thumb.image = img; s.noneLab.hidden = YES; }
        else { s.noneLab.hidden = NO; }
    }];
}

// v2.8：消息模型自带解码好的缩略图（thumbImg），直接显示，省一次下载
- (void)showImage:(UIImage *)img {
    self.imgURL = nil;
    if (!img) {
        self.thumb.image = nil;
        self.noneLab.hidden = NO;
        return;
    }
    self.thumb.image = img;
    self.noneLab.hidden = YES;
}
@end

// ---------- 分组头（v2.7：一天大标题 + 按小时小标题，样式对齐云回放） ----------

// 云回放那个蓝色小时时钟图标（圆环 + 两根指针，纯 drawRect 自绘，不依赖图片资源）
@interface JAGridClockView : UIView
@end
@implementation JAGridClockView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}
- (void)drawRect:(CGRect)rect {
    UIColor *blue = [UIColor colorWithRed:0.13 green:0.55 blue:0.95 alpha:1.0];
    [blue setStroke];
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGRect r = CGRectInset(rect, 1.0, 1.0);
    UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:r];
    circle.lineWidth = 1.4;
    [circle stroke];
    CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    UIBezierPath *handX = [UIBezierPath bezierPath];   // 指向 12 点
    [handX moveToPoint:c];
    [handX addLineToPoint:CGPointMake(c.x, c.y - h * 0.28)];
    handX.lineWidth = 1.4;
    [handX stroke];
    UIBezierPath *handY = [UIBezierPath bezierPath];   // 指向 3 点
    [handY moveToPoint:c];
    [handY addLineToPoint:CGPointMake(c.x + w * 0.24, c.y)];
    handY.lineWidth = 1.4;
    [handY stroke];
}
@end

@interface JAGridHeader : UICollectionReusableView
@property (nonatomic, strong) UILabel *dayLab;         // 「2026年11月12日」（该天第一组才显示）
@property (nonatomic, strong) UIView *dashLine;        // 日期右边的虚线
@property (nonatomic, strong) JAGridClockView *clockView;
@property (nonatomic, strong) UILabel *hourLab;        // 「22:00」
- (void)configDayTitle:(NSString *)dayTitle hourTitle:(NSString *)hourTitle;
@end

@implementation JAGridHeader
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor whiteColor];

        _dayLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _dayLab.font = [UIFont boldSystemFontOfSize:20];
        _dayLab.textColor = [UIColor colorWithWhite:0.10 alpha:1.0];
        [self addSubview:_dayLab];

        _dashLine = [[UIView alloc] initWithFrame:CGRectZero];
        _dashLine.backgroundColor = [UIColor clearColor];
        [self addSubview:_dashLine];

        _clockView = [[JAGridClockView alloc] initWithFrame:CGRectZero];
        [self addSubview:_clockView];

        _hourLab = [[UILabel alloc] initWithFrame:CGRectZero];
        _hourLab.font = [UIFont systemFontOfSize:16];
        _hourLab.textColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.95 alpha:1.0];
        [self addSubview:_hourLab];
    }
    return self;
}
- (void)configDayTitle:(NSString *)dayTitle hourTitle:(NSString *)hourTitle {
    BOOL hasDay = dayTitle.length > 0;
    self.dayLab.text = hasDay ? dayTitle : nil;
    self.dayLab.hidden = !hasDay;
    self.dashLine.hidden = !hasDay;
    self.hourLab.text = hourTitle;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    BOOL hasDay = !self.dayLab.hidden;
    CGFloat y = 2;
    if (hasDay) {
        CGSize sz = [self.dayLab sizeThatFits:CGSizeMake(w - 70, 28)];
        self.dayLab.frame = CGRectMake(16, y, sz.width, 28);
        CGFloat dashX = 16 + sz.width + 12;
        self.dashLine.frame = CGRectMake(dashX, y + 14, MAX(0, w - dashX - 16), 1);
        [self refreshDash];
        y += 34;
    }
    self.clockView.frame = CGRectMake(16, y + 3, 20, 20);
    // v2.8.1：没有时钟的「空天说明」从左边 16 起排，和日期标题左对齐
    CGFloat hx = self.clockView.hidden ? 16 : 42;
    self.hourLab.frame = CGRectMake(hx, y, MAX(0, w - hx - 16), 26);
}
- (void)refreshDash {
    self.dashLine.layer.sublayers = nil;
    CGFloat len = self.dashLine.bounds.size.width;
    if (len < 2) return;
    CAShapeLayer *l = [CAShapeLayer layer];
    l.strokeColor = [UIColor colorWithWhite:0.80 alpha:1.0].CGColor;
    l.fillColor = nil;
    l.lineWidth = 1.0;
    l.lineDashPattern = @[@5, @5];
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(0, 0.5)];
    [p addLineToPoint:CGPointMake(len, 0.5)];
    l.path = p.CGPath;
    [self.dashLine.layer addSublayer:l];
}
@end

// ---------- 格子页本体 ----------

@interface JAGridReplayViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) id myCamera;
@property (nonatomic, strong) NSMutableArray *days;    // 按天原始数据 @[@{@"day":NSNumber, @"items":NSArray}]（新→旧）
@property (nonatomic, strong) NSMutableArray *secs;    // v2.7：展示用「小时组」，见 rebuildLayout
@property (nonatomic, strong) NSMutableArray *flat;    // 与 secs 顺序完全一致，连播/翻页索引用
@property (nonatomic, strong) UICollectionView *cv;
@property (nonatomic, strong) UILabel *hintLab;
@property (nonatomic, strong) UIBarButtonItem *autoItem;
@property (nonatomic, strong) NSMutableArray *retained; // 借用中的官方 dataVC（保活）
@property (nonatomic, assign) long long nextDay;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL autoNext;
@property (nonatomic, assign) NSInteger emptyStreak;
@property (nonatomic, assign) BOOL gaveUp;
@property (nonatomic, assign) NSInteger playIndex;
@property (nonatomic, strong) id playingVC;
@property (nonatomic, strong) NSMutableSet *knownDays;   // v2.8：已确认有录像的日期（日历红点）
@property (nonatomic, copy) NSString *cacheKey;          // v2.8：该设备的按天缓存键
@property (nonatomic, strong) UIBarButtonItem *calItem;  // v2.8：右上角日期选择器
@property (nonatomic, strong) UIView *calPanel;          // v2.8：月历弹层
@property (nonatomic, assign) BOOL didFirstLoad;          // v2.8：本次进入是否已发起首轮加载
@property (nonatomic, strong) NSDate *calMonth;           // v2.8：日历当前显示的月份
@end

@implementation JAGridReplayViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"回放";
    self.days = [NSMutableArray array];
    self.secs = [NSMutableArray array];
    self.flat = [NSMutableArray array];
    self.retained = [NSMutableArray array];
    self.autoNext = YES;
    self.playIndex = -1;
    self.emptyStreak = 0;
    self.nextDay = JAGridTodayStart();

    self.knownDays = [NSMutableSet set];
    // v2.8：按设备做缓存目录键（FNV-1a，和封面缓存同一套思路）
    NSString *devId = JAGridDeviceId(self.myCamera);
    if (devId.length) {
        uint32_t h = 2166136261u;
        for (NSUInteger i = 0; i < devId.length; i++) {
            h ^= (uint32_t)[devId characterAtIndex:i];
            h *= 16777619u;
        }
        self.cacheKey = [NSString stringWithFormat:@"%08x", h];
    }

    self.autoItem = [[UIBarButtonItem alloc] initWithTitle:@"连播 开"
                                                    style:UIBarButtonItemStylePlain
                                                   target:self
                                                   action:@selector(toggleAutoNext)];
    // v2.8：右上角日期选择器（月历，有录像的日期带红点）
    UIImage *calImg = [UIImage systemImageNamed:@"calendar"];
    if (calImg) {
        self.calItem = [[UIBarButtonItem alloc] initWithImage:calImg
                                                       style:UIBarButtonItemStylePlain
                                                      target:self
                                                      action:@selector(showCalendarPanel)];
    } else {
        self.calItem = [[UIBarButtonItem alloc] initWithTitle:@"日期"
                                                        style:UIBarButtonItemStylePlain
                                                       target:self
                                                       action:@selector(showCalendarPanel)];
    }
    self.navigationItem.rightBarButtonItems = @[self.calItem, self.autoItem];

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
    self.hintLab.font = [UIFont systemFontOfSize:15];
    self.hintLab.textColor = [UIColor colorWithWhite:0.45 alpha:1.0];
    // v2.6：提示文案居中（水平 + 垂直都在页面正中）
    self.hintLab.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.hintLab];
    self.hintLab.hidden = YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // v2.7：内容避开安全区 —— 否则最上面的日期分组会被顶部「回放 / 连播」那条导航栏压住
    UIEdgeInsets si = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) si = self.view.safeAreaInsets;
    CGRect r = UIEdgeInsetsInsetRect(self.view.bounds, si);
    self.cv.frame = r;
    CGFloat usable = r.size.width - 32 - 18;
    CGFloat itemW = floor(usable / 3.0);
    UICollectionViewFlowLayout *lay = (UICollectionViewFlowLayout *)self.cv.collectionViewLayout;
    lay.itemSize = CGSizeMake(itemW, itemW * 152.0 / 236.0 + 24);
    self.hintLab.frame = CGRectMake(20, r.origin.y + (r.size.height - 64) / 2.0,
                                    r.size.width - 40, 64);
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self.view setNeedsLayout];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.myCamera) {
        self.hintLab.hidden = NO;
        self.hintLab.text = @"没拿到设备对象（myCamera 为空），格子页无法读取录像";
        return;
    }
    long long today = JAGridTodayStart();
    // v2.8：缓存先上屏 —— 第二次进页面直接有内容（不用等网络/等官方的隐藏数据页）
    if (self.days.count == 0) {
        NSArray *cached = JAGridDayCacheRead(self.cacheKey, today);
        if (cached.count) {
            [self appendDay:today items:cached];
            [self.knownDays addObject:@(today)];
            self.hintLab.hidden = YES;
        }
    }
    if (!self.didFirstLoad && !self.gaveUp) {
        self.didFirstLoad = YES;
        if (self.nextDay <= 0 || self.nextDay > today) self.nextDay = today;
        [self loadOneMoreDay];
    }
}

// ---------- 拉一天事件（借官方数据层） ----------

- (void)fetchDaySD:(long long)dayStart completion:(void (^)(NSArray *events))cb {
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

    [self gridTryFetch:dataVC attempt:0 day:dayStart best:nil stable:0 completion:cb];
}

// ---------- v2.9：借用官方「消息列表」页的取数能力 ----------
// 之前的做法是「照着消息列表的行为自己重写一遍」（先猜 JAMessageModel 的参数，
// 再回退 SD 段），参数一猜错就整体不对。这里改成直接借官方页面自己的取数链路：
//   * 它是 JABasicViewController 子类，设备走父类的 myCamera（dump 已确认）
//   * loadDataFirstWithDate:showHud:isTableRefresh:finish: 是它自己的按天首屏
//   * loadMoreFirstDateWithShowHud:isTableRefresh:finish: 是它自己的翻页
//   * warnInfoListArr 就是它 tableView 的数据源，isSelfEndMoreData 是"没有更多"
// 这样条数、抓拍图、跨天、分页结果与用户在消息列表里看到的完全一致。
// v2.9.1：不再新建隐藏实例（会在它 viewDidLoad 时闪退），改为复用用户真打开过
// 的那个实例（见 JAMsgListVCFor / ja_msgList_viewDidLoad）。

- (void)fetchDayMessageNative:(long long)day completion:(void (^)(NSArray *items))cb {
    // 返回约定：cb(nil) = 这条通道走不通；cb(@[]) = 官方明确说这天没有消息
    // v2.9.1：只借用用户真实打开过的那个实例，不再新建（新建会在它 viewDidLoad
    // 时闪退）。没捕获到就交回上层，走直连消息模型 + SD 段兜底。
    id mvc = JAMsgListVCFor(self.myCamera);
    if (!mvc || ![mvc isKindOfClass:UIViewController.class]) { if (cb) cb(nil); return; }
    UIViewController *vc = (UIViewController *)mvc;

    NSString *ds = JAGridDayStr(day);
    @try { [mvc setValue:ds forKey:@"currentDateStr"]; } @catch (NSException *e) {}
    // 先清掉它上次留下的数据，免得把别的天/别的设备的结果当成本天结果
    @try {
        id arr = [mvc valueForKey:@"warnInfoListArr"];
        if ([arr isKindOfClass:NSMutableArray.class]) [(NSMutableArray *)arr removeAllObjects];
    } @catch (NSException *e) {}

    SEL ldf = NSSelectorFromString(@"loadDataFirstWithDate:showHud:isTableRefresh:finish:");
    if (![vc respondsToSelector:ldf]) { if (cb) cb(nil); return; }
    // finish 的 block 签名未知（@?），传一个无参空 block 最安全：
    // 就算它按 (BOOL) 调用，多余参数也被忽略
    id noopFinish = ^{};
    BOOL sent = NO;
    @try {
        ((void (*)(id, SEL, id, BOOL, BOOL, id))objc_msgSend)(vc, ldf, ds, NO, NO, noopFinish);
        sent = YES;
    } @catch (NSException *e) {}
    if (!sent) {
        // 首参也可能是 NSDate；字符串版本抛了就用 NSDate 再试一次
        @try {
            NSDate *d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)day];
            ((void (*)(id, SEL, id, BOOL, BOOL, id))objc_msgSend)(vc, ldf, d, NO, NO, noopFinish);
            sent = YES;
        } @catch (NSException *e2) {}
    }
    if (!sent) { if (cb) cb(nil); return; }

    [self pollNativeMessageVC:vc day:day round:0 lastN:0 stable:0 moreLoads:0 completion:cb];
}

// 轮询官方页的数据源：条数不再增长就收工；还有更多页就替它调翻页
- (void)pollNativeMessageVC:(UIViewController *)mvc day:(long long)day
                       round:(NSInteger)round lastN:(NSInteger)lastN
                      stable:(NSInteger)stable moreLoads:(NSInteger)moreLoads
                  completion:(void (^)(NSArray *items))cb {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        NSArray *arr = nil;
        @try { arr = [mvc valueForKey:@"warnInfoListArr"]; } @catch (NSException *e) {}
        NSInteger n = [arr isKindOfClass:NSArray.class] ? (NSInteger)arr.count : 0;
        BOOL end = NO;
        @try { end = [[mvc valueForKey:@"isSelfEndMoreData"] boolValue]; } @catch (NSException *e) {}
        // 官方自己判定的「我这台设备这天没有消息」，是这个页面唯一的权威空答案
        BOOL noData = NO;
        @try { noData = [[mvc valueForKey:@"isSelfNoData"] boolValue]; } @catch (NSException *e) {}

        NSInteger ls = lastN;
        NSInteger st = stable;
        NSInteger ml = moreLoads;
        if (n > ls) { ls = n; st = 0; } else { st += 1; }

        // 数据停了但官方说还有更多 → 替它翻一页（最多 6 页，防止死循环）
        if (st >= 2 && n > 0 && !end && ml < 6) {
            SEL lm = NSSelectorFromString(@"loadMoreFirstDateWithShowHud:isTableRefresh:finish:");
            if ([mvc respondsToSelector:lm]) {
                @try {
                    id noop2 = ^{};
                    ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(mvc, lm, NO, NO, noop2);
                    ml += 1;
                    st = 0;
                } @catch (NSException *e) { end = YES; }
            } else {
                end = YES;
            }
        }

        // 收工条件只看「数据稳定」，noData 只用来区分「权威空」还是「通道没跑起来」
        BOOL done = (st >= 3) || (round >= 16) || (st >= 2 && (end || ml >= 6));
        if (done) {
            NSArray *items = JAGridEntriesFromMessages(arr, day);
            // 一条都没拿到、官方也没说自己「无数据」→ 当作通道没跑起来，
            // 交回上层继续试，避免把「网络没回来」误判成「这天没有报警」
            if (n == 0 && !noData) { if (cb) cb(nil); return; }
            if (cb) cb(items ?: @[]);
            return;
        }
        [s pollNativeMessageVC:mvc day:day round:round + 1 lastN:ls
                          stable:st moreLoads:ml completion:cb];
    });
}

// v2.7：多次采样，取「该天有效条数最多」的那次，连续 2 次不再增长才收工。
// 官方列表是异步/分段回来的，一拿到非空就返回会少条 —— 这正对应
// 「翻过报警消息再回格子页就变多」的现象。
- (void)gridTryFetch:(id)dataVC attempt:(NSInteger)attempt day:(long long)day
                 best:(NSArray *)bestCand stable:(NSInteger)stable
           completion:(void (^)(NSArray *events))cb {
    if (!dataVC) { if (cb) cb(nil); return; }
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (!s) return;
        NSArray *ev = JAGridFindEvents(dataVC);
        NSInteger n = JAGridDayEventCount(ev, day);
        NSInteger bn = JAGridDayEventCount(bestCand, day);
        NSArray *cand = bestCand;
        NSInteger st = stable;
        if (n > bn) { cand = ev; st = 0; } else { st += 1; }
        NSInteger cn = JAGridDayEventCount(cand, day);
        BOOL settled = (cn > 0 && st >= 2);
        NSInteger limit = (cn > 0) ? 5 : 3;      // 已经拿到数据就多采两次；一直空就别耗着
        if (settled || attempt + 1 >= limit) {
            [s gridStopDataVC:dataVC];
            if (cb) cb(cn > 0 ? cand : nil);
            return;
        }
        [s gridTryFetch:dataVC attempt:attempt + 1 day:day best:cand stable:st completion:cb];
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

- (BOOL)hasDay:(long long)day {
    for (NSDictionary *d in self.days) {
        if ([(NSNumber *)d[@"day"] longLongValue] == day) return YES;
    }
    return NO;
}

- (void)loadOneMoreDay {
    if (self.loading || !self.myCamera) return;
    if (self.nextDay <= 0) self.nextDay = JAGridTodayStart();
    long long day = self.nextDay;
    self.loading = YES;

    // ① 有缓存就直接上屏（第二次进页面 = 秒开）
    NSArray *cached = JAGridDayCacheRead(self.cacheKey, day);
    if (cached.count && ![self hasDay:day]) {
        [self appendDay:day items:cached];
        [self.knownDays addObject:@(day)];
        self.hintLab.hidden = YES;
    } else if (!cached.count && self.days.count == 0) {
        self.hintLab.hidden = NO;
        // v2.9.1：要复用官方消息列表的实例才谈得上「完全一样」。还没打开过那页时
        // 给一句明确引导，不然用户会以为这版没生效。
        if (!JAMsgListVCFor(self.myCamera)) {
            self.hintLab.text = @"正在读取该日录像…\n（先在「消息列表」打开一次这台设备，这里的条数就会和它完全一致）";
        } else {
            self.hintLab.text = @"正在读取该日录像…";
        }
    }

    __weak typeof(self) ws = self;
    // ② v2.9：官方消息列表页（隐藏实例）—— 数据/分页/抓拍图与它自己完全一致
    [self fetchDayMessageNative:day completion:^(NSArray *items) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        if (items) {              // 非 nil（哪怕是空数组）= 官方给了权威答案
            [s onDayLoaded:day items:items];
            return;
        }
        // ③ 通道走不通才退到「直连 JAMessageModel」（v2.8 那层）
        JAGridFetchMessageDay(s.myCamera, day, ^(NSArray *a2) {
            __strong typeof(ws) s2 = ws;
            if (!s2) return;
            if (a2.count > 0) { [s2 onDayLoaded:day items:a2]; return; }
            // ④ 最后回退官方 SD 段（v2.7 原链路，保证不比之前差）
            [s2 fetchDaySD:day completion:^(NSArray *events) {
                __strong typeof(ws) s3 = ws;
                if (!s3) return;
                [s3 onDayLoaded:day items:JAGridEntriesFromEvents(events, day)];
            }];
        });
    }];
}

- (void)onDayLoaded:(long long)day items:(NSArray *)items {
    self.loading = NO;
    self.nextDay = day - 86400;
    long long today = JAGridTodayStart();
    if (items.count > 0) {
        self.emptyStreak = 0;
        [self.knownDays addObject:@(day)];
        [self appendDay:day items:items];
        if (self.cacheKey.length) JAGridDayCacheWrite(self.cacheKey, day, items);
        self.hintLab.hidden = YES;
        return;
    }
    // 网络这次没回，但缓存里已经有这天 → 保留缓存内容，不算“没录像”
    if ([self hasDay:day]) {
        self.emptyStreak = 0;
        self.hintLab.hidden = YES;
        return;
    }
    // v2.8.1：刚过 0 点时「今天还没有任何报警」是完全正常的状态 —— 显示当天抬头 +
    // 一句说明，不累加“连续空”，也不自动往前翻；用户往下拉才去读前一天。
    if (day >= today) {
        self.emptyStreak = 0;
        self.gaveUp = NO;
        [self appendDay:day items:@[] note:@"当日还没有任何报警消息，往下拉可读取前一天"];
        self.hintLab.hidden = YES;
        return;
    }
    self.emptyStreak++;
    if (self.emptyStreak >= 3) {
        self.gaveUp = YES;
        self.hintLab.hidden = NO;
        self.hintLab.text = @"往前 3 天都没有读到录像记录（设备可能没上报这几天的报警）";
    } else {
        [self loadOneMoreDay];
    }
}

- (void)appendDay:(long long)day items:(NSArray *)items {
    [self appendDay:day items:items note:nil];
}

- (void)appendDay:(long long)day items:(NSArray *)items note:(NSString *)note {
    // v2.8.1：空天也允许入组 —— 只为了显示「2026年11月14日 + 当日还没有任何报警消息」
    // 这样一个抬头，不下发任何格子
    if (items.count == 0 && note.length == 0) return;
    NSDictionary *bucket = @{@"day": @(day),
                             @"items": (items ?: @[]),
                             @"note": (note ?: @"")};
    // v2.7：同一天已经加过就整体替换（防同一天出现两个分组）
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < self.days.count; i++) {
        NSDictionary *old = (NSDictionary *)self.days[i];
        long long oldDay = [(NSNumber *)old[@"day"] longLongValue];
        if (oldDay == day) {
            self.days[i] = bucket;
            replaced = YES;
            break;
        }
    }
    if (!replaced) [self.days addObject:bucket];
    [self rebuildLayout];
}

// v2.7：把「按天」的数据拍平成「天 → 小时」的展示分组（天新→旧、小时晚→早），
// 同时按展示顺序重建 flat，保证连播 / scrollToItem / 点击定位三者顺序一致。
- (void)rebuildLayout {
    [self.days sortUsingComparator:^NSComparisonResult(id a, id b) {
        long long da = [(NSNumber *)[(NSDictionary *)a objectForKey:@"day"] longLongValue];
        long long db = [(NSNumber *)[(NSDictionary *)b objectForKey:@"day"] longLongValue];
        if (da == db) return NSOrderedSame;
        return da > db ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSMutableArray *secs = [NSMutableArray array];
    NSMutableArray *flat = [NSMutableArray array];
    for (NSUInteger di = 0; di < self.days.count; di++) {
        NSDictionary *dayDict = (NSDictionary *)self.days[di];
        long long day = [(NSNumber *)dayDict[@"day"] longLongValue];
        NSArray *items = (NSArray *)dayDict[@"items"];
        // v2.8.1：当天还没有任何报警 → 仍给一个「日期抬头 + 说明」的空分组
        if (items.count == 0) {
            NSString *note = (NSString *)dayDict[@"note"];
            if (note.length) {
                [secs addObject:@{@"day": @(day), @"hour": @(-1),
                                  @"dayTitle": JAGridDayText(day),
                                  @"hourTitle": @"", @"items": @[],
                                  @"note": note}];
            }
            continue;
        }
        NSMutableDictionary *byHour = [NSMutableDictionary dictionary];
        for (NSDictionary *e in items) {
            long long sec = [(NSNumber *)e[@"sec"] longLongValue];
            NSInteger hour = (NSInteger)(((sec + 28800LL) % 86400LL) / 3600LL);   // 北京时区小时
            NSMutableArray *bucket = (NSMutableArray *)byHour[@(hour)];
            if (!bucket) {
                bucket = [NSMutableArray array];
                byHour[@(hour)] = bucket;
            }
            [bucket addObject:e];
        }
        NSArray *hours = [[byHour allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
            return [(NSNumber *)b compare:(NSNumber *)a];      // 小时从晚到早
        }];
        BOOL firstHourOfDay = YES;
        for (NSNumber *h in hours) {
            NSMutableArray *bucket = (NSMutableArray *)byHour[h];
            [bucket sortUsingComparator:^NSComparisonResult(id a, id b) {
                long long sa = [(NSNumber *)[(NSDictionary *)a objectForKey:@"sec"] longLongValue];
                long long sb = [(NSNumber *)[(NSDictionary *)b objectForKey:@"sec"] longLongValue];
                if (sa == sb) return NSOrderedSame;
                return sa > sb ? NSOrderedAscending : NSOrderedDescending;
            }];
            NSString *dayTitle = firstHourOfDay ? JAGridDayText(day) : @"";
            NSString *hourTitle = [NSString stringWithFormat:@"%02ld:00", (long)h.integerValue];
            [secs addObject:@{@"day": @(day), @"hour": h, @"dayTitle": dayTitle,
                              @"hourTitle": hourTitle, @"items": bucket}];
            [flat addObjectsFromArray:bucket];
            firstHourOfDay = NO;
        }
    }
    self.secs = secs;
    self.flat = flat;
    [self.cv reloadData];
}

// ---------- 集合视图 ----------

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return (NSInteger)self.secs.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.secs.count) return 0;
    NSDictionary *d = (NSDictionary *)self.secs[section];
    NSArray *items = (NSArray *)d[@"items"];
    return (NSInteger)items.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)ip {
    JAGridCell *c = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    if (ip.section < (NSInteger)self.secs.count) {
        NSDictionary *secDict = (NSDictionary *)self.secs[ip.section];
        NSArray *items = (NSArray *)secDict[@"items"];
        if (ip.item < (NSInteger)items.count) {
            NSDictionary *e = (NSDictionary *)items[ip.item];
            NSNumber *sec = (NSNumber *)e[@"sec"];
            c.timeLab.text = JAGridTimeText(sec.longLongValue);
            id imgObj = e[@"imgObj"];
            if ([imgObj isKindOfClass:UIImage.class]) {
                [c showImage:(UIImage *)imgObj];
            } else {
                id u = e[@"img"];
                if (![u isKindOfClass:NSString.class]) u = JAGridImageURL(e[@"ev"]);
                [c setImageURL:([u isKindOfClass:NSString.class] ? (NSString *)u : nil)];
            }
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
    if (ip.section < (NSInteger)self.secs.count) {
        NSDictionary *secDict = (NSDictionary *)self.secs[ip.section];
        NSString *note = (NSString *)secDict[@"note"];
        if (note.length) {
            // v2.8.1：空天 —— 只留日期抬头，时钟换成一句灰色说明
            [h configDayTitle:(NSString *)secDict[@"dayTitle"] hourTitle:@""];
            h.clockView.hidden = YES;
            h.hourLab.text = note;
            h.hourLab.font = [UIFont systemFontOfSize:13];
            h.hourLab.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        } else {
            [h configDayTitle:(NSString *)secDict[@"dayTitle"]
                     hourTitle:(NSString *)secDict[@"hourTitle"]];
            h.clockView.hidden = NO;
            h.hourLab.font = [UIFont systemFontOfSize:16];
            h.hourLab.textColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.95 alpha:1.0];
        }
    }
    return h;
}

// v2.7：分组头高度 —— 有新的一天大标题就高一些（日期行 + 小时行），否则只有小时行
- (CGSize)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)collectionViewLayout
    referenceSizeForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.secs.count) return CGSizeZero;
    NSDictionary *secDict = (NSDictionary *)self.secs[section];
    BOOL hasDay = [(NSString *)secDict[@"dayTitle"] length] > 0;
    return CGSizeMake(self.cv.bounds.size.width, hasDay ? 78 : 42);
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
    if (ip.section >= (NSInteger)self.secs.count) return;
    NSDictionary *secDict = (NSDictionary *)self.secs[ip.section];
    NSArray *items = (NSArray *)secDict[@"items"];
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
    for (NSInteger s = 0; s < (NSInteger)self.secs.count; s++) {
        NSDictionary *secDict = (NSDictionary *)self.secs[s];
        NSArray *items = (NSArray *)secDict[@"items"];
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

    // v2.8：RTC hooks 补装（和详情页链路一致）—— 少了这个，viewDidAppear 不会
    // 触发定位，进去就只剩官方自动播的最新实时画面
    if (!g_rtcHooked) {
        JASetImp(rtc, @selector(viewDidAppear:), (IMP)ja_rtc_viewDidAppear, &g_orig_rtc_vda);
        JASetImp(rtc, @selector(viewDidDisappear:), (IMP)ja_rtc_viewDidDisappear, &g_orig_rtc_vdd);
        g_rtcHooked = YES;
    }

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

    // v2.6：云回放式「35 秒片段」观感 —— 进播放页 1s 后隐藏时间轴/拖动条，
    // 只留画面，看完自动回格子页接着下一格（不再显示可拖的时间线）。
    __weak id wvc = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id v = wvc;
        if (!v) return;
        @try {
            id tl = [v valueForKey:@"timeLineView"];
            if ([tl isKindOfClass:[UIView class]]) {
                UIView *tview = (UIView *)tl;
                tview.hidden = YES;
            }
        } @catch (NSException *e) {}
    });

    // v2.8：画面右上角标出这一格的目标时间 —— 时间轴被隐藏了，定位有没有生效
    // 只能靠这个角标和画面做对照
    __weak id wvc2 = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *p = (UIViewController *)wvc2;
        if (!p || !p.isViewLoaded) return;
        for (UIView *sv in p.view.subviews) if (sv.tag == 0x1A65) return;
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.tag = 0x1A65;
        lab.font = [UIFont systemFontOfSize:12];
        lab.textColor = [UIColor whiteColor];
        lab.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.layer.cornerRadius = 6;
        lab.clipsToBounds = YES;
        lab.text = [NSString stringWithFormat:@"目标 %@", JAGridTimeText(sec)];
        CGFloat w = p.view.bounds.size.width;
        lab.frame = CGRectMake(w - 122, 96, 110, 22);
        [p.view addSubview:lab];
    });

    // 35 秒后自动跳下一格
    if (self.autoNext) {
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35.0 * NSEC_PER_SEC)),
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

// ---------- v2.8：右上角日期选择器（月历 + 有录像日期红点） ----------

- (void)showCalendarPanel {
    if (self.calPanel) { [self hideCalendarPanel]; return; }
    if (!self.calMonth) self.calMonth = [NSDate date];

    UIView *mask = [[UIView alloc] initWithFrame:self.view.bounds];
    mask.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:mask];
    self.calPanel = mask;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(hideCalendarPanel)];
    [mask addGestureRecognizer:tap];

    CGFloat sw = self.view.bounds.size.width;
    CGFloat w = MIN(sw - 24, 356);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sw - w) / 2.0, 74, w, 356)];
    card.tag = 0x1A64;
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 14;
    card.clipsToBounds = YES;
    // 卡片吞掉点击，避免点卡片本体就关掉
    [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(noopTap)]];
    [mask addSubview:card];
    [self renderCalendarCard:card];
}

- (void)noopTap {
}

- (void)hideCalendarPanel {
    if (!self.calPanel) return;
    [self.calPanel removeFromSuperview];
    self.calPanel = nil;
}

- (NSCalendar *)calCalendar {
    NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
    return cal;
}

- (void)renderCalendarCard:(UIView *)card {
    for (UIView *v in [card.subviews copy]) [v removeFromSuperview];
    CGFloat w = card.bounds.size.width;

    NSCalendar *cal = [self calCalendar];
    NSDateComponents *mc = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth)
                                  fromDate:self.calMonth];
    NSDateComponents *cm = [[NSDateComponents alloc] init];
    cm.year = mc.year;
    cm.month = mc.month;
    cm.day = 1;
    NSDate *firstDay = [cal dateFromComponents:cm];
    NSInteger daysInMonth = [cal rangeOfUnit:NSCalendarUnitDay
                                     inUnit:NSCalendarUnitMonth
                                    forDate:firstDay].length;
    NSInteger weekday = [cal component:NSCalendarUnitWeekday fromDate:firstDay];   // 1=周日

    // 标题行
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 120, 24)];
    title.font = [UIFont boldSystemFontOfSize:16];
    title.text = [NSString stringWithFormat:@"%ld年%ld月", (long)mc.year, (long)mc.month];
    [card addSubview:title];

    UIButton *prev = [UIButton buttonWithType:UIButtonTypeSystem];
    prev.frame = CGRectMake(w - 112, 6, 40, 36);
    prev.titleLabel.font = [UIFont systemFontOfSize:18];
    [prev setTitle:@"‹" forState:UIControlStateNormal];
    prev.tag = -1;
    [prev addTarget:self action:@selector(onCalendarMonthButton:)
   forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:prev];

    UIButton *next = [UIButton buttonWithType:UIButtonTypeSystem];
    next.frame = CGRectMake(w - 72, 6, 40, 36);
    next.titleLabel.font = [UIFont systemFontOfSize:18];
    [next setTitle:@"›" forState:UIControlStateNormal];
    next.tag = 1;
    [next addTarget:self action:@selector(onCalendarMonthButton:)
   forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:next];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(w - 38, 6, 36, 36);
    close.titleLabel.font = [UIFont systemFontOfSize:15];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.tag = 99;
    [close addTarget:self action:@selector(onCalendarMonthButton:)
     forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    // 星期行
    NSArray *wks = @[@"日", @"一", @"二", @"三", @"四", @"五", @"六"];
    CGFloat gridW = w - 24;
    CGFloat colW = gridW / 7.0;
    for (NSInteger i = 0; i < 7; i++) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12 + colW * i, 44, colW, 20)];
        l.font = [UIFont systemFontOfSize:12];
        l.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        l.textAlignment = NSTextAlignmentCenter;
        l.text = wks[i];
        [card addSubview:l];
    }

    // 日期网格
    CGFloat top = 68;
    CGFloat rowH = 42;
    NSInteger lead = (NSInteger)(weekday - 1);      // 周日开头，前面空几格
    long long todayStart = JAGridTodayStart();
    for (NSInteger d = 1; d <= daysInMonth; d++) {
        NSInteger idx = lead + d - 1;
        NSInteger row = idx / 7;
        NSInteger col = idx % 7;
        if (row > 5) break;
        NSDateComponents *dc = [[NSDateComponents alloc] init];
        dc.year = mc.year;
        dc.month = mc.month;
        dc.day = d;
        NSDate *dd = [cal dateFromComponents:dc];
        long long dayStart = (long long)[dd timeIntervalSince1970];
        dayStart = dayStart - ((dayStart + 28800LL) % 86400LL);   // 对齐北京时间 0 点

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(12 + colW * col, top + rowH * row, colW, rowH);
        btn.tag = (NSInteger)dayStart;
        [btn setTitle:[NSString stringWithFormat:@"%ld", (long)d] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:15];
        [btn setTitleColor:[UIColor colorWithWhite:0.15 alpha:1.0] forState:UIControlStateNormal];
        if (dayStart == todayStart) {
            [btn setTitleColor:[UIColor colorWithRed:0.13 green:0.55 blue:0.95 alpha:1.0]
                       forState:UIControlStateNormal];
        }
        [btn addTarget:self action:@selector(onPickDayButton:)
       forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:btn];

        // 有录像的日期：数字下面一个红点
        if ([self.knownDays containsObject:@(dayStart)]) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6, 6)];
            dot.backgroundColor = [UIColor colorWithRed:0.92 green:0.24 blue:0.22 alpha:1.0];
            dot.layer.cornerRadius = 3;
            dot.center = CGPointMake(colW / 2.0, rowH - 9);
            dot.userInteractionEnabled = NO;
            [btn addSubview:dot];
        }
    }
}

- (void)onCalendarMonthButton:(UIButton *)b {
    if (b.tag == 99) { [self hideCalendarPanel]; return; }
    NSCalendar *cal = [self calCalendar];
    self.calMonth = [cal dateByAddingUnit:NSCalendarUnitMonth value:(NSInteger)b.tag
                                   toDate:self.calMonth options:0];
    UIView *card = nil;
    for (UIView *v in self.calPanel.subviews) {
        if (v.tag == 0x1A64) { card = v; break; }
    }
    if (card) [self renderCalendarCard:card];
}

- (void)onPickDayButton:(UIButton *)b {
    long long day = (long long)b.tag;
    [self jumpToDay:day];
}

- (void)jumpToDay:(long long)day {
    [self hideCalendarPanel];
    if (day < 1000000000LL) return;
    self.gaveUp = NO;
    self.emptyStreak = 0;
    self.didFirstLoad = YES;
    self.loading = NO;
    [self.days removeAllObjects];
    self.nextDay = day;
    [self rebuildLayout];
    self.hintLab.hidden = YES;
    [self loadOneMoreDay];
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

// v2.8：属性链拿不到 camera 时（第三台设备的卡片层级就是这样），退化为拿卡片上
// 的设备名去 JAGroupManager.getAllMyCamera 里按名字匹配 —— 比"随便给一个 camera"
// 可靠，不会再出现点进去提示「没找到这台设备」。
static id JAGridCameraByNameNear(UIView *box) {
    id gm = JAGroupManagerShared();
    if (!gm || !box) return nil;
    id all = nil;
    @try { all = [gm performSelector:NSSelectorFromString(@"getAllMyCamera")]; }
    @catch (NSException *e) {}
    if (![all isKindOfClass:NSArray.class] || [all count] == 0) return nil;

    NSMutableArray *names = [NSMutableArray array];
    UIView *x = box;
    int level = 0;
    while (x && level < 10) {
        for (UIView *s in x.subviews) {
            NSString *t = JAGridViewText(s);
            if (t.length >= 2 && t.length <= 20) [names addObject:t];
        }
        x = x.superview;
        level++;
    }
    if (names.count == 0) return nil;
    for (NSString *n in names) {
        for (id cam in all) {
            NSString *cn = JAGridDeviceName(cam);
            if (!cn.length) continue;
            if ([cn isEqualToString:n] || [n containsString:cn] || [cn containsString:n]) return cam;
        }
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
    return JAGridCameraByNameNear(v);   // v2.8：属性链走不通就按设备名匹配
}

// v2.8：入口去重 —— cell 复用会让卡片的视图层级重建，旧的入口 box 可能留在
// 上一层容器里，只按「同一 host + midX」判重会漏掉，结果一张卡片上叠出两个
// 「格子回放」（其中一个是旧层级里的残影，点它自然解析不到设备）。
static void JAGridCollectEntriesNear(UIView *root, CGPoint pt, NSMutableArray *out, int depth) {
    if (!root || depth > 8) return;
    for (UIView *s in root.subviews) {
        if (s.tag == JAGridEntryTag && s.window) {
            CGRect rw = [s convertRect:s.bounds toView:s.window];
            if (fabs(CGRectGetMidX(rw) - pt.x) < 14 && fabs(CGRectGetMidY(rw) - pt.y) < 14) {
                [out addObject:s];
            }
        }
        JAGridCollectEntriesNear(s, pt, out, depth + 1);
    }
}

static void JAGridPurgeEntriesUnder(UIView *v, int depth) {
    if (!v || depth > 4) return;
    NSMutableArray *del = [NSMutableArray array];
    for (UIView *s in v.subviews) {
        if (s.tag == JAGridEntryTag) [del addObject:s];
        else JAGridPurgeEntriesUnder(s, depth + 1);
    }
    for (UIView *d in del) [d removeFromSuperview];
}

static void JAGridInstallEntryInRow(UIView *cloud, UIView *ai) {
    if (!cloud || !ai || !cloud.window) return;
    if ([cloud isDescendantOfView:ai] || [ai isDescendantOfView:cloud]) return;
    UIView *host = JAGridCommonAncestor(cloud, ai);
    if (!host) return;

    CGRect rc = [cloud convertRect:cloud.bounds toView:host];
    CGRect ra = [ai convertRect:ai.bounds toView:host];
    if (fabs(CGRectGetMidY(rc) - CGRectGetMidY(ra)) > 10) return;   // 不在同一行
    if (CGRectGetMinX(ra) <= CGRectGetMinX(rc)) return;             // AI 应在右边

    CGFloat midX = (CGRectGetMidX(rc) + CGRectGetMidX(ra)) / 2.0;
    CGFloat midY = (CGRectGetMidY(rc) + CGRectGetMidY(ra)) / 2.0;

    // 已在同一位置装过就什么都不做（避免每 0.3s 重建一次导致闪烁）
    CGRect rcw = [cloud convertRect:cloud.bounds toView:nil];
    CGRect raw = [ai convertRect:ai.bounds toView:nil];
    CGPoint wp = CGPointMake((CGRectGetMidX(rcw) + CGRectGetMidX(raw)) / 2.0,
                             (CGRectGetMidY(rcw) + CGRectGetMidY(raw)) / 2.0);
    NSMutableArray *found = [NSMutableArray array];
    JAGridCollectEntriesNear(cloud.window, wp, found, 0);
    if (found.count > 0) {
        // 多余的重影全部删掉，只留第一个
        for (NSUInteger i = 1; i < found.count; i++) [found[i] removeFromSuperview];
        return;
    }
    // 这张卡片所在容器里的旧入口一律清掉，再装新的（保证一卡一口）
    JAGridPurgeEntriesUnder(host, 0);

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
    // v2.6：入口按钮出现太慢 —— 首 tick 1.5s→0.2s，间隔 0.8s→0.3s
    // （tick 只扫当前可见视图、有则直接 return，开销很小）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[JAGridEntryHub shared] tick];
        NSTimer *t = [NSTimer timerWithTimeInterval:0.3
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

static void ja_msgList_viewDidLoad(id self, SEL _cmd) {
    if (g_orig_msgList_vdl) ((void (*)(id, SEL))g_orig_msgList_vdl)(self, _cmd);
    @try {
        NSString *k = JAMsgListKey(JAVal(self, @"myCamera"));
        if (!k.length) return;
        if (!g_msgListVCs) g_msgListVCs = [NSMutableDictionary dictionary];
        // 每台设备留一份；超过 8 台就丢最早的那份，别让多个页面常驻
        if (g_msgListVCs.count >= 8 && !g_msgListVCs[k]) {
            id oldest = [[g_msgListVCs allKeys] firstObject];
            if (oldest) [g_msgListVCs removeObjectForKey:oldest];
        }
        g_msgListVCs[k] = self;
    } @catch (NSException *e) {}
}

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
    // v2.9.1：捕获用户真实打开过的「消息列表」页（按设备分桶留用）
    {
        Class msgCls = NSClassFromString(@"JANewDevWarnInfoListVC");
        if (msgCls) {
            JASetImp(msgCls, @selector(viewDidLoad), (IMP)ja_msgList_viewDidLoad,
                     &g_orig_msgList_vdl);
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

// v2.6：清掉历史版本在沙盒 Documents 里留下的诊断日志（幂等，删不到就算了）
static void JAPurgeOldLogs(void) {
    NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES) firstObject];
    if (!doc.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in @[@"jasdreplay.log", @"jasdreplay2.log"]) {
        NSString *p = [doc stringByAppendingPathComponent:n];
        if ([fm fileExistsAtPath:p]) [fm removeItemAtPath:p error:nil];
    }
}

// 类可能还没加载：等 App 启动完成后再尝试，最多 30 次，每次 0.5s
__attribute__((constructor))
static void JASDReplayInit(void) {
    JAPurgeOldLogs();           // v2.6：先清旧诊断日志
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
