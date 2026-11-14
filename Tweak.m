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
// v2.9（数据源 = 官方「消息列表」的同一批报警消息）：
//   「消息列表」页就是 JANewDevWarnInfoListVC，它的数据源 warnInfoListArr 来自
//   JAMessageModel（按天分页拉取的报警消息）。所以不必借用那个页面实例，直接用
//   JAMessageModel 走同一条接口，就能拿到同一批数据、同一批抓拍图：
//     · JAGridFetchMessageDay：[[JAMessageModel alloc] init] + KVC 设
//       selectedCamera / selectedDayString / searchFrom，调
//       fetchJooanMessagesWithDay:searchFrom:devId:devName:（阿里存量走 fetchAli…）；
//     · JAGridPollMessageModel：轮询 warnMessageList 到稳定，再替它翻页；
//     · 结果按秒去重、按天过滤，与消息列表是同一批数据。
//   格子页只负责「3 列 + 小时分隔」重排；这条通道取不到时才退官方 SD 段。
// v2.9.1 / v2.9.2（已全部删除）：曾改成「新建隐藏实例 / 捕获复用用户真打开过的
//   消息列表页」当数据引擎，两次实测都在官方网络回调里 SIGABRT（.ips：
//   MYAFNetworkingKit handleRequestCompletion → 官方代码 → forwarding）。
//   根因是复用共享实例：用户刚在那页滑过时，那页正在跑自己的分页请求，我们再改
//   它的 currentDateStr、清它的 warnInfoListArr 就把它的状态打乱，回调按错状态处理。
// v2.9.3（当前）：
//   · 删净整段官方页复用（fetchDayMessageNative / pollNativeMessageVC /
//     ja_msgList_viewDidLoad / hook 安装），从根上消除那条崩源；
//   · 直连通道补翻页：首屏稳定后调 loadMoreWarningMessagesWithDay:，某一页一条也
//     没多出就收工（最多 8 页）—— 修「只读到 22/21/20 点、19 点那条读不到」。
// v2.9.4（一天一屏，对齐官方消息列表）：
//   官方「消息列表」只看当天，要看前一天必须点右上角日期选择器。格子页照此改：
//   · 滚到底不再自动读前一天（旧实现滚到底就 loadOneMoreDay，于是「14 号读到一半
//     突然冒出 13 号」）；
//   · 列表底部固定一行「当日没有更多消息了 · 看其他日期请点右上角日期」；
//   · 该日真的没有报警消息时只给一个日期抬头 + 一句说明，不再连读三天、也不再弹
//     「往前 3 天都没有录像」；
//   · 连播到这一天最后一格就停，不再自动跳下一天。
// v2.9.5（修「第二台无封面」+「第三台入口双层 / 返回后点不进去」）：
//   · 封面：固定键表只有 40 个名字，不同型号 / 阿里云存量设备的报警模型是另一套字段。
//     改为把消息对象的所有 ivar 扫一遍：绝对地址里挑像图片的，相对路径用同对象的
//     http 地址补成绝对地址 —— 这样字段叫什么都能捞到。
//   · 入口双层：旧实现按屏幕坐标 ±14pt 判重，cell 一复用坐标就变，旧入口留在旧容器里
//     没人清，于是同一张卡片叠两个。改为按「设备身份（uid / 设备名）」判重、同身份全局
//     只留一个；每 0.3s 扫描前再清一遍「父视图里已经没有云存储 / AI分析」的残影。
//   · 返回后点不进去：旧实现每次点击都现场解析视图层级，从回放页返回后层级变了就报
//     「没找到这台设备」。改为安装入口时就把 camera 挂到入口上（associated object），
//     点击直接用，永不失手。
// v2.9.6：
//   · 底部提示改为「当日已全部加载完毕，选择日期重新加载」，整行居中。
//   · 修「消息多的设备读不全」：翻页后服务端比首屏慢得多，旧版 0.45s × 2 次没增长就判
//     「这页没数据」直接收工（所以滑到底只到 12:32:46，条数比消息列表少）。现在翻页后
//     第一次等 1.0s 再判，一页没多也再等 2 轮才收工，页数上限 8 → 20。
//   · 导航栏：删掉「连播 开」按钮，右上角只留日期选择器；中间改成「回放 + 正在加载」，
//     加载时右边出现蓝色「正在加载」，读完自动消失。
// v2.9.8：
//   · 修「第一台反而只读到 18:32:32」：v2.9.6 把翻页稳定判定放松到 1 次，正好撞进官方自己
//     还在请求（_isLoading）的窗口，此时翻页会被它吞掉 → 这一页「一条没多」→ 提前收工。
//     现在恢复「连续 2 次不增长」，并在翻页前先看 _isLoading，忙就等它跑完再翻。
//   · 加回官方 SD 回放页自带的时间轴 / 拖动条（v2.6 曾主动隐藏，用户要能自己拖）。
// v2.9.9：
//   · 报警时间改为「双源校正」：eid / 时间戳解析出的秒，与消息列表上直接显示的
//     HH:mm:ss 比对，都在当天且相差 ≤5 分钟才用解析值，否则以显示时间为准。
//     第二台就是解析结果和显示时间对不上 —— 既让它整天的记录被当成「不在本天」丢掉，
//     又让「查看录像」（官方页和格子页同一个 hook）定位到不存在的时刻、播不起来、
//     回落到实时流。这条同时修了「条数少」和「定位不对」。
//   · 封面再兜一层：递归扫字段值里的字典 / 数组 / JSON 字符串（有的型号把抓拍图塞在
//     eventData 里，不在顶层字段上）。
//   · 去掉自动连播（35 秒自动跳下一格），播放节奏完全交给用户。
// v2.9.10：
//   · 修「第一台只显示 18:00 之后」：v2.9.8 加的「翻页前先看官方 _isLoading，忙就等」
//     在有的设备上是毒药 —— 这个值一直为 YES，于是永远不翻页，只剩首屏一页。
//     改为完全不看 _isLoading，只按结果自适应：翻一页就看列表长度变没变，没变就把同一页
//     重试（最多 3 次），变了继续，成功翻满 24 页收工；首屏 6s 一条没有才当空天。
//     这样「请求被官方在途请求吞掉」也能靠重试救回来。
// v2.9.11：
//   · 按天缓存换目录（JAGridDays3）。v2.9.9 改了报警时间的算法，旧缓存里的秒是旧规则
//     算的 —— 复用会让格子定位到错误时刻。换目录即自动作废，用户不用手动清缓存。
//   · 网络回包条数比本地缓存还少时不覆盖（残缺结果会冲掉好数据、还会把缓存写坏）。
// v2.9.12：
//   · 修「第三个监控的格子回放入口出现了又消失」。v2.9.5 的清残影判据只看入口的直接
//     父视图里有没有「云存储/AI分析」文字 —— 第三台那种型号入口容器和文字不在同一层，
//     于是被误判成残影删掉，下一 tick 又装回来，入口一直闪。现在改成往 cell 内整条链
//     找文字，并且必须连续 3 次 tick 都判无效才删，防滚动/复用瞬间抖动。
// v2.9.13：
//   · 格子页改成「边读边显示」：以前要等翻满 24 页才一次性上屏，用户盯着
//     「正在读取该日录像…」等几十秒。现在每翻到一页就把这批格子推上去（最新的在最上面），
//     后台继续往早补，先看到最近这段时间，再慢慢补到当天最早的一条。
// v2.9.14：
//   · 治「每补一页闪一下」的三个源头：
//     ① 重建时滚动位置被重置 → 保存并恢复 contentOffset，原来在底部等数据的继续贴底；
//     ② 正在拖 / 惯性滑动时不重建，攒到松手再一次性刷新；
//     ③ 同一张封面图只发一个下载请求（否则每次重建都重复请求，图在占位与图片之间跳）；
//     ④ 收工那次如果条数没变就跳过重建。
// v2.9.15：
//   · 导航栏去掉「正在加载」横幅，只留「回放」并真正居中（之前容器宽度把那个 alpha=0
//     的「正在加载」也算进去，字实际偏左）。
//   · 封面下载限 3 并发 + 失败自动重试 2 次（1s、2s）。第二台那个设备首屏一次要拉十几张图，
//     全部同时打出去会被服务端吞掉一部分 —— 官方消息列表里就是「最上面那 9 条没封面，
//     往下拉滑走再滑回来就有了」（cell 复用等于重拉一次）。
//   · 进页面后 1.2s/3s/6s/12s 各补一次「还没图」的可见格子（不重建列表、不闪），
//     兜住「抓拍地址晚一点才填到消息对象上」这一种情况。
// v2.9.16：
//   · 历史日期（不是今天）已经有缓存就直接收工，不再从头翻一遍网络 —— 之前是「缓存上屏之后
//     照样翻 24 页」，所以会出现「13 号秒显示、却一直在加载」。今天仍然会刷新（可能还有新报警）。
//   · 缓存按天自动清理，只留最近 30 天（每天一个 plist，一条只存「秒 + 封面地址」，占用很小）。
// v2.9.17：
//   · 同一天整体替换前继承旧条目已有的封面 —— 网络新数据对某些设备抓拍地址是空的，
//     直接覆盖会让已经显示出来的封面先消失再慢慢回来（读第四台时看到的那种闪）。
//   · 封面失败重试放到 4 次（2s/4s/8s/16s），补封面的时间点延到 20s、35s。
//   · 入口残影清理改为「先隐藏、连续 12 次才真删」—— 从别的格子页返回时第三台那个 cell
//     有几拍扫不到文字，以前删掉就不再重装，表现是「进去过一次，回来入口就没了」。
// v2.9.18：
//   · 入口去重不能只挪坐标：cell 复用后旧入口挂在了别人家的容器里，新位置因为「已存在」
//     跳过安装，旧入口又被清掉 —— 这就是「主界面看着没事，一滑动第三个就没了」。
//     改成把同身份旧入口迁到当前这一行的容器里。
//   · 封面分三种状态显示：无封面（没地址）/ 载入中…（有地址还没下完）/ 加载失败（下载失败）。
//     这样一眼就能判断是「取不到地址」还是「地址不对/下载不通」。
//   · 收工后若这一天还有「没地址」的格子，静默再请求一次最新页，把新对象里的封面补上
//     （那台设备的抓拍地址要第二次请求才回来）。
// v2.9.19：
//   · 封面下载并发 3 → 6，失败重试 4 次 16s → 3 次 6s，另加 8 秒兜底。
//     上一版最长要 30 秒才收工，这段时间整页格子都挂「载入中」，看着像卡死。
// v2.9.20：
//   · 过了 0 点当天还没报警时，只留「日期抬头 + 当日还没有任何报警消息」。
//     底部那句「当日已全部加载完毕」改成「有格子才加」，不再和空天说明自相矛盾。
//   · 进格子页先藏掉官方播放器残留的「回放倍数选择」浮层（它正好压在日期抬头上面），
//     离开页面再放回去，官方播放页照常可用。
//   · 日期抬头量宽改成「先按不换行量，再夹到可用宽度」—— 窄宽下不会只剩一个字。
// v2.9.21：
//   · 封面候选禁止是视频。键表里 event_file_url 排在第二位，第二台设备没有
//     eventPicThumbUrl，就一路被 event_file_url（录像地址 mp4/ts）当成封面下载，
//     UIImage 解不出来 —— 现象正是「载入中很久 → 加载失败」，而别的设备都正常。
//     视频类字段挪到末尾，统一过「不许是视频」的过滤。
//   · 失败时格子上带后缀：「失败.mp4」= 拿到的是录像；「失败.jpg」= 地址对但下载被拒。
// v2.9.22：
//   · 过 0 点当天没报警时，页面上会多出一个「无封面 / 00:00:00」的假格子 —— 时间字段一个
//     都解析不出来时 JAGridSecForMessage 兜底成了当天 0 点整。现在 sec <= 当天 0 点的直接丢。
//   · 「回放倍数选择」浮层带模态遮罩，一旦显示回来就把格子页的触摸全吃掉（连返回都点不了，
//     只能退后台）。改成格子页前台期间每 0.6s 压一次，扫描范围扩到所有 window，且不再恢复。
// v2.9.23：
//   · 光藏横条不够 —— 横条外面那层全屏遮罩还挂着：屏幕顶上留一条白边（状态栏那块看不见），
//     触摸照样全被吃掉，连手势返回都失效。现在往上找到「满屏宽」的那层容器，整块移除。
//   · 按天缓存换目录（JAGridDays4）：旧缓存里存着「时间兜底成 0 点」的假格子，读缓存
//     会照样显示出来（过 0 点当天没报警时页面上多一个「无封面 00:00:00」）。
//   · 封面请求补 User-Agent / Accept / Referer，超时 12 秒 —— 第二台那张 jpg 地址是对的，
//     裸请求被 CDN 判成非 App 流量直接拒（格子上一直「失败.jpg」）。
//   · 失败文字优先显示 HTTP 状态码（失败 403 / 失败 404），跟「失败.jpg」（没拿到响应）分开。
//   · 同一张图连续失败 3 次后不再自动重试，避免 20s/35s 补图时反复「载入中 → 失败」闪。
// v2.9.24：
//   · 遮挡不再靠「找文字」猜。每 0.6s 对每个 window 做一次 hitTest，命中的那个视图就是
//     真正吃掉手势的东西：它是满屏的、又不是格子页自己的后代，就整块摘掉。
//     摘不掉的把类名写在底部提示条上（「遮挡:XXX(320x568)」），截图即可定位是谁。
//   · 缓存读取也拦一道 sec <= 当天 0 点 的条目，老版本写进去的假格子读不出来。
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
// v2.9.9：报警时间的「双源校正」—— 用列表上直接显示的 HH:mm:ss 反推秒，跟 eid/时间戳
// 解析出来的比对，偏差大就以显示时间为准（第二台就是 eid 解析结果和显示时间对不上）。
static long long JAGridDayFromMessage(id msg);
static long long JAGridSecForMessage(id msg, long long day);
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
        // v2.9.9：这个秒如果和消息列表上显示的时间不一致，官方「查看录像」也会定错位
        // （第二台的情况：定位了不播、又回到实时）。统一走双源校正。
        long long d0 = JAGridDayFromMessage(warn);
        if (d0 <= 0) d0 = JADayStartSec(ts);
        long long fixed = JAGridSecForMessage(warn, d0);
        if (fixed > 0) {
            JASet(vc, @"currentTimeStamp", @(fixed));
            g_rtcTargetSec = fixed;
        } else {
            if (ts) JASet(vc, @"currentTimeStamp", ts);
            long long tv0 = ts ? ts.longLongValue : 0;
            if (tv0 >= 1000000000LL && tv0 < 10000000000LL) g_rtcTargetSec = tv0;
        }
        // 预设设备 SD 选中日期 = 报警日 0 点秒 —— RTC setupData（0x100af6104）会
        // 读 myCamera.sdSelectiontDay → 加载该日事件列表
        if (d0 > 0 && cam) {
            JASet(cam, @"sdSelectiontDay", @(d0));
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

// v2.9.21：这个地址是不是「视频」。key 表里 event_file_url 排在很前面，第二台设备没有
// eventPicThumbUrl 字段，就一路落到 event_file_url（录像地址）当封面用 —— 下载回来是
// mp4/ts，UIImage 解不出来，格子上就一直「载入中」然后「加载失败」。
// 这是「别的设备都正常、只有第二台没图」最可能的病因。
static BOOL JAGridLooksLikeVideo(NSString *u) {
    if (![u isKindOfClass:NSString.class]) return NO;
    NSString *low = u.lowercaseString;
    if ([low containsString:@".mp4"] || [low containsString:@".m3u8"] ||
        [low containsString:@".m4v"] || [low containsString:@".ts"] ||
        [low containsString:@".avi"] || [low containsString:@".mov"] ||
        [low containsString:@".mkv"] || [low containsString:@".flv"] ||
        [low containsString:@".h264"] || [low containsString:@".mpg"]) return YES;
    return NO;
}

static BOOL JAGridLooksLikeImage(NSString *u) {
    if (![u isKindOfClass:NSString.class] || u.length < 8) return NO;
    if (JAGridLooksLikeVideo(u)) return NO;
    NSString *low = u.lowercaseString;
    if ([low containsString:@".jpg"] || [low containsString:@".jpeg"] ||
        [low containsString:@".png"] || [low containsString:@".webp"] ||
        [low containsString:@".bmp"] || [low containsString:@"pic"] ||
        [low containsString:@"thumb"] || [low containsString:@"snap"] ||
        [low containsString:@"image"] || [low containsString:@"cover"] ||
        [low containsString:@"img"]) return YES;
    return NO;
}

// v2.9.21：封面候选过滤 —— 视频地址直接丢掉，别当封面下载
static NSString *JAGridPickImage(NSString *u) {
    if (!u) return nil;
    if (JAGridLooksLikeVideo(u)) return nil;
    return u;
}


// v2.6：封面地址归一化（补协议 / 丢弃无法解析的相对路径）
static NSString *JAGridNormalizeURL(NSString *u) {
    if (![u isKindOfClass:NSString.class]) return nil;
    if (u.length < 9) return nil;
    if ([u hasPrefix:@"http://"] || [u hasPrefix:@"https://"]) return u;
    if ([u hasPrefix:@"//"]) return [@"https:" stringByAppendingString:u];
    if ([u hasPrefix:@"file://"]) return u;
    return nil;
}

// v2.9.9：在任意对象里递归找图片地址 —— 有的型号把抓拍图塞在 eventData（字典或 JSON
// 字符串）里，不在任何顶层字段上，逐字段扫永远扫不到。
static NSString *JAGridFindURLIn(id obj, int depth) {
    if (!obj || depth < 0) return nil;
    if ([obj isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)obj;
        if (s.length < 8 || s.length > 4096) return nil;
        if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) {
            NSString *low = s.lowercaseString;
            if ([low containsString:@".jpg"] || [low containsString:@".jpeg"] ||
                [low containsString:@".png"] || [low containsString:@".webp"] ||
                [low containsString:@"pic"] || [low containsString:@"thumb"] ||
                [low containsString:@"snap"] || [low containsString:@"image"] ||
                [low containsString:@"cover"]) return s;
            return nil;
        }
        NSString *t = [s stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 2 && ([t hasPrefix:@"{"] || [t hasPrefix:@"["])) {
            NSData *d = [t dataUsingEncoding:NSUTF8StringEncoding];
            id j = nil;
            @try { j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; }
            @catch (NSException *e) { j = nil; }
            if (j) return JAGridFindURLIn(j, depth - 1);
        }
        return nil;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id k in (NSDictionary *)obj) {
            NSString *r = JAGridFindURLIn([(NSDictionary *)obj objectForKey:k], depth - 1);
            if (r) return r;
        }
        return nil;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        for (id v in (NSArray *)obj) {
            NSString *r = JAGridFindURLIn(v, depth - 1);
            if (r) return r;
        }
        return nil;
    }
    return nil;
}

static NSString *JAGridImageURL(id ev) {
    // v2.8：消息模型（JAEMWarnInfoEntityModel）的抓拍图就是消息列表里那张缩略图，
    // 键名 eventPicThumbUrl 优先；其次 event_file_url（原图/大图）。
    id thumb = JAVal(ev, @"eventPicThumbUrl");
    if ([thumb isKindOfClass:NSString.class]) {
        NSString *u = JAGridPickImage(JAGridNormalizeURL((NSString *)thumb));
        if (u) return u;
    }
    // v2.6：键名扩到常见的封面/抓拍字段（不同设备的报警模型字段不一样）
    NSArray *keys = @[@"eventPicUrl", @"event_pic_url", @"event_pic", @"picUrl",
                      @"pic_url", @"event_img", @"imageUrl", @"snapUrl", @"eventImagePath",
                      @"coverUrl", @"thumbUrl", @"imgUrl",
                      @"pic", @"cover", @"coverImg", @"coverPic", @"coverPicUrl",
                      @"videoCoverUrl", @"eventCoverUrl", @"eventCover", @"snapshotUrl",
                      @"snapPic", @"snapPicUrl", @"thumb", @"image", @"eventImage",
                      @"eventImageUrl", @"img", @"picPath", @"imagePath", @"localCoverPath",
                      @"event_file_url", @"recordFileUrl", @"record_file_url",
                      @"fileUrl", @"file_url"];
    // v2.9.21：视频类字段挪到最后，并且统一过一道「不许是视频」的过滤 ——
    // 之前的顺序让 event_file_url 抢了第二台设备的封面，下载 mp4 必然解不出图。
    for (NSString *k in keys) {
        NSString *u = JAGridPickImage(JAGridNormalizeURL(JAVal(ev, k)));
        if (u) return u;
    }
    // v2.9.5：字段名兜底 —— 不同型号 / 不同云通道（Jooan / 阿里云存量）的报警模型字段
    // 名是另一套，上面那张固定键表覆盖不到（第二台设备就整页「无封面」）。这里直接把
    // 对象所有 ivar 扫一遍：先挑绝对地址里像图片的，再把相对路径用同对象的 http 地址
    // 补成绝对地址。
    unsigned int ic = 0;
    Ivar *ivs = class_copyIvarList([ev class], &ic);
    NSMutableArray *absUrls = [NSMutableArray array];
    NSMutableArray *relUrls = [NSMutableArray array];
    for (unsigned int i = 0; i < ic; i++) {
        const char *nm = ivar_getName(ivs[i]);
        if (!nm) continue;
        NSString *raw = [NSString stringWithUTF8String:nm];
        NSString *key = [raw hasPrefix:@"_"] ? [raw substringFromIndex:1] : raw;
        id v = nil;
        // v2.9.7：这里只能走 KVC。v2.9.5 还挂了一条 object_getIvar 兜底，但它会把
        // int / long long / BOOL 这类标量 ivar 的数值直接当 id 交出去，ARC 一 retain 就
        // SIGSEGV（objc_retain @ JAGridImageURL，第二台设备点格子播放、RTC 定位找事件时必崩）。
        // KVC 会按 ivar 类型装箱：标量变 NSNumber，对象才是对象，安全。
        @try { v = [ev valueForKey:key]; } @catch (NSException *e) { v = nil; }
        if (![v isKindOfClass:NSString.class]) {
            // v2.9.9：嵌套结构（字典 / 数组 / JSON 字符串）里也可能藏着抓拍图
            NSString *deep = JAGridFindURLIn(v, 2);
            if (deep) { if (ivs) free(ivs); return deep; }
            continue;
        }
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length < 8 || s.length > 2048) continue;
        if ([s hasPrefix:@"http://"] || [s hasPrefix:@"https://"]) [absUrls addObject:s];
        else if ([s hasPrefix:@"/"]) [relUrls addObject:s];
    }
    if (ivs) free(ivs);

    for (NSString *u in absUrls) {
        if (JAGridLooksLikeImage(u)) return u;
    }
    // v2.9.21：没有明确像图片的，退一步取第一个「不是视频」的地址
    for (NSString *u in absUrls) {
        if (!JAGridLooksLikeVideo(u)) return u;
    }
    // 相对路径：借同对象里第一个 http 地址的 scheme+host 拼成绝对地址
    NSString *origin = nil;
    for (NSString *u in absUrls) {
        NSRange r = [u rangeOfString:@"://"];
        if (r.location == NSNotFound) continue;
        NSRange tail = NSMakeRange(r.location + 3, u.length - r.location - 3);
        NSUInteger slash = [u rangeOfString:@"/" options:0 range:tail].location;
        origin = (slash == NSNotFound) ? u : [u substringToIndex:slash];
        break;
    }
    if (origin.length) {
        for (NSString *rel in relUrls) {
            NSString *full = [origin stringByAppendingString:rel];
            if (JAGridLooksLikeImage(full)) return full;
        }
        for (NSString *rel in relUrls) {
            NSString *full = [origin stringByAppendingString:rel];
            if (!JAGridLooksLikeVideo(full)) return full;
        }
    }

    // v2.9.7：再兜一层 —— 有些型号的图地址是 getter 现场拼出来的（域名 + id，不落在任何
    // ivar 上），光扫字段永远取不到，而消息列表里照样有图。这里枚举模型自己的 0 参方法，
    // 只在名字像取图的里面取返回值，其余方法一律不碰。
    // 只对「像事件 / 消息模型」的类做，避免对随便一个对象触发带副作用的 getter。
    NSString *clsName = NSStringFromClass([ev class]);
    BOOL looksEvent = ([clsName containsString:@"Warn"] || [clsName containsString:@"Event"] ||
                       [clsName containsString:@"Record"] || [clsName containsString:@"Entity"] ||
                       [clsName containsString:@"Msg"]);
    if (!looksEvent) return nil;
    unsigned int mc = 0;
    Method *ms = class_copyMethodList([ev class], &mc);
    NSString *hit = nil;
    for (unsigned int i = 0; i < mc && !hit; i++) {
        if (method_getNumberOfArguments(ms[i]) != 2) continue;      // self + _cmd，纯取值
        const char *enc = method_getTypeEncoding(ms[i]);
        if (!enc || enc[0] != '@') continue;                       // 返回类型必须是对象
        NSString *sn = NSStringFromSelector(method_getName(ms[i]));
        NSString *low = sn.lowercaseString;
        if (!([low containsString:@"url"] || [low containsString:@"pic"] ||
              [low containsString:@"thumb"] || [low containsString:@"image"] ||
              [low containsString:@"cover"] || [low containsString:@"snap"])) continue;
        id r = nil;
        @try { r = ((id (*)(id, SEL))objc_msgSend)(ev, method_getName(ms[i])); }
        @catch (NSException *e) { r = nil; }
        if (![r isKindOfClass:NSString.class]) continue;
        hit = JAGridNormalizeURL((NSString *)r);
    }
    if (ms) free(ms);
    if (hit) return hit;
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

static NSString *JAGridDeviceName(id cam) {
    for (NSString *k in @[@"name", @"deviceName", @"devName", @"nickName", @"remark"]) {
        id v = JAVal(cam, k);
        if ([v isKindOfClass:NSString.class] && [(NSString *)v length]) return (NSString *)v;
    }
    return @"";
}

// v2.9.9：从消息对象里取报警日的 0 点秒（event_date 最可靠，没有就退回时间戳推算）
static long long JAGridDayFromMessage(id msg) {
    if (!msg) return -1;
    for (NSString *k in @[@"event_date", @"eventDate", @"day", @"dateStr", @"eventDateStr",
                          @"date", @"showDate"]) {
        id v = JAVal(msg, k);
        if (![v isKindOfClass:NSString.class]) continue;
        NSString *s = (NSString *)v;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"(\\d{4})-(\\d{1,2})-(\\d{1,2})" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (!m || m.numberOfRanges < 4) continue;
        NSInteger y = [[s substringWithRange:[m rangeAtIndex:1]] integerValue];
        NSInteger mo = [[s substringWithRange:[m rangeAtIndex:2]] integerValue];
        NSInteger da = [[s substringWithRange:[m rangeAtIndex:3]] integerValue];
        if (y < 2000 || mo < 1 || mo > 12 || da < 1 || da > 31) continue;
        NSDateComponents *c = [[NSDateComponents alloc] init];
        c.year = y; c.month = mo; c.day = da;
        NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
        NSDate *d = [cal dateFromComponents:c];
        if (d) return (long long)[d timeIntervalSince1970];
    }
    return -1;
}

// 消息列表上直接显示的时刻（timeLabelStr 等，形如 23:46:05）→ 当天秒
static long long JAGridSecFromLabel(id msg, long long day) {
    if (day <= 0) return -1;
    for (NSString *k in @[@"timeLabelStr", @"showMessage", @"eventDesc", @"message", @"timeStr"]) {
        id v = JAVal(msg, k);
        if (![v isKindOfClass:NSString.class]) continue;
        NSString *s = (NSString *)v;
        if (s.length < 5) continue;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"(\\d{1,2}):(\\d{2}):(\\d{2})" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
        if (!m || m.numberOfRanges < 4) continue;
        NSInteger h = [[s substringWithRange:[m rangeAtIndex:1]] integerValue];
        NSInteger mi = [[s substringWithRange:[m rangeAtIndex:2]] integerValue];
        NSInteger se = [[s substringWithRange:[m rangeAtIndex:3]] integerValue];
        if (h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 59) continue;
        return day + (long long)h * 3600 + (long long)mi * 60 + (long long)se;
    }
    return -1;
}

// 双源校正：eid/时间戳解析 vs 列表显示时间。两个都在当天且相差 ≤5 分钟就用解析值，
// 否则用显示时间 —— 显示时间是用户眼睛看到的那条，必须一致。
static long long JAGridSecForMessage(id msg, long long day) {
    if (!msg) return -1;
    long long a = -1;
    NSNumber *ts = JABuildTimestamp(msg);
    if (ts) a = ts.longLongValue;
    long long b = JAGridSecFromLabel(msg, day);
    BOOL aOk = (a >= day && a < day + 86400LL);
    BOOL bOk = (b >= day && b < day + 86400LL);
    if (day <= 0) return (a > 0) ? a : b;
    if (aOk && bOk) {
        long long d = (a > b) ? (a - b) : (b - a);
        return (d <= 300) ? a : b;
    }
    if (bOk) return b;
    if (aOk) return a;
    return -1;
}

// 一条报警消息 → 格子 entry（sec 用 v2.9.9 的双源校正）
static NSDictionary *JAGridEntryFromMessage(id msg, long long day) {
    if (!msg) return nil;
    long long sec = JAGridSecForMessage(msg, day);
    if (sec < day || sec >= day + 86400LL) return nil;     // 只收本天
    // v2.9.22：正好落在「当天 0 点整」的一律丢掉 —— 时间字段一个都解析不出来时，
    // JAGridSecForMessage 会兜底成当天 0 点，于是 0 点整多出一个「无封面 00:00:00」的假格子
    // （过 0 点当天没报警时最明显：明明一条消息都没有，页面上却有一个空格子）。
    if (sec <= day) return nil;
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

// 官方消息模型是异步网络拉取：warnMessageList 会分段变长，翻页靠
// -loadMoreWarningMessagesWithDay:。历次教训：
//   v2.9.3 只翻 8 页 → 消息多的设备读不到最后几条；
//   v2.9.6 把「稳定」判定放松到 1 次 → 撞进官方还在请求的窗口，翻页请求被吞 → 提前收工；
//   v2.9.8 改成「先看 _isLoading，忙就等」→ 有的设备这个值一直是 YES，于是永远不翻页，
//          只剩首屏，正是第一台「只显示 18:00 之后」。
// v2.9.10 不再看 _isLoading，只按结果自适应：每轮 1.5s（首屏 2.4s），翻一页就看长度
//   有没有变；没变就把同一页重试（最多 3 次），变了继续；成功翻满 24 页收工；
//   首屏 6s 还一条没有才当空天。
// v2.9.13：每翻到一页就立刻回调 prog 上屏（不再等全部翻完才一次性显示）——
//   首屏那页一到，最近这段时间的格子就先出来，后面的页在后台继续往早补。
//   用户看到的「正在读取该日录像…」因此只存在最前面那一两秒。
static void JAGridPollMessageModel(id model, long long day, NSInteger round,
                                   NSArray *best, NSInteger bestN, NSInteger okPages,
                                   NSInteger retry,
                                   void (^prog)(NSArray *items),
                                   void (^cb)(NSArray *items)) {
    if (round > 150) { if (cb) cb(bestN > 0 ? best : nil); return; }
    NSTimeInterval wait = (round == 0) ? 2.0 : 1.4;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray *list = nil;
        @try { list = [model valueForKey:@"warnMessageList"]; } @catch (NSException *e) {}
        NSArray *items = JAGridEntriesFromMessages(list, day);
        NSInteger n = items ? (NSInteger)items.count : 0;
        NSArray *cand = best;
        NSInteger bn = bestN;
        if (n > bn) {
            cand = items;
            bn = n;
            if (prog) prog(cand);       // 有新增就先把这批推上去
        }
        SEL lm = NSSelectorFromString(@"loadMoreWarningMessagesWithDay:");
        BOOL canMore = [model respondsToSelector:lm];

        if (round == 0) {
            // 首屏：数据还没到就再等等（最多 4 次 ≈ 6s），别把「慢」当成「当天没报警」
            if (bn == 0 && retry < 4) {
                JAGridPollMessageModel(model, day, round + 1, cand, bn, 0, retry + 1, prog, cb);
                return;
            }
            if (!canMore || okPages >= 24) { if (cb) cb(cand); return; }
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(model, lm, JAGridDayStr(day));
            } @catch (NSException *e) { if (cb) cb(cand); return; }
            JAGridPollMessageModel(model, day, round + 1, cand, bn, 0, 0, prog, cb);
            return;
        }

        // 上一轮已经发过翻页，这里看它有没有效果
        if (n > bestN) {
            if (okPages + 1 >= 24 || !canMore) { if (cb) cb(cand); return; }
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(model, lm, JAGridDayStr(day));
            } @catch (NSException *e) { if (cb) cb(cand); return; }
            JAGridPollMessageModel(model, day, round + 1, cand, bn, okPages + 1, 0, prog, cb);
            return;
        }
        // 一条没多：可能被官方自己的在途请求吞了，重试同一页（最多 3 次）
        if (retry < 3 && canMore) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(model, lm, JAGridDayStr(day));
            } @catch (NSException *e) { if (cb) cb(cand); return; }
            JAGridPollMessageModel(model, day, round + 1, cand, bn, okPages, retry + 1, prog, cb);
            return;
        }
        if (cb) cb(cand);
    });
}

// 拉「某设备某天」的报警消息；prog 每翻到一页就回调一次（先上屏），cb(nil) 表示这条通道
// 走不通（调用方回退官方 SD 段）
static void JAGridFetchMessageDay(id cam, long long day,                                  void (^prog)(NSArray *items),
                                  void (^cb)(NSArray *items)) {
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

    JAGridPollMessageModel(model, day, 0, nil, 0, 0, 0, prog, ^(NSArray *items) {
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
        JAGridPollMessageModel(model, day, 0, nil, 0, 0, 0, prog, cb);
    });
}

// v2.9.18：只请求「最新那一页」，不翻页。
// 第二台那个设备首屏返回的消息里抓拍地址是空的，官方消息列表也要滑一下（等于再请求一次）才出图。
// 这里在收工之后静默地再请求一次，用新对象里的封面地址补给还没有图的格子。
static void JAGridFetchFirstPage(id cam, long long day, void (^cb)(NSArray *items)) {
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
    if (![model respondsToSelector:f1]) { if (cb) cb(nil); return; }
    BOOL sent = NO;
    @try {
        ((void (*)(id, SEL, id, int, id, id))objc_msgSend)(model, f1, ds, 0, devId, dn);
        sent = YES;
    } @catch (NSException *e) { sent = NO; }
    if (!sent) { if (cb) cb(nil); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSArray *list = nil;
        @try { list = [model valueForKey:@"warnMessageList"]; } @catch (NSException *e) {}
        if (cb) cb(JAGridEntriesFromMessages(list, day));
    });
}

// ---------- v2.8：按天磁盘缓存（第二次进格子页秒开） ----------

// v2.9.11：目录名带版本号（JAGridDays3）。v2.9.9 改了报警时间的算法（双源校正），
// v2.9.23：换成 JAGridDays4 —— 之前写进缓存的条目里有「时间解析兜底成当天 0 点」的假格子，
// 读缓存会照样把它显示出来（过 0 点当天没报警时页面上多一个「无封面 00:00:00」）。
// 换目录一次性作废旧缓存，不用用户手动清。
// 之前缓存的秒是旧规则算出来的，直接复用会让格子定位到错误的时刻、看起来像「读不全」。
// 换目录 = 旧缓存自动作废，不用用户手动清。
static NSString *JAGridDayCacheDir(NSString *devKey) {
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                            NSUserDomainMask, YES) firstObject];
    if (!caches.length || !devKey.length) return nil;
    NSString *dir = [[caches stringByAppendingPathComponent:@"JAGridDays4"]
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
        // v2.9.24：缓存里也拦一道 —— 老版本写进去过「时间兜底成当天 0 点」的假条目，
        // 读出来照样会在 00:00 组里显示一个「无封面 00:00:00」的空格子。
        if (sec.longLongValue < day + 1 || sec.longLongValue >= day + 86400LL) continue;
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

// v2.9.16：缓存按天自动清理 —— 只留最近 30 天。占用很小：每天一个 plist，每条消息只存
// 「秒 + 封面地址」，一天 200 条约 30KB，30 天也就 1MB 左右，留着不影响什么。
static void JAGridDayCachePrune(NSString *devKey, NSInteger keepDays) {
    NSString *dir = JAGridDayCacheDir(devKey);
    if (!dir.length) return;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    long long cutoff = JAGridTodayStart() - (long long)keepDays * 86400;
    for (NSString *n in files) {
        if (![[n pathExtension] isEqualToString:@"plist"]) continue;
        long long day = [[n stringByDeletingPathExtension] longLongValue];
        if (day > 0 && day < cutoff) {
            [[NSFileManager defaultManager]
                removeItemAtPath:[dir stringByAppendingPathComponent:n] error:nil];
        }
    }
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
@property (nonatomic, strong) NSMutableDictionary *inflight;   // v2.9.14：同 URL 去重
@property (nonatomic, strong) NSMutableDictionary *fails;      // v2.9.23：同一 URL 连续失败次数
@property (nonatomic, strong) NSMutableDictionary *codes;      // v2.9.23：失败时的 HTTP 状态码
@property (nonatomic, strong) NSMutableArray *queue;           // v2.9.15：限并发排队
@property (nonatomic, assign) NSInteger active;                // 当前在跑的下载数
+ (instancetype)shared;
- (UIImage *)imageForKey:(NSString *)key;
- (void)loadURL:(NSString *)url completion:(void (^)(UIImage *img, NSString *key))cb;
- (NSInteger)statusForURL:(NSString *)url;   // v2.9.23：失败时的 HTTP 状态码，0 = 没拿到响应
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
        _inflight = [NSMutableDictionary dictionary];
        _fails = [NSMutableDictionary dictionary];
        _codes = [NSMutableDictionary dictionary];
        _queue = [NSMutableArray array];
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
- (NSInteger)statusForURL:(NSString *)url {
    if (!url.length) return 0;
    return [[self.codes objectForKey:url] integerValue];
}
- (void)loadURL:(NSString *)url completion:(void (^)(UIImage *, NSString *))cb {
    if (!url.length || ![url hasPrefix:@"http"]) { if (cb) cb(nil, url); return; }
    UIImage *c = [self imageForKey:url];
    if (c) { if (cb) cb(c, url); return; }
    // v2.9.14：同一个 URL 只发一个请求。边读边显示会一层层重建 cell，不去重就会对同一张图
    // 反复发请求，图片在「占位 → 加载出来」之间来回跳，看起来就是闪。
    // v2.9.23：连续失败已经够多次的就不再自动重试 —— 否则 20s/35s 那几轮补图会一轮轮
    // 重新下载同一张失败图，格子上「载入中 → 失败」反复闪。
    if ([[self.fails objectForKey:url] integerValue] >= 3) { if (cb) cb(nil, url); return; }
    NSMutableArray *wait = (NSMutableArray *)self.inflight[url];
    if (wait) {
        if (cb) [wait addObject:[cb copy]];
        return;
    }
    wait = [NSMutableArray array];
    if (cb) [wait addObject:[cb copy]];
    self.inflight[url] = wait;
    [self jaStart:url];
}

// v2.9.15：限制并发。第二台那个设备首屏一次要拉十几张图，一起打出去服务端会吞掉一部分 ——
// 官方消息列表里表现为「最上面那 9 条没封面，往下拉滑走再滑回来就有了」（cell 复用等于重拉一次）。
// v2.9.19：上限从 3 提到 6 —— 限 3 时首屏 9 个格子要排三批，看着全是「载入中」；
// 同时加了 8 秒兜底，任何一个请求不回调也会被收掉，不会把队列堵死。
- (void)jaStart:(NSString *)url {
    if (self.active >= 6) { [self.queue addObject:url]; return; }
    self.active += 1;
    [self jaFetch:url retry:0];
    __weak typeof(self) ws = self;
    NSString *key = [url copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) s = ws;
        if (s && s.inflight[key]) [s jaFinish:key image:nil];
    });
}

- (void)jaFinish:(NSString *)url image:(UIImage *)img {
    if (!self.inflight[url]) return;      // v2.9.19：幂等 —— 兜底已经收过就别重复扣并发
    if (self.active > 0) self.active -= 1;
    if (img) [self.fails removeObjectForKey:url];
    else {
        NSInteger n = [[self.fails objectForKey:url] integerValue] + 1;
        self.fails[url] = @(n);
    }
    NSArray *ws = [self.inflight[url] copy];
    [self.inflight removeObjectForKey:url];
    for (void (^b)(UIImage *, NSString *) in ws) { if (b) b(img, url); }
    if (self.queue.count > 0) {
        NSString *next = (NSString *)self.queue.firstObject;
        [self.queue removeObjectAtIndex:0];
        [self jaStart:next];
    }
}

- (void)jaFetch:(NSString *)url retry:(NSInteger)retry {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { [self jaFinish:url image:nil]; return; }
    // v2.9.23：带上 App 的 User-Agent 跟常规图片请求头。第二台设备那张抓拍图 jpg 地址是对的，
    // 但裸 session 请求图片 CDN 会被判成非 App 流量直接拒（格子上一直是「失败.jpg」）。
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:u];
    [rq setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Joolink/4.79"
        forHTTPHeaderField:@"User-Agent"];
    [rq setValue:@"image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];
    [rq setValue:@"https://www.jooancloud.com/" forHTTPHeaderField:@"Referer"];
    rq.timeoutInterval = 12.0;
    NSURLSessionDataTask *t = [[NSURLSession sharedSession]
        dataTaskWithRequest:rq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            UIImage *img = nil;
            if (data) { @autoreleasepool { img = [UIImage imageWithData:data]; } }
            if (!img && [resp isKindOfClass:NSHTTPURLResponse.class]) {
                // v2.9.23：记下 HTTP 状态码，格子上的失败文字能区分 403/404/超时
                NSInteger st = ((NSHTTPURLResponse *)resp).statusCode;
                if (st > 0) self.codes[url] = @(st);
            }
            if (img) {
                [self.mem setObject:img forKey:url];
                [self.codes removeObjectForKey:url];
                NSString *dp = JAGridDiskPathForKey(url);
                if (dp.length) [data writeToFile:dp atomically:YES];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (img || retry >= 3) { [self jaFinish:url image:img]; return; }
                // v2.9.19：重试 3 次（1.5s、3s、6s）。上一版给到 4 次 16s，最长要 30 秒才收工，
                // 这段时间格子上一直挂着「载入中」，看起来像整页卡住。
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)((1.5 * (double)(1 << retry)) * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self jaFetch:url retry:retry + 1];
                });
            });
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
@property (nonatomic, strong) NSDictionary *entryRef;   // v2.9.15：延迟补封面用
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
        self.noneLab.text = @"无封面";     // v2.9.18：区分「没地址」和「有地址没下下来」
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
    self.noneLab.text = @"载入中…";        // v2.9.18：有地址但图还没到，和「无封面」分开显示
    self.noneLab.hidden = NO;
    __weak typeof(self) ws = self;
    NSString *key = [url copy];
    [[JAGridImageCache shared] loadURL:url completion:^(UIImage *img, NSString *k) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        if (!key || ![s.imgURL isEqualToString:key]) return;
        if (img) { s.thumb.image = img; s.noneLab.hidden = YES; }
        else {
            // v2.9.21：把后缀带出来 —— 显示「失败.mp4」就说明拿到的根本不是图。
            // v2.9.23：有 HTTP 状态码时优先显示码 —— 「失败 403」是被拒，「失败 404」是地址错，
            // 「失败.jpg」是压根没拿到响应（超时/断网）。三者修法完全不同。
            NSInteger st = [[JAGridImageCache shared] statusForURL:key];
            if (st >= 400) s.noneLab.text = [NSString stringWithFormat:@"失败 %ld", (long)st];
            else {
                NSString *ext = [[NSURL URLWithString:key] pathExtension].lowercaseString;
                s.noneLab.text = ext.length ? [NSString stringWithFormat:@"失败.%@", ext]
                                            : @"加载失败";
            }
            s.noneLab.hidden = NO;
        }
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
- (void)configNote:(NSString *)note;   // v2.9.6：一行居中灰字说明（空天 / 列表末尾）
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
    self.hourLab.font = [UIFont systemFontOfSize:16];
    self.hourLab.textColor = [UIColor colorWithRed:0.13 green:0.55 blue:0.95 alpha:1.0];
    self.hourLab.textAlignment = NSTextAlignmentLeft;     // cell 复用要复位
    [self setNeedsLayout];
}

// v2.9.6：一行居中灰字 —— 该日没报警 / 当日已全部加载完毕
- (void)configNote:(NSString *)note {
    self.dayLab.text = nil;
    self.dayLab.hidden = YES;
    self.dashLine.hidden = YES;
    self.clockView.hidden = YES;
    self.hourLab.text = note;
    self.hourLab.font = [UIFont systemFontOfSize:13];
    self.hourLab.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.hourLab.textAlignment = NSTextAlignmentCenter;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    BOOL hasDay = !self.dayLab.hidden;
    CGFloat y = 2;
    if (hasDay) {
        // v2.9.20：先按不换行量一次真实宽度，再夹到可用宽度里 —— 窄宽下直接
        // sizeThatFits(w-70) 会把「2026年11月15日」压成只剩一个字。
        CGSize sz = [self.dayLab sizeThatFits:CGSizeMake(CGFLOAT_MAX, 28)];
        sz.width = MIN(sz.width, MAX(0, w - 70));
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

// v2.9.20：过 0 点再进格子页时，官方播放器留在 window 上的「回放倍数选择」浮层还挂着，
// 正好盖住日期抬头，而且它是模态的 —— 遮罩吃掉所有触摸，连左上角返回都点不了。
// v2.9.22：改成「格子页在前台期间持续压住它」：每次都重扫（官方后台可能又把它显示回来）。
// v2.9.23：光隐藏横条不够 —— 横条外面那层全屏遮罩还在，屏幕顶上会出现一条白边（状态栏那块），
// 触摸照样全被吃掉、手势返回也失效。所以往上找到「宽度接近满屏」的那层遮罩容器，
// 整块 removeFromSuperview，横条和遮罩一起走。格子页自己的 view 绝不碰。
static __weak UIView *g_jaGridHostView = nil;

// v2.9.24：不再靠「找文字」猜遮挡层 —— 直接问系统：在这个点上谁最先接到触摸。
// window 对自己做 hitTest，命中的那个视图就是真正吃掉手势的东西。
// 它不是格子页自己的后代、又是满屏的，那就整块摘掉。
// 返回 @{@"cls":类名, @"frame":CGRect值, @"w":宽, @"h":高} 或 nil。
static NSDictionary *JAGridProbeHit(UIWindow *win, UIView *host, CGPoint pt) {
    if (!win || win.hidden || win.alpha < 0.02) return nil;
    if (win.bounds.size.width < 2 || win.bounds.size.height < 2) return nil;
    UIView *hit = nil;
    @try { hit = [win hitTest:pt withEvent:nil]; } @catch (NSException *e) { hit = nil; }
    if (!hit || [hit isKindOfClass:UIWindow.class]) return nil;
    if (host && [hit isDescendantOfView:host]) return nil;      // 命中自己，正常
    // 命中「格子页的祖先」（导航栏/容器）说明那点本来就没被格子页覆盖，不算遮挡
    if (host) {
        UIView *anc = host.superview;
        while (anc) {
            if (anc == hit) return nil;
            anc = anc.superview;
        }
    }
    return @{@"cls": NSStringFromClass(hit.class),
             @"frame": [NSValue valueWithCGRect:hit.frame],
             @"w": @(CGRectGetWidth(hit.frame)),
             @"h": @(CGRectGetHeight(hit.frame)),
             @"v": hit};
}

static void JAGridToggleSpeedPanel(BOOL hide) {
    if (!hide) return;                 // 不再恢复：留着它只会再遮一次
    UIView *host = g_jaGridHostView;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *win in wins) {
        NSMutableArray *os = [NSMutableArray arrayWithObject:win];
        int budget = 6000;
        while (os.count > 0 && budget-- > 0) {
            UIView *v = (UIView *)os.lastObject;
            [os removeLastObject];
            if ([v isKindOfClass:UILabel.class]) {
                UILabel *l = (UILabel *)v;
                if (l.text.length && [l.text containsString:@"回放倍数"]) {
                    // 往上找「满屏宽」的那层容器（模态遮罩），没有就退回到 window 直接子视图
                    UIView *target = nil;
                    UIView *cur = l.superview;
                    CGFloat ww = win.bounds.size.width;
                    while (cur && cur != win) {
                        if (ww > 0 && CGRectGetWidth(cur.bounds) >= ww * 0.9) target = cur;
                        cur = cur.superview;
                    }
                    if (!target) {
                        UIView *r = l;
                        while (r.superview && r.superview != win) r = r.superview;
                        if (r.superview == win) target = r;
                    }
                    if (target && host && [target isDescendantOfView:host]) target = nil;  // 不碰自己
                    if (target) [target removeFromSuperview];
                    continue;
                }
            }
            for (UIView *s in v.subviews) [os addObject:s];
        }
    }
}

@interface JAGridReplayViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) id myCamera;
@property (nonatomic, strong) NSMutableArray *days;    // 按天原始数据 @[@{@"day":NSNumber, @"items":NSArray}]（新→旧）
@property (nonatomic, strong) NSMutableArray *secs;    // v2.7：展示用「小时组」，见 rebuildLayout
@property (nonatomic, strong) NSMutableArray *flat;    // 与 secs 顺序完全一致，连播/翻页索引用
@property (nonatomic, strong) UICollectionView *cv;
@property (nonatomic, strong) UILabel *hintLab;
@property (nonatomic, strong) NSMutableArray *retained; // 借用中的官方 dataVC（保活）
@property (nonatomic, assign) long long nextDay;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL pendingRefresh;   // v2.9.14：滚动中攒下来的刷新
@property (nonatomic, assign) BOOL coverRefetch;      // v2.9.18：正在静默补一次最新页
@property (nonatomic, assign) NSInteger emptyStreak;
@property (nonatomic, assign) BOOL gaveUp;
@property (nonatomic, strong) NSTimer *speedTimer;   // v2.9.22：前台期间持续压住官方倍数浮层
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

// v2.9.15：去掉「正在加载」横幅，标题只剩「回放」，并且真正居中 ——
// 之前 titleView 容器宽度把那个 alpha=0 的「正在加载」也算进去了，「回放」实际偏左。
- (void)buildTitleView {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
    t.text = @"回放";
    t.font = [UIFont boldSystemFontOfSize:17];
    t.textColor = [UIColor blackColor];
    t.textAlignment = NSTextAlignmentCenter;
    [t sizeToFit];

    CGFloat h = 32.0;
    CGFloat wt = CGRectGetWidth(t.frame);
    CGFloat w = wt + 12.0;      // 容器只包住这两个字，左右各留 6pt；容器整体在导航栏居中
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    t.frame = CGRectMake((w - wt) / 2.0, (h - CGRectGetHeight(t.frame)) / 2.0,
                         wt, CGRectGetHeight(t.frame));
    [box addSubview:t];
    self.navigationItem.titleView = box;
}

// v2.9.15：横幅已去掉，保留空实现，原来的调用点不用动
- (void)setLoadingBadge:(BOOL)on {
    (void)on;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"回放";
    self.days = [NSMutableArray array];
    self.secs = [NSMutableArray array];
    self.flat = [NSMutableArray array];
    self.retained = [NSMutableArray array];
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
    // v2.9.6：右上角只留日期选择器（「连播 开」按钮去掉，连播本身仍是默认开启）
    self.navigationItem.rightBarButtonItem = self.calItem;
    [self buildTitleView];

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // v2.9.20：先藏掉官方播放器残留的「回放倍数选择」浮层，它正好压在日期抬头上面，
    // 而且带模态遮罩，会把返回按钮也一起挡掉。
    g_jaGridHostView = self.view;
    JAGridToggleSpeedPanel(YES);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.speedTimer invalidate];
    self.speedTimer = nil;
}

// v2.9.24：用 hitTest 直接找出「谁在吃触摸」。满屏的整块摘掉，剩下的把类名写到
// 底部提示条上 —— 用户一截图就能看到究竟是谁盖的，不用再猜。
- (void)jaProbeBlockers {
    UIView *host = self.view;
    if (!host) return;
    NSMutableString *rep = [NSMutableString string];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        CGPoint p = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
        NSDictionary *d = JAGridProbeHit(w, host, p);
        if (!d) continue;
        UIView *v = (UIView *)d[@"v"];
        CGFloat ww = CGRectGetWidth(w.bounds), hh = CGRectGetHeight(w.bounds);
        CGFloat fw = [d[@"w"] doubleValue], fh = [d[@"h"] doubleValue];
        [rep appendFormat:@"%@(%.0fx%.0f) ", d[@"cls"], fw, fh];
        if (ww > 0 && hh > 0 && fw >= ww * 0.9 && fh >= hh * 0.6) {
            @try { [v removeFromSuperview]; } @catch (NSException *e) {}
        }
    }
    if (rep.length) {
        self.hintLab.hidden = NO;
        self.hintLab.text = [NSString stringWithFormat:@"遮挡:%@", rep];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // v2.9.22：官方播放页在后台可能又把「回放倍数选择」浮层显示回来（它带模态遮罩，
    // 一出来就把整个格子页的触摸吃掉，返回都点不了）。前台期间每 0.6s 压一次。
    if (!self.speedTimer) {
        __weak JAGridReplayViewController *wsv = self;
        self.speedTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES
                                                            block:^(NSTimer *t) {
            __strong JAGridReplayViewController *sv = wsv;
            if (!sv) { [t invalidate]; return; }
            JAGridToggleSpeedPanel(YES);
            [sv jaProbeBlockers];
        }];
    }
    if (!self.myCamera) {
        self.hintLab.hidden = NO;
        self.hintLab.text = @"没拿到设备对象（myCamera 为空），格子页无法读取录像";
        return;
    }
    long long today = JAGridTodayStart();
    // v2.9.16：进页面顺手清一次 30 天以前的老缓存
    if (self.cacheKey.length) JAGridDayCachePrune(self.cacheKey, 30);
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

    // v2.9.15：分几个时间点补一次「还没有封面」的格子。第二台设备的抓拍图在首屏那一刻
    // 可能还没填到消息对象上 —— 官方消息列表里那几条也是滑动之后才出图的。这里只补图，
    // 不重建列表，所以不会闪。
    __weak typeof(self) wself = self;
    for (NSNumber *d in @[@1.2, @3.0, @6.0, @12.0, @20.0, @35.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(wself) s = wself;
            if (s) [s refreshMissingCovers];
        });
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
    [self setLoadingBadge:YES];

    // ① 有缓存就直接上屏（第二次进页面 = 秒开）
    NSArray *cached = JAGridDayCacheRead(self.cacheKey, day);
    BOOL cacheHit = NO;
    if (cached.count && ![self hasDay:day]) {
        [self appendDay:day items:cached];
        [self.knownDays addObject:@(day)];
        self.hintLab.hidden = YES;
        cacheHit = YES;
    } else if (!cached.count && self.days.count == 0) {
        self.hintLab.hidden = NO;
        self.hintLab.text = @"正在读取该日录像…";
    }

    // v2.9.16：历史日期已经有完整缓存 —— 那天早就读完了，不用再从头翻一遍网络。
    // 之前是「缓存上屏之后照样翻 24 页」，所以会看到「13 号秒显示、却一直在加载」。
    // 只有「今天」需要再拉一次，因为可能还有新的报警消息。
    if (cacheHit && day != JAGridTodayStart()) {
        [self onDayLoaded:day items:cached];
        return;
    }

    __weak typeof(self) ws = self;
    // ② 直连官方消息模型（v2.8 那层，v2.9.3 补上翻页直到没有更多）
    // 不再复用「消息列表」页实例：用户刚在那页滑过时，那页正在跑自己的请求，
    // 我们改它的日期/清它的数组会把它的状态打乱，它的网络回调就崩
    // （.ips 里 MYAFNetworkingKit 回调 → 官方代码 → forwarding 就是这条）。
    // v2.9.13：每翻到一页先把这批格子推上屏（最新的在最上面），后台再继续往早补，
    // 不用盯着「正在读取该日录像…」等几十秒才出东西。
    JAGridFetchMessageDay(self.myCamera, day,
                          ^(NSArray *partial) {
        __strong typeof(ws) s0 = ws;
        if (!s0 || partial.count == 0) return;
        [s0.knownDays addObject:@(day)];
        [s0 appendDay:day items:partial];
        s0.hintLab.hidden = YES;
    },
                          ^(NSArray *items) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        if (items.count > 0) { [s onDayLoaded:day items:items]; return; }
        // ③ 最后回退官方 SD 段（v2.7 原链路，保证不比之前差）
        [s fetchDaySD:day completion:^(NSArray *events) {
            __strong typeof(ws) s2 = ws;
            if (!s2) return;
            [s2 onDayLoaded:day items:JAGridEntriesFromEvents(events, day)];
        }];
    });
}

- (void)onDayLoaded:(long long)day items:(NSArray *)items {
    self.loading = NO;
    [self setLoadingBadge:NO];
    // v2.9.4：只展示「当前这一天」，不再自动往前翻（官方消息列表也只能看当天，
    // 前一天要点日期选择器）。这里不再把 nextDay 减一天。
    self.nextDay = day;
    long long today = JAGridTodayStart();
    if (items.count > 0) {
        self.emptyStreak = 0;
        [self.knownDays addObject:@(day)];
        // v2.9.11：网络这次回的条数比本地缓存还少 —— 多半是这一轮翻页没翻全（请求被官方
        // 在途请求吞掉）。别拿残缺结果把已经拿到的好数据冲掉，连缓存一起写坏。
        NSArray *cachedNow = self.cacheKey.length ? JAGridDayCacheRead(self.cacheKey, day) : nil;
        if (cachedNow.count > items.count) {
            [self appendDay:day items:cachedNow];
            self.hintLab.hidden = YES;
            return;
        }
        // v2.9.14：进度回调已经把同一批数据上屏了，收工这一次条数没变就别再重建 ——
        // 再重建一次就是用户说的「读取完毕时闪一下」。
        NSInteger shown = 0;
        for (NSDictionary *d in self.days) {
            if ([(NSNumber *)d[@"day"] longLongValue] == day) {
                shown = (NSInteger)[(NSArray *)d[@"items"] count];
                break;
            }
        }
        if (shown > 0 && shown == (NSInteger)items.count) {
            self.hintLab.hidden = YES;
            if (self.cacheKey.length) JAGridDayCacheWrite(self.cacheKey, day, items);
            [self refetchCoversForDay:day];
            return;
        }
        [self appendDay:day items:items];
        if (self.cacheKey.length) JAGridDayCacheWrite(self.cacheKey, day, items);
        self.hintLab.hidden = YES;
        [self refetchCoversForDay:day];
        return;
    }
    // 网络这次没回，但缓存里已经有这天 → 保留缓存内容，不算“没录像”
    if ([self hasDay:day]) {
        self.emptyStreak = 0;
        self.hintLab.hidden = YES;
        return;
    }
    // 这一天确实没有读到报警消息（含「刚过 0 点今天还没有」）：给日期抬头 + 一句说明，
    // 不再连读三天、也不再弹「往前 3 天都没录像」。
    self.emptyStreak = 0;
    self.gaveUp = NO;
    [self appendDay:day
               items:@[]
                note:(day >= today
                      ? @"当日还没有任何报警消息 · 点右上角日期可查看其他日期"
                      : @"该日没有读到报警消息 · 点右上角日期可查看其他日期")];
    self.hintLab.hidden = YES;
}

// v2.9.17：同一天整体替换前，把旧条目里已经拿到的封面继承过来。
// 某些设备网络刚回来的消息对象抓拍地址是空的（官方列表也要滑一下才出图），
// 直接拿新数组覆盖会让本来有图的格子先变回「无封面」，过一会才补上 ——
// 用户看到的就是「读取完闪一下、封面没了，等十几秒又出来」。
- (NSArray *)mergeCovers:(NSArray *)items forDay:(long long)day {
    if (!items.count) return items;
    NSArray *oldItems = nil;
    for (NSDictionary *d in self.days) {
        if ([(NSNumber *)d[@"day"] longLongValue] == day) {
            oldItems = (NSArray *)d[@"items"];
            break;
        }
    }
    if (!oldItems.count) return items;
    NSMutableDictionary *oldBySec = [NSMutableDictionary dictionary];
    for (NSDictionary *e in oldItems) {
        NSNumber *sec = e[@"sec"];
        if (![sec isKindOfClass:NSNumber.class]) continue;
        if ([e[@"imgObj"] isKindOfClass:UIImage.class] || [(NSString *)e[@"img"] length]) {
            oldBySec[sec] = e;
        }
    }
    if (!oldBySec.count) return items;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *e in items) {
        NSNumber *sec = e[@"sec"];
        NSDictionary *old = [sec isKindOfClass:NSNumber.class] ? oldBySec[sec] : nil;
        BOOL newHasCover = ([e[@"imgObj"] isKindOfClass:UIImage.class] ||
                            [(NSString *)e[@"img"] length]);
        if (old && !newHasCover) {
            NSMutableDictionary *m = [e mutableCopy];
            if ([old[@"imgObj"] isKindOfClass:UIImage.class]) m[@"imgObj"] = old[@"imgObj"];
            NSString *oi = old[@"img"];
            if ([oi isKindOfClass:NSString.class] && oi.length) m[@"img"] = oi;
            [out addObject:m];
        } else {
            [out addObject:e];
        }
    }
    return out;
}

- (void)appendDay:(long long)day items:(NSArray *)items {
    [self appendDay:day items:items note:nil];
}

- (void)appendDay:(long long)day items:(NSArray *)items note:(NSString *)note {
    // v2.8.1：空天也允许入组 —— 只为了显示「2026年11月14日 + 当日还没有任何报警消息」
    // 这样一个抬头，不下发任何格子
    if (items.count == 0 && note.length == 0) return;
    // v2.9.17：替换前先继承旧封面，避免「刷新完封面先消失再回来」
    NSArray *covers = [self mergeCovers:items forDay:day];
    NSDictionary *bucket = @{@"day": @(day),
                             @"items": (covers ?: @[]),
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
    // v2.9.4：一天一屏 —— 列表底部固定一行提示（等同官方消息列表的「没有更多消息」）。
    // 想看前一天就点右上角日期选择器，不再滚到底自动往前翻。
    // v2.9.20：只有真的有格子时才加这一行 —— 空天（过了 0 点今天还没报警）只留
    // 「日期抬头 + 当日还没有任何报警消息」，不再多一句「已全部加载完毕」自相矛盾。
    if (flat.count > 0) {
        [secs addObject:@{@"day": @(0), @"hour": @(-2),
                          @"dayTitle": @"", @"hourTitle": @"",
                          @"items": @[],
                          @"note": @"当日已全部加载完毕，选择日期重新加载"}];
    }
    self.secs = secs;
    self.flat = flat;
    // v2.9.14：正在拖 / 惯性滑动时不重建 —— 否则每页都刷新一次，会打断滑动、位置被拉回，
    // 看起来就是「闪一下」。先攒着，等手停下再一次性刷。
    UICollectionView *cv = self.cv;
    if (!cv) return;
    if (cv.isDragging || cv.isDecelerating || cv.isTracking) {
        self.pendingRefresh = YES;
        return;
    }
    [self applyLayoutKeepingOffset];
}

// v2.9.14：重建表格但保住滚动位置 —— 原来停在底部的继续贴底（数据在末尾增长），
// 否则原位不动。避免「位置被弹回去」造成的闪烁。
- (void)applyLayoutKeepingOffset {
    UICollectionView *cv = self.cv;
    if (!cv) return;
    self.pendingRefresh = NO;
    CGPoint off = cv.contentOffset;
    CGFloat insetTop = cv.adjustedContentInset.top;
    CGFloat insetBottom = cv.adjustedContentInset.bottom;
    CGFloat oldH = cv.contentSize.height;
    BOOL atBottom = (oldH > 0 &&
                     off.y + cv.bounds.size.height - insetBottom >= oldH - 8.0);
    [cv reloadData];
    [cv layoutIfNeeded];
    CGFloat newH = cv.contentSize.height;
    CGFloat minY = -insetTop;
    CGFloat maxY = newH - cv.bounds.size.height + insetBottom;
    if (maxY < minY) maxY = minY;
    CGFloat y = atBottom ? maxY : MIN(MAX(off.y, minY), maxY);
    if (fabs(y - off.y) > 0.5) cv.contentOffset = CGPointMake(off.x, y);
}

// v2.9.18：这一天的条目里还有「完全没有封面地址」的就返回 YES
- (BOOL)dayHasCoverless:(long long)day {
    for (NSDictionary *d in self.days) {
        if ([(NSNumber *)d[@"day"] longLongValue] != day) continue;
        for (NSDictionary *e in (NSArray *)d[@"items"]) {
            if ([e[@"imgObj"] isKindOfClass:UIImage.class]) continue;
            if ([(NSString *)e[@"img"] length]) continue;
            return YES;
        }
        break;
    }
    return NO;
}

// v2.9.18：再请求一次「最新那一页」，把新对象里的封面地址补到已有条目上（只补不重建，不闪）
- (void)refetchCoversForDay:(long long)day {
    if (self.coverRefetch || day <= 0 || !self.myCamera) return;
    if (![self dayHasCoverless:day]) return;
    self.coverRefetch = YES;
    __weak typeof(self) ws = self;
    JAGridFetchFirstPage(self.myCamera, day, ^(NSArray *items) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        s.coverRefetch = NO;
        if (items.count) [s applyCovers:items day:day];
    });
}

// 把 items 里「有封面」的那些按秒号补到已有条目（只补没有图/没有地址的）。
// 补完刷新一次可见 cell —— 不重建列表。
- (void)applyCovers:(NSArray *)items day:(long long)day {
    NSMutableDictionary *bySec = [NSMutableDictionary dictionaryWithCapacity:items.count];
    for (NSDictionary *e in items) {
        NSNumber *sec = e[@"sec"];
        if (![sec isKindOfClass:NSNumber.class]) continue;
        if ([e[@"imgObj"] isKindOfClass:UIImage.class] || [(NSString *)e[@"img"] length]) {
            bySec[sec] = e;
        }
    }
    if (!bySec.count) return;
    for (NSDictionary *d in self.days) {
        if ([(NSNumber *)d[@"day"] longLongValue] != day) continue;
        for (NSDictionary *e in (NSArray *)d[@"items"]) {
            NSNumber *sec = e[@"sec"];
            NSDictionary *src = [sec isKindOfClass:NSNumber.class] ? bySec[sec] : nil;
            if (!src || ![e isKindOfClass:NSMutableDictionary.class]) continue;
            NSMutableDictionary *m = (NSMutableDictionary *)e;
            if ([m[@"imgObj"] isKindOfClass:UIImage.class]) continue;
            if ([src[@"imgObj"] isKindOfClass:UIImage.class]) m[@"imgObj"] = src[@"imgObj"];
            NSString *u = src[@"img"];
            if ([u isKindOfClass:NSString.class] && u.length) m[@"img"] = u;
        }
        break;
    }
    [self refreshMissingCovers];
}

// v2.9.15：只给「还没有图」的可见格子补一次封面 —— 重新从消息对象取地址。
// 第二台设备首屏那几条的抓拍地址要晚一点才填上（官方消息列表里也是滑动之后才出图，
// 我们这边不靠滑动，直接定时补）。只补图不重建列表，所以不闪。
- (void)refreshMissingCovers {
    UICollectionView *cv = self.cv;
    if (!cv) return;
    for (JAGridCell *c in cv.visibleCells) {
        if (![c isKindOfClass:JAGridCell.class]) continue;
        if (c.thumb.image) continue;
        NSDictionary *e = c.entryRef;
        if (!e) continue;
        NSString *u = nil;
        id raw = e[@"img"];
        if ([raw isKindOfClass:NSString.class]) u = (NSString *)raw;
        if (!u.length) u = JAGridImageURL(e[@"ev"]);
        if (!u.length) continue;
        if ([e isKindOfClass:NSMutableDictionary.class]) {
            [(NSMutableDictionary *)e setObject:u forKey:@"img"];
        }
        [c setImageURL:u];
    }
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
            c.entryRef = e;
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
            NSString *dayTitle = (NSString *)secDict[@"dayTitle"];
            if (dayTitle.length > 0) {
                // 空天 —— 保留日期抬头，说明跟在抬头下面（左对齐）
                [h configDayTitle:dayTitle hourTitle:note];
                h.clockView.hidden = YES;
                h.hourLab.font = [UIFont systemFontOfSize:13];
                h.hourLab.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
                h.hourLab.textAlignment = NSTextAlignmentLeft;
            } else {
                // v2.9.6：列表末尾提示 —— 整行居中
                [h configNote:note];
            }
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

// v2.9.4：不再滚到底自动读前一天 —— 一天一屏，换天走右上角日期选择器。
// （旧实现滚到底就 loadOneMoreDay，于是「14 号读到一半突然变成 13 号」。）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
}

// v2.9.14：手停下来就把滚动期间攒下的刷新补上（边读边显示时数据在持续增长）
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate && self.pendingRefresh) [self applyLayoutKeepingOffset];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (self.pendingRefresh) [self applyLayoutKeepingOffset];
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

    // v2.9.8：官方 SD 回放页自带的时间轴/拖动条不再隐藏（用户要能自己拖）。
    // v2.8：画面右上角标出这一格的目标时间 —— 定位有没有生效靠这个角标和画面对照
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

    // v2.9.9：自动连播（35 秒自动跳下一格）已按用户要求去掉 —— 拖动条回来了，
    // 播放完全由用户自己控制。
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
// v2.9.5：入口 box 上挂的两个身份 —— camera 本身、以及该卡片的设备身份键。
static char kJAGridEntryCamKey = 0;
static char kJAGridEntryIdKey = 0;

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
// v2.9.5：收集窗口里全部入口 box（不限坐标），用于按设备身份去重 / 清残影
static void JAGridCollectAllEntries(UIView *root, NSMutableArray *out, int depth) {
    if (!root || depth > 10) return;
    for (UIView *s in root.subviews) {
        if (s.tag == JAGridEntryTag) {
            [out addObject:s];      // 入口内部只有 icon/lab，不必再往下钻
        } else {
            JAGridCollectAllEntries(s, out, depth + 1);
        }
    }
}

static char kJAGridEntryMissKey = 0;

// v2.9.12：入口是否还挂在正确的位置 —— 从它往上找，扫到 cell / 列表边界为止，
// 这一路任何一层子树里还有「云存储 / AI分析」就算有效。
// 旧判据（v2.9.5）只扫直接父视图：第三台那种型号，入口容器和文字不在同一个直接父层，
// 一扫不到就判残影删掉，下一 tick 又装回来 → 入口「出现了又消失」，只有它这样。
static BOOL JAGridEntryStillValid(UIView *b) {
    UIView *v = b.superview;
    int depth = 0;
    while (v && depth < 8) {
        NSMutableArray *txt = [NSMutableArray array];
        NSInteger budget = 240;
        JAGridCollectTexts(v, 0, txt, &budget);
        for (UIView *t in txt) {
            NSString *s = JAGridViewText(t);
            if (JAGridIsCloudText(s) || JAGridIsAIText(s)) return YES;
        }
        if ([v isKindOfClass:NSClassFromString(@"UITableViewCell")] ||
            [v isKindOfClass:NSClassFromString(@"UICollectionViewCell")] ||
            [v isKindOfClass:UITableView.class] ||
            [v isKindOfClass:UICollectionView.class]) break;
        v = v.superview;
        depth++;
    }
    return NO;
}

// v2.9.5：清残影 —— cell 复用会让旧入口留在已不复用的那一层容器里，从此叠在卡片上。
// v2.9.12：判定改为「往 cell 内整条链找文字」，并且必须连续 3 次 tick 都判无效才删
// （滚动 / 复用瞬间会短暂扫不到，一次就删就是闪烁）。
static void JAGridSweepStaleEntries(void) {
    UIWindow *win = nil;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (UIWindow *w in wins) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win && wins.count) win = [wins lastObject];
    if (!win) return;
    NSMutableArray *boxes = [NSMutableArray array];
    JAGridCollectAllEntries(win, boxes, 0);
    if (boxes.count == 0) return;
    NSMutableArray *del = [NSMutableArray array];
    for (UIView *b in boxes) {
        // 真的脱离窗口了（cell 被回收）→ 立刻清
        if (!b.superview || !b.window) { [del addObject:b]; continue; }
        if (JAGridEntryStillValid(b)) {
            objc_setAssociatedObject(b, &kJAGridEntryMissKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (b.hidden) b.hidden = NO;    // v2.9.17：误判过就先恢复显示
            continue;
        }
        NSInteger m = [objc_getAssociatedObject(b, &kJAGridEntryMissKey) integerValue] + 1;
        objc_setAssociatedObject(b, &kJAGridEntryMissKey, @(m),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // v2.9.17：从别的格子页返回时，第三台那个 cell 有几拍扫不到文字，
        // 以前 3 次就直接删掉，删掉之后一直不再重装 —— 用户看到「进去过一次，回来就没了」。
        // 现在先只隐藏（层级还留着，位置也不会跑），连续 12 次（≈4s）仍然无效才真删，
        // 交给下一 tick 重新安装。
        if (m >= 12) [del addObject:b];
        else if (m >= 3) b.hidden = YES;
    }
    for (UIView *d in del) [d removeFromSuperview];
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

    // v2.9.5：入口身份 = 这张卡片的设备（uid 优先，其次设备名）。同身份全局只留一个，
    // 并把 camera 直接挂在入口上 —— 这两个就是「一张卡片叠两个格子回放」和
    // 「返回后再点提示没找到设备」的根因：旧实现按屏幕坐标 ±14pt 判重，cell 一复用
    // 坐标就变，旧入口留在旧容器里没人管；点击时又去现场解析视图层级，解析不到就报错。
    id cam = JAGridCameraForView(cloud);
    if (!cam) cam = JAGridCameraByNameNear(host);
    NSString *eid = nil;
    if (cam) {
        NSString *u = JAGridDeviceId(cam);
        eid = u.length ? u : JAGridDeviceName(cam);
    }
    if (!eid.length) {
        eid = [NSString stringWithFormat:@"pos_%.0f_%.0f",
               (CGRectGetMidX(rc) + CGRectGetMidX(ra)) / 2.0, midY];
    }

    NSMutableArray *allBoxes = [NSMutableArray array];
    JAGridCollectAllEntries(cloud.window, allBoxes, 0);
    UIView *keep = nil;
    for (UIView *b in allBoxes) {
        NSString *bid = objc_getAssociatedObject(b, &kJAGridEntryIdKey);
        if (![bid isKindOfClass:NSString.class] || ![bid isEqualToString:eid]) continue;
        if (!keep) keep = b;
        else [b removeFromSuperview];      // 同一设备的多层叠影，删掉多余的
    }
    if (keep) {
        // v2.9.18：同设备已有入口时，不能只挪坐标。列表滚动会让 cell 复用，旧入口此时挂在
        // 一个已经装了别的设备的容器里 —— 用户看到的现象正是「主界面不动，一滑动第三个就没了」：
        // 旧入口被当残影清掉，新位置又因为「已存在」跳过了安装。
        // 这里改成「迁到当前这一行的容器里」，位置一起纠正。
        if (keep.superview != host) {
            [keep removeFromSuperview];
            [host addSubview:keep];
            objc_setAssociatedObject(keep, &kJAGridEntryMissKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            keep.hidden = NO;
        }
        CGRect f = keep.frame;
        f.origin = CGPointMake(midX - f.size.width / 2.0, midY - f.size.height / 2.0);
        keep.frame = f;
        if (cam) objc_setAssociatedObject(keep, &kJAGridEntryCamKey, cam,
                                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    // 这张卡片所在容器里解析不到设备身份的旧入口一律清掉，保证一卡一口
    JAGridPurgeEntriesUnder(host, 0);

    CGFloat h = MAX(36.0, MAX(CGRectGetHeight(rc), CGRectGetHeight(ra)) + 10.0);
    CGFloat w = 104.0;
    CGFloat hostW = CGRectGetWidth(host.bounds);
    if (hostW > 0 && w > hostW * 0.40) w = hostW * 0.40;

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(midX - w / 2.0, midY - h / 2.0, w, h)];
    box.tag = JAGridEntryTag;
    objc_setAssociatedObject(box, &kJAGridEntryIdKey, eid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (cam) objc_setAssociatedObject(box, &kJAGridEntryCamKey, cam,
                                      OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    // v2.9.5：每次扫描先清掉挂错层的旧入口（cell 复用留下的叠影）
    @try { JAGridSweepStaleEntries(); } @catch (NSException *e) {}
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
    // v2.9.5：优先用安装入口时就存好的 camera —— 旧实现每次点击都去现场解析视图层级，
    // 从回放页返回后层级已变，解析不到就弹「没找到这台设备」（第三台就是这样）。
    id cam = objc_getAssociatedObject(box, &kJAGridEntryCamKey);
    if (!cam) cam = JAGridCameraForView(box);
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
