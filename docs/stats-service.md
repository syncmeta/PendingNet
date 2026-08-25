# 统计服务（sbtally 采集器）

统计页面的数据来自 `sbtally daemon`——它连引擎的 Clash API 收连接快照，落进
SQLite，再从 `http://127.0.0.1:7777` 把结果吐给 App。这份文档写清它由谁拉起、
密钥怎么流过去、老残留怎么处理，以及**装上之后该逐条验什么**。

## 谁在跑采集器

同一时刻只有一个 owner，由接管方式决定（判断在
`SBTallyCore/PendingNetStatsService.collectorOwner`，两侧共用，有单测）：

| 接管方式 | 引擎由谁起 | 采集器由谁起 | 密钥怎么给 |
| --- | --- | --- | --- |
| 仅端口 | App 的子进程 | App（`PendingNetStatsDaemon`） | `-secret-file` 指向 `~/Library/Application Support/PendingNet/engine/control-secret`，每次用时现读 |
| 系统代理 / TUN | 特权助手用 root 起的 launchd 作业 | 特权助手（`StatsCollector`） | `-secret-stdin`，走管子，不落磁盘、不上命令行、不进环境变量 |
| 引擎没在跑 | — | 没人 | — |

两种模式写**同一个统计库**（`~/Library/Application Support/sbtally/sbtally.db`），
所以切接管方式统计不会清零。助手那份采集器因此必须 `sudo -u <登录用户>` 降身份
跑：root 建出来的库和它的 `-wal`/`-shm` 会是 root 所有，之后「仅端口」那份就再也
写不进去，而且是静默写不进去。

降身份是采集器**自己**做的（`-drop-to-uid` / `-drop-to-gid`，fork 之后 exec 之前
setgid/setuid），**不要**改成 `sudo -u`：sudo 从 1.9.14 起默认 `use_pty`，会套一个
伪终端并自己当中间人——密钥走 stdin 进来会被回显抄进日志，管子断掉的 EOF 也传不到
孙子进程。

助手握着采集器 stdin 的写端，那根管子同时是**命脉**：写端一关（换接管方式、停
引擎、助手自己被 SIGKILL），采集器自己退场，不会留下一个还占着 7777 的孤儿。

App 不需要知道自己处在哪种接管方式：「仅端口」下它看自己那个子进程，另外两种
下它问助手要 `statsStatus`（XPC 接口版本 5），拿到的都是同一件事——现在有没有人
在采、没有的话该跟用户说什么。

## 老残留

`deploy/install.sh` 那条手工路径会装一个用户级 LaunchAgent `io.sbtally.daemon`，
它指着旧端口旧密钥、还开机自启。哪一侧先要起采集器，哪一侧就负责接管它：
`launchctl bootout`，再把 plist 改名成 `io.sbtally.daemon.plist.pendingnet-disabled`
留在原地（launchd 不再收它，改回后缀就能还原）。落点固定，重复执行不会堆备份。

## 端口

统计接口默认 7777。「仅端口」下被别的程序占了会往后挪一个并把新端口告诉读的
那一侧；助手那侧固定用 7777（App 要能读到），占着不放就报出来让用户腾。

---

## 装上之后要逐条验的（GUI 部分，只能人来做）

命令行能验的部分（构建、签名、密钥轮换自愈、管子断了不留孤儿、判断层）都有
单测或实跑证据了。下面这些必须装上 App 才验得了。

**准备**：`sudo lsof -nP -iTCP:7777 -sTCP:LISTEN` 记下现在是谁占着 7777；
`ls -l ~/Library/LaunchAgents/ | grep sbtally` 记下老残留在不在。

### 1. TUN 模式下有统计（这次返工的正题）

1. 打开 App → 连接页切到 **TUN** → 连上 VPS。
2. 正常上一会儿网（开几个网页）。
3. 看**应用**页。

**期望**：能看到按应用分的流量。**不该**再看到任何一句「暂时没有统计」。

**对不上就看**：`tail -20 /var/log/pendingnet-stats.log`（采集器自己的日志）和
`tail -20 /var/log/pendingnet-helper.log`（里面有一行「统计采集器已起（用户 …，
引擎控制口 …，统计端口 …）」）。

### 2. 系统代理模式同上

切到**系统代理**、上会儿网、看应用页。期望同上。

### 3. 采集器确实降到了你的身份，库没被 root 占（最容易翻车的一条）

```
ps -o user=,command= -p "$(lsof -nP -tiTCP:7777 -sTCP:LISTEN)"
ls -l ~/Library/Application\ Support/sbtally/
```

**期望**：进程的 user 是**你**（不是 root）；`sbtally.db` 和它的 `-wal`/`-shm`
属主也是**你**。任何一个是 root 都算这条不通过——那会让「仅端口」模式后续写不进去。

顺带确认密钥没漏：`grep -c the-secret /var/log/pendingnet-stats.log` 之类没意义
（真密钥你不知道），改看**命令行上有没有密钥**——
`ps -o command= -p "$(lsof -nP -tiTCP:7777 -sTCP:LISTEN)"`
期望只看到 `-secret-stdin`，看不到任何一串随机十六进制。

### 4. 三种模式切来切去，不打架也不断档

连接页依次切 **TUN → 仅端口 → 系统代理 → TUN**，每切一次：

```
lsof -nP -iTCP:7777 -sTCP:LISTEN
```

**期望**：每次**只有一个** sbtally 在 7777 上（不是两个，也不是零个——只要引擎
在跑就该有一个）。切完统计页仍有数据。

### 5. 历史数据没被切没

切模式前后各看一次**应用**页（时间范围选 24 小时）。

**期望**：切换前的流量切换后**还在**，不是从零开始。

### 6. 老残留被干净接管

```
ls -l ~/Library/LaunchAgents/ | grep sbtally
launchctl print "gui/$(id -u)/io.sbtally.daemon" >/dev/null 2>&1 && echo "还在跑" || echo "已卸载"
```

**期望**：`io.sbtally.daemon.plist` 变成 `io.sbtally.daemon.plist.pendingnet-disabled`，
作业显示「已卸载」。**想还原**：改回 `.plist` 后缀再
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.sbtally.daemon.plist`。

### 7. 停掉代理，采集器跟着走

连接页点断开，然后 `lsof -nP -iTCP:7777 -sTCP:LISTEN`。

**期望**：没有输出（7777 空了）。统计页显示「还没有连接」，而不是「统计服务坏了」。

### 8. 退出 App / 重启助手不留孤儿

退出 PendingNet，再 `lsof -nP -iTCP:7777 -sTCP:LISTEN`。

**期望**：没有残留的 sbtally 占着 7777。

### 9. 助手是新版（接口版本 5）

这一版加了 `statsStatus`，旧助手会被既有的版本握手自动退场，不需要重新授权。
若统计页说「后台服务还不是这一版」：退出 PendingNet 再打开一次；还不行就在设置
里重新授权后台服务。
