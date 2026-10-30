# 定序二交付 — goroutine 服务模型 + 斜率三段修复

基点 `e19f058`；盒上 integ 工具链（sci `e7c18568` / sla `47ec56a` 线）构建与验收，
仓根 cwd + `SA_PLUGIN_DEV=1` + `SA_STD_DIR` + `SLA_NO_FRESHNESS_CACHE=1` +
`SA_SLA_FIXTURE_DIR` 规范口径。判读一律四联：rc=0 + 预期结果行 + 失败名字集为空。

## 1. 设计（src/main.sla serve 节）

单 dispatcher（主任务）独占 slot 表（64 槽）、自由栈与 access-log sink：

- dispatcher 在自己的循环里以短轮询（`ACCEPT_POLL_MS = 5`）调用
  `sa_http_server_accept_v2` 接请求；每代先非阻塞排空 completions 队列
  （select/default 形），回收永远跑在新 accept 之前。
- 每请求由 dispatcher 直接 `go supervised conn_worker(job)` spawn
  worker；worker 跑顺序版 `handle_request` 处理恰好一个请求，把
  (slot idx, 分发序号) 打包送 completions chan，并释放自己的 job Box。
- dispatcher 在回收槽时 `sa_task_join` 该任务句柄并读回 trap 记录
  （`join_slot_task`）：写日志行、trap 强度核算、释放请求句柄、槽归还。
- **看门狗**：被 trap 的 worker 不会发 completion（defer 在 trap 时不
  执行，探针 probe_h7t2 实证），dispatcher 以 ~1 Hz 节律扫描在途槽；
  超龄槽（常规 1,800 s；槽耗尽时 300 s——std fetch 上限 180 s，超龄即
  陷阱/楔死/极端慢读者）就地 join 并按同一 trap 路径回收；回收前先
  bump 槽序号，使该 worker 万一已排队的 completion 变为陈旧件被
  `book_recycle` 丢弃，杜绝双重回收。
- trap 策略：单 worker trap 不杀进程——槽以已记录 outcome 完成
  （status 未置则合成 500），照常记日志/释放；`TRAP_LIMIT = 32` 次 /
  `TRAP_WINDOW_S = 60` s 超限 → 返回 3、进程响亮退出。

### 三个实测运行时行为塑造了本设计（全部有探针/诊断证据）

1. **非主任务驱动的 spawn+join 有 ~300k 累计天花板**。首版形态
   （每连接一只 supervisor goroutine，内含 spawn+join）在 bench 累计
   ~28 万请求后进程死亡：`PANIC: code=60901` + `reached unreachable
   code`。判别探针：supervisor 内 supervised spawn+join（probe_h5）与
   普通 spawn+join（probe_h6）同在 295–315k 周期死亡；同一循环由主
   任务驱动（probe_h7）705,000 周期全过。故监督的 spawn/join 全部收
   回主任务，supervisor goroutine 取消——监督语义（supervised 边界、
   逐槽 trap 记录、强度上限）不变。此面已入 DEF 补充移交（补充三）。
2. **goroutine 的固定任务栈使循环型 goroutine 的棘轮死亡点远低于
   主栈**。acceptor 形态首版在 bench 数千次接受后 abort：
   `goroutine 4294967296 stack overflow (fixed stack, no growth in
   this phase)`（probe_i：acceptor 形循环死于 15–16k 迭代 ⇒ 固定栈
   ≈256 KiB）。且任务栈溢出是**进程 abort 而非可 trap 的任务失败**，
   监督对它无效。此面已入 DEF 补充移交（补充二）。
3. **accept 必须由消费方主循环泵动**。acceptor goroutine 喂
   reqs chan 的形态在持续负载下会整机停驻数秒（全线程 futex 停驻、
   零 CPU、请求不投递、客户端 15 s 超时成簇；独立墙钟见证排除盒子
   冻结；select 超时臂 5 s→50 ms、日志改投 tmpfs 均不改变停驻）；
   同一服务器改为 dispatcher 主任务 accept 后，120k 请求 **0 错误、
   ~4,000 rps** 持续跑通（python 诊断驱动口径）。std server 面的
   accept 显然要求由消费者自身循环驱动（顺序版正是如此）。此面
   登记为 std 面/运行时候选缺陷，候 DEF 线判（§8）。

### 代际轮换（栈棘轮应用层缓解）

dispatcher 是长寿命循环，按事件代际轮换：`GEN_EVENT_BUDGET = 20000`
个事件（分发+回收）后停分发、排空在途、返回 serve() 在新帧上开下一
代。依据：棘轮 ≈13–16 B/迭代（探针定案），按 128 B/event 最坏估
2.56 MB < 8 MiB 主栈的 1/3；排空成本 ≤64 在途请求、按 1 万请求摊
销。worker 每请求一只、无循环，不需轮换。耐力跑中主栈 VmStk 全程
恒定（§7）即轮换生效的直接证据。

### 与 PLAN 的偏差（逐项登记）

1. **无 `serve_model` 配置开关**：顺序 serve 路径整体退役（交付清单
   口径优先）；回滚 = git revert 本批。
2. **分发粒度是请求而非连接**：std 面交出的是请求句柄，监督的是
   一次请求处理；keep-alive 后续请求是新的 accept 事件。
3. **supervisor goroutine 取消**（见上行为 1）：PLAN 的「每连接
   supervisor goroutine」在当前工具链撞 ~300k 硬天花板、低于耐力
   门（52.3 万），形态被实测否决；监督语义等价保留（dispatcher 持
   句柄 join + trap_info + 强度核算，即 OTP 监督树的根监督者直管
   形态）。db 线 OTP 骨架落 std 后，此变体应映射其 child-spec
   （restart=off、监督者在根任务）。
4. **dispatcher 不调用 `Chan::len()`**：嵌套 while 条件内 len()
   （此前有 recv 时）会确定性挂死任务（复现存
   `~/workspace/sx-work/chan-len-hang/`），全部通道等待只用
   select 形；登记为编译器/运行时候选缺陷，本线只登记不修。

## 2. 斜率三段应用层修复（逐项落点）

| 段 | 基线归因 | 修复 | 落点 |
|---|---|---|---|
| Outcome 按值返回（~1,424 B 结构体） | ≈2,853 B/req | `handle_request(..., o: &Outcome)` 改 &out 参数、void 返回；`outcome_new` → `outcome_init(o)` 原地写字段 | src/main.sla |
| ResolvedPath 等按值结构体物化 | ≈5,778 B/req | `resolved`/`mime`/status `body` 改字面量局部原地初始化；`config_assets_root_into(&AssetsRoot)` 原地版（原函数转委托）；proxy 内 8 处 `tb_new()` → `TextBuf` 字面量局部、删 `tb_new` | src/main.sla、src/config.sla、src/proxy.sla |
| peer/ACL 的 String 临时量 | ≈6,277 B/req | 字节级 ACL：`ipv4_parse_bytes` 逐条镜像 sa_std `ipv4_parse` 接受语义（4 段、1–3 位、多位段不以 '0' 开头、≤255、全串消费）、`ipv6_text_valid` 镜像 `ipv6_parse`（段 1–4 hex、"::" 至多一次、压缩时总段 <8、无压缩 ==8、内嵌 v4 占 2 段）；`config_acl_allows_bytes(p, n)` 与 String 版决策等价（本地复审逐条对齐 + G1 的 ACL 单测走 String 版、G2 的 live 403 检查走字节版，两面同判）。String 版保留供单测 | src/config.sla |

## 3. 并发安全补口

- **upstream 游标**：`ProxyConfig.cursor_mutex`（src/upstream.sla）；
  `proxyconf_pool_pick` 在句柄非零时 lock/unlock 保护游标读改写
  （`sa_sync_mutex_*`，task.sai）。单测路径句柄为 0、走无锁原路径，
  G1 逐名不变。main() 启动时创建并装入。
- access-log sink 的组装缓冲只被 dispatcher 碰（回收时写行），
  worker 不写日志——F3 的单 write_all/行原子性保持。

## 4. 门禁结果（盒上实测，2026-10-30，定版二进制）

- 构建：`sa build-exe src/main.sla -o slanginx` rc=0，
  二进制 14,610,184 B。
- **G1 单测 25/25 逐名全过**：access_log 2 / config 4 / shared_dict 7 /
  upstream 4 / webpath 8，各文件 `test result: ok`、失败集 ∅。
- **G2 验收 49 PASS / 0 FAIL**：`scripts/acceptance.sh` rc=0，尾行
  `acceptance done: FAIL count = 0`（四跑：18090 出厂 / 18091 alt /
  18092 换根 / 18093 代理 + fixture 19001/19002）。
- 负载冒烟（定版）：python 诊断驱动（16 线程 keep-alive）
  **120,000 请求 0 错误、3,997 rps、access log 精确 120,000 行**、
  进程存活、VmStk 188 kB；另顺序 2,500 + 20 并发突发全 200、hello
  正文 sha256 逐字节一致、/internal 403、HEAD 200；畸形输入
  （垃圾请求行、60 KB 头）→ 连接被关/重置、进程存活且后续 200
  （std 面在分发前处置，未触发 worker trap；trap 路径由探针
  probe_d/probe_h7t3 的监督语义 + 代码路径成立）。

## 5. 斜率（盒上实测，分口径如实并列）

- 基线（顺序版）：≈15,100 B/req（三段成因，探针阶梯定案）。
- 定版脚本口径（server_rss_slope.py，单 keep-alive 连接、300 req/
  相，新鲜实例两轮）：冷相 9,352 → 预热后 **≈6,700 B/req**
  （hello 6,676 / big 6,717）。同口径 T1 形态三轮 13,653 → 10,800、
  acceptor 形态两轮 17,571 → 14,923——定版在同口径下亦最低。
- 定版长跑口径见 §7 耐力跑的 RSS 轨迹（600k 请求平均斜率）。
- 残余分解（探针 probe_h1/h3/h4）：每 spawn 的运行时保留
  ~4,231 B（detached/任务上下文保留面，已入 DEF 补充移交补充一）
  + HTTP 面在任务上下文中的每请求保留（余量 ~2.4k）。三段应用层
  成因已按构造消除；残余属 DEF 线运行时面，非应用代码可解。

## 6. Bench（bench.sh 同口径，对集成 G7 基线）

定版二进制全表（2026-10-30，盒上窗口负载 ~3.9–4.7，为三窗最噪；
rps，括号内为对同窗 nginx 的比值；G7 基线比值引集成批同窗数）：

| 格 | nginx | slanginx | 比值 | G7 基线比值 |
|---|---|---|---|---|
| small c1 | 20,162 | 759 | 3.8% | 26.3% |
| small c10 | 90,793 | 5,486 | 6.0% | 5.9% |
| small c50 | 118,190 | 5,266 | 4.5% | 4.4% |
| large c1 | 9,796 | 744 | 7.6% | 44.3% |
| large c10 | 35,790 | 5,080 | 14.2% | 15.3% |
| large c50 | 33,368 | 5,252 | 15.7% | 5.3% |
| proxy c1 | 1,062 | 385 | 36.3% | — |
| proxy c10 | 1,609 | 1,302 | 80.9% | — |
| proxy c50 | 1,600 | 655 | 40.9% | — |

- **c10/c50 静态格与 G7 基线同水平**（large c50 反超至 15.7%）：
  dispatcher 服务率上限 ~5.5k rps 未变（顺序版的串行化天花板
  ~5.6k 同量级），但已由「单线程直服」换成「调度+监督」结构，
  且不再有 52.3 万请求死亡线。
- **c1 格是明确弱面**：单连接延迟被 accept 轮询片量化 +
  每请求 spawn/join 链串行化（p50 1.29–2.52 ms），~760 rps
  封顶；ACCEPT_POLL_MS 5→1 已把该格从 186 抬到 ~760（4.1×），
  余量在 std 面 accept 的早返回语义与 spawn 链成本，非轮询
  可再榨。顺序版 c1 的高比值（26.3%/44.3%）来自其同步内联
  零交接成本，与 goroutine 形态的取舍点在此交代清楚。
- p99 长尾：本窗 small c50 193 ms、large c10 854 ms（多格
  120–930 ms 量级）；更静窗口（~1.2–2.8）下 T3 形态同格 p99
  仅 2.75 ms、本窗 c50 large 格 6.37 ms——长尾随窗口噪声出现、
  不与并发度单调相关，判为盒上争用/wrk 口径伪影为主，如实
  登记不粉饰；服务端侧的确定性停驻（acceptor 形态）已由 §7
  的 0 错误耐力排除。
- proxy c10 脚本判 PASS（两窗皆然）；bench.sh 的历史阈值总判
  仍 FAIL（阈值早于 G7 基线口径），逐格比值如上表即本线口径。
- fixture 天花板（proxy 场景信息行）：c1 24.40 rps。

## 7. 耐力（死亡关闭证明，定版二进制实测）

驱动 `docs/repro/endurance_drive.py`（16 线程 keep-alive、15 s
超时）：**600,000 请求、0 错误、152.3 s、3,939 rps ——
ENDURANCE_PASS**。

- 顺序版在默认 8 MiB 栈下的死亡点是 523,128 请求；本跑越过并
  到达 600,000，进程存活、收尾 GET 200。
- access log 600,001 行（600k 耐力 + 收尾 GET）：跨 ~60 个
  dispatcher 代际（600k×2 事件 / 20,000 预算），零回收丢失、
  零重复。
- 主栈 VmStk 全程有界：采样 132 kB 起、跑中 212 kB、收尾读数
  836 kB，无向 8 MiB 攀升的单调趋势——代际轮换生效的直接证据
  （对照：顺序版 VmStk 随请求数线性爬升至触限段错误）。
- 长跑 RSS：12,272 → 3,821,464 kB，**平均斜率 ≈6,502 B/req**，
  与 §5 脚本口径预热值（≈6,700）互洽。
- 对照实验（acceptor 形态同驱动）：325 个 15 s 超时（投递停驻
  面，§1 行为 3）——定版形态 0 错误，两形态差异即该面的开关
  对照。

## 8. DEF 移交件

`~/workspace/sx-work/stack-ratchet-handoff/`：
- 主件（栈棘轮）：probe_b.sla（盒上原件，sha256 `faff2f69…`）、
  sx-stk.py/sx-stk.sh（原件）、DATA.md（三点 ulimit 标定 + fault
  证据 + 对账表）、HANDOFF.md。
- 补充一（detached spawn 每只保留 ~4,231 B，probe_h1/h3/h4）。
- 补充二（goroutine 固定任务栈 ~256 KiB：循环型 goroutine 棘轮
  死亡点 15–16k 迭代；栈溢出 = 进程 abort 不可监督，probe_i）。
- 补充三（非主任务 spawn+join ~300k 累计天花板，probe_h5/h6/h7；
  附 defer-on-trap 不执行 probe_h7t2、主任务 join trap 回读
  probe_h7t3）。
- 补充四（**std server 面 accept 须由消费者主循环泵动**：
  acceptor goroutine 喂 chan 形态在持续负载下整机停驻 ~6–9 s；
  证据 = diag 系列：全线程 futex 停驻快照、墙钟见证排除环境
  冻结、50 ms 超时臂与 tmpfs 日志排除项、V6 主任务 accept
  同负载 0 错误对照）。
- 本线未动 def12-local staging，移交由主会话转发 DEF 线。
