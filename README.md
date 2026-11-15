# Black Market · 黑市

**L4D2 补给点经济系统** —— 打特感赚点数，`!shop` 买补给，数据跨地图存档。

A supply-point economy for Left 4 Dead 2 co-op. Kill special infected, earn points, spend them at `!shop`. Persists across maps via SQLite.

![version](https://img.shields.io/badge/version-1.4.5-blue)
![sourcemod](https://img.shields.io/badge/SourceMod-1.12%2B-orange)
![game](https://img.shields.io/badge/game-L4D2-red)
![license](https://img.shields.io/badge/license-MIT-green)

---

## 中文

### 这是什么

给 L4D2 联机加一层经济循环：**打特感赚钱 → 花在补给上 → 活得更久**。

不是资源替换包，是服务器端 SourceMod 插件，只在**自己开服/单机**时生效。

### 特性

- **赚点**：特感 +3、Witch +5（一击秒杀 +7）、Tank +25、救起队友 +4、电击器 +6、治疗队友 +4、过一章全队 +10
- **连杀**：25 秒内连杀 3/5/8/12 只特感，额外 +5/+10/+20/+40，全服播报
- **商店**：15 件商品分 4 类（补给 / 投掷 / 弹药升级 / 武器），`!shop` 打开
- **特价**：每张图随机 2 件五折，开局播报
- **存档**：SteamID64 存 SQLite，`bm_players` 表，换图/重启不丢
- **排行榜** `!top`、**个人数据** `!pts`
- **作弊**：`!cheat` 花多少补回多少，`!bmadd 500` 直接加（可关）
- **属性强化**：`!attr` 用补给点强化 火力 / 近战 / 投掷 / 换弹 / 移速，每项 3 级，**通关后自动清零**
- **提示音**：购买成功 / 点数不足两声，来自配套创意工坊音效包（可选，不订阅就静音）

### 前置

- Left 4 Dead 2
- MetaMod:Source 1.11+
- SourceMod 1.12+（在 1.12.0.7259 上编译验证）

### 安装

1. 解压到 `Left 4 Dead 2/left4dead2/`，合并 `addons` 和 `cfg` 目录
2. 游戏启动选项加 `-insecure`（**必须**，否则 L4D2 拒绝加载任何插件）
3. 进图后控制台 `sm plugins list`，应出现 `Black Market`

> `-insecure` 会关闭 VAC，代价是进不了 VAC 服务器。打野队时把启动选项清空即可。

### 配套资源

- **一键安装包** `BlackMarket_Installer_v1.4.2.zip` —— 双击自动找游戏目录、装好 MetaMod + SourceMod + 插件，适合不想手动折腾的朋友
- **创意工坊音效包** `Black Market Sound Pack` —— 订阅后在装了本插件的服务器里会有购买成功 / 补点不足两种提示音；没订阅也能正常玩，只是没声音（**每位玩家都要自己订阅**）

### 命令

| 命令 | 作用 |
|---|---|
| `!shop` / `!bm` | 商店 |
| `!attr` | 属性强化面板 |
| `!pts` | 自己的点数与击杀 |
| `!top` | 排行榜前 10 |
| `!cheat` | 自动补给（作弊） |
| `!bmadd <n>` | 加减点数（作弊） |
| `!bmzero` | 补给点清零（作弊） |
| `sm_bm_give <目标> <n>` | 管理员发点 |
| `sm_bm_resetall` | 清空存档（root） |

### 配置

`cfg/sourcemod/l4d2_black_market.cfg`：

```
sm_bm_enabled            1
sm_bm_sounds             1
sm_bm_attrs              1
sm_bm_campaign_reset     1
sm_bm_reset_points       1
sm_bm_debug              0
sm_bm_points_mult        1.0
sm_bm_price_mult         1.0
sm_bm_killnotify         1
sm_bm_streak_window      25.0
sm_bm_chapter_bonus      10
sm_bm_cheat_enabled      1
sm_bm_cheat_amount       9999
```

### 编译

```bash
spcomp -i "addons/sourcemod/scripting/include" \
       -o "plugins/l4d2_black_market.smx" \
       "scripting/l4d2_black_market.sp"
```

### 许可

MIT，见 [LICENSE](LICENSE)。

---

## English

### What it is

A server-side SourceMod plugin that adds a supply-point economy to L4D2 co-op:
kill special infected to earn points, spend them on supplies, upgrades and weapons.

### Features

- **Earn**: special infected +3, Witch +5 (+7 one-shot), Tank +25, revive +4, defib +6, heal teammate +4, chapter clear +10 for the team
- **Killstreaks**: 3/5/8/12 special kills within 25s → bonus points + server-wide announcement
- **Shop**: 15 items in 4 categories via `!shop`
- **Daily deals**: 2 random items at 50% off each map
- **Persistence**: SQLite, keyed by SteamID64
- **Leaderboard** `!top`, personal stats `!pts`
- **Attributes**: `!attr` — damage / melee / throw speed / reload / movement, 3 levels each, reset when the campaign ends
- **Sounds**: buy / deny cues from the companion Workshop sound pack (optional — silent if not subscribed)
- **Cheats**: `!cheat`, `!bmadd <n>` (can be disabled)

### Requirements

- Left 4 Dead 2
- MetaMod:Source 1.11+
- SourceMod 1.12+ (built and tested on 1.12.0.7259)

### Install

1. Extract into `Left 4 Dead 2/left4dead2/`, merging `addons` and `cfg`
2. Add `-insecure` to the game's launch options (**required** — L4D2 refuses to load any plugin DLL otherwise)
3. In console: `sm plugins list` → expect `Black Market`

### Note on localization

In-game text is currently **Simplified Chinese only**. Pull requests adding SourceMod phrase files are welcome.

### License

MIT.
