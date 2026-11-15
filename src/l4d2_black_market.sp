/*
 *  「黑市」 Black Market  v1.0.0
 *  L4D2 补给点经济系统
 *
 *  玩法循环：
 *    打特感 / 救队友 / 过章节  ->  赚「补给点」(SP)
 *    !shop                     ->  在黑市买医疗包、投掷物、弹药升级、特殊武器
 *    数据存 SQLite              ->  跨地图、跨重启都保留
 *
 *  作者: DSH
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dbi>


#define PLUGIN_VERSION  "1.4.7"
#define BM_TAG          "\x04[黑市]\x01"
#define MAX_SHOP_ITEMS  64
#define SHOP_PER_PAGE   6
#define ATTR_MAX        5
#define ATTR_LV_MAX     3
#define BM_MAX_ENT      2048

/* ---------- 奖励基础值（再乘 sm_bm_points_mult） ---------- */
#define PTS_SPECIAL     3
#define PTS_WITCH       5
#define PTS_TANK        25
#define PTS_REVIVE      4
#define PTS_DEFIB       6
#define PTS_HEAL        4

/* ---------- 商店分类 ---------- */
enum
{
	CAT_SUPPLY = 0,     // 补给
	CAT_THROW,          // 投掷物
	CAT_UPGRADE,        // 弹药升级
	CAT_WEAPON,         // 武器（常用，平铺一页）
	CAT_MORE,           // 更多武器（全量，分层）
	CAT_MAX
};

/* 武器子类：远程按枪种分，近战单独一类 */
enum
{
	SUB_NONE = 0,
	SUB_SMG,            // 冲锋枪
	SUB_SHOTGUN,        // 霰弹枪
	SUB_RIFLE,          // 步枪
	SUB_SNIPER,         // 狙击枪
	SUB_SPECIAL,        // 特殊武器
	SUB_PISTOL,         // 手枪
	SUB_MELEE,          // 近战武器
	SUB_MAX
};

enum struct ShopEntry
{
	int  cat;
	int  sub;
	int  price;         // 基础价（再乘 sm_bm_price_mult）
	char id[24];
	char name[48];
	char cls[48];
	char note[64];
	char melee[32];     // 非空表示近战武器，值 = 近战脚本名
}

ShopEntry g_eShop[MAX_SHOP_ITEMS];
int       g_iShopCount = 0;

/* ---------- 每个玩家的运行期数据 ---------- */
int   g_iPoints[MAXPLAYERS + 1];
int   g_iKills[MAXPLAYERS + 1];     // 累计特感击杀
int   g_iStreak[MAXPLAYERS + 1];    // 当前连杀
float g_fLastKill[MAXPLAYERS + 1];
bool  g_bLoaded[MAXPLAYERS + 1];

/* ---------- 本图特价商品 ---------- */
int g_iSale[2] = { -1, -1 };

/* ---------- 句柄 ---------- */
ConVar   g_cvEnabled;
ConVar   g_cvPointsMult;
ConVar   g_cvPriceMult;
ConVar   g_cvKillNotify;
ConVar   g_cvStreakWindow;
ConVar   g_cvChapterBonus;
ConVar   g_cvCheatEnabled;
ConVar   g_cvCheatAmount;
ConVar   g_cvSounds;
ConVar   g_cvAttrs;
ConVar   g_cvCampaignReset;
ConVar   g_cvResetPoints;
ConVar   g_cvDebug;
ConVar   g_cvSoundMode;
ConVar   g_cvReloadStep;      // 换弹强化：每级减少的比例
ConVar   g_cvReloadFloor;     // 换弹强化：换弹时间倍率下限
ConVar   g_cvSniperBolt;      // 狙击枪拉栓（射击间隔）是否吃换弹强化
ConVar   g_cvSniperAnim;      // 狙击枪拉栓动画是否同步加速
ConVar   g_cvShotgunAnim;     // 散弹枪泵动动画是否同步加速
ConVar   g_cvSniperFloor;     // 狙击枪射击间隔倍率下限
ConVar   g_cvAutoBind;       // 玩家进服时自动把 B 键绑到商店
ConVar   g_cvDmgStep;         // 火力强化：每级提升比例
ConVar   g_cvMeleeStep;       // 近战强化：每级提升比例
ConVar   g_cvSpeedStep;       // 体能强化：每级提升比例
float    g_fSpeedForce[MAXPLAYERS + 1];
float    g_fShotBase[BM_MAX_ENT][3];      // 散弹枪三个换弹时长的原始值
bool     g_bShotBase[BM_MAX_ENT];         // 上面那组原始值是否已记录
int      g_iShotTicks[MAXPLAYERS + 1];    // 换弹加速的调试节流计数   // 调试：只对下命令的这个人生效的强制移速
int      g_iDmgSeen[MAXPLAYERS + 1];      // 伤害诊断：作为攻击者进入回调的次数
int      g_iDmgBoosted[MAXPLAYERS + 1];   // 伤害诊断：真正加了成的次数
char     g_sDmgWeapon[MAXPLAYERS + 1][48];// 伤害诊断：最近一次造成伤害的武器
float    g_fDmgMult[MAXPLAYERS + 1];      // 伤害诊断：最近一次的加成倍率
ConVar   g_cvGrenadeMult;     // 榴弹发射器换弹额外倍率
int      g_iViewModelO  = -1; // CTerrorPlayer::m_hViewModel
int      g_iVMStartTimeO = -1;// CTerrorViewModel::m_flLayerStartTime
int      g_iBoltWeapon[MAXPLAYERS + 1];   // 狙击拉栓：上次记录的武器
int      g_iPlaybackGen[MAXPLAYERS + 1];  // 播放倍率“代号”，防止旧定时器把新的倍率重置掉
float    g_fBoltNext[MAXPLAYERS + 1];     // 狙击拉栓：上次写入的可开火时间
float    g_fReloadBusy[MAXPLAYERS + 1];   // 换弹进行到什么时候（这段时间别去抢播放倍率）
bool     g_bPrecBuy = false;
bool     g_bPrecDeny = false;
int      g_iSndTestCount[MAXPLAYERS + 1];

Database g_hDB = null;
bool     g_bDBReady = false;
bool     g_bChapterPaid = false;
bool     g_bCheat[MAXPLAYERS + 1];
int      g_iAttr[MAXPLAYERS + 1][ATTR_MAX];
bool     g_bThrowBoosted[BM_MAX_ENT];
bool     g_bThrowTracked[BM_MAX_ENT];
int      g_iThrowTicks[BM_MAX_ENT];
int      g_iThrowOwner[BM_MAX_ENT];
float    g_fThrowLast[BM_MAX_ENT][3];

public Plugin myinfo =
{
	name        = "Black Market",
	author      = "DSH",
	description = "L4D2 补给点经济：击杀特感赚点，!shop 消费，跨地图存档",
	version     = PLUGIN_VERSION,
	url         = ""
};

/* ============================================================
 *  启动
 * ============================================================ */

public void OnPluginStart()
{
	g_cvEnabled      = CreateConVar("sm_bm_enabled",      "1",    "1=开启黑市系统", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvPointsMult   = CreateConVar("sm_bm_points_mult",  "1.0",  "补给点获取倍率", _, true, 0.1, true, 10.0);
	g_cvPriceMult    = CreateConVar("sm_bm_price_mult",   "1.0",  "商品价格倍率",   _, true, 0.1, true, 10.0);
	g_cvKillNotify   = CreateConVar("sm_bm_killnotify",   "1",    "1=击杀特感时给本人一条提示", _, true, 0.0, true, 1.0);
	g_cvStreakWindow = CreateConVar("sm_bm_streak_window","25.0", "连杀判定窗口（秒）", _, true, 1.0);
	g_cvChapterBonus = CreateConVar("sm_bm_chapter_bonus","10",   "通过一章时全队奖励的补给点", _, true, 0.0);
	g_cvCheatEnabled = CreateConVar("sm_bm_cheat_enabled","1",    "1=允许 !cheat / !bmadd 作弊命令", _, true, 0.0, true, 1.0);
	g_cvCheatAmount  = CreateConVar("sm_bm_cheat_amount", "9999", "作弊模式下自动补到的补给点数", _, true, 0.0);
	g_cvSounds       = CreateConVar("sm_bm_sounds",       "1",    "1=播放黑市提示音（需订阅创意工坊音效包）", _, true, 0.0, true, 1.0);
	g_cvAttrs        = CreateConVar("sm_bm_attrs",        "1",    "1=开启属性强化系统（!attr）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCampaignReset = CreateConVar("sm_bm_campaign_reset", "1", "1=通关或全灭后清空属性", _, true, 0.0, true, 1.0);
	g_cvResetPoints  = CreateConVar("sm_bm_reset_points", "1",    "1=通关时补给点也一起清零", _, true, 0.0, true, 1.0);
	g_cvDebug        = CreateConVar("sm_bm_debug",        "0",    "1=在服务器控制台输出投掷物加速的调试信息", _, true, 0.0, true, 1.0);
	g_cvSoundMode    = CreateConVar("sm_bm_sound_mode",   "0",    "0=客户端 play 命令（默认，唯一实测可用的方式）  1=引擎 EmitSound", _, true, 0.0, true, 1.0);
	g_cvReloadStep   = CreateConVar("sm_bm_attr_reload_step",  "0.20", "换弹强化每级减少的换弹时间比例（0.20 = 每级 -20%，三级 -60%）", _, true, 0.05, true, 0.45);
	g_cvReloadFloor  = CreateConVar("sm_bm_attr_reload_floor", "0.30", "换弹时间倍率下限（0.30 = 最快只剩原时长的 30%）", _, true, 0.20, true, 0.90);
	g_cvSniperBolt   = CreateConVar("sm_bm_attr_sniper_bolt",  "1",    "1=狙击枪的拉栓/射击间隔也吃换弹强化", _, true, 0.0, true, 1.0);
	g_cvShotgunAnim  = CreateConVar("sm_bm_attr_shotgun_anim", "0",    "1=散弹枪泵动/上膛动画也加速（实验，可能引出双动画）", _, true, 0.0, true, 1.0);
	g_cvSniperAnim   = CreateConVar("sm_bm_attr_sniper_anim",  "0",    "1=拉栓动画同步加速（会让开火动画重播、多掉弹壳，默认关）", _, true, 0.0, true, 1.0);
	g_cvSniperFloor  = CreateConVar("sm_bm_attr_sniper_floor", "0.60", "狙击枪射击间隔的倍率下限（0.60 = 最快只剩 60%）", _, true, 0.30, true, 0.95);
	g_cvGrenadeMult  = CreateConVar("sm_bm_attr_gl_mult",      "0.85", "榴弹发射器换弹在强化基础上再乘这个值（0.85 = 再快 15%）", _, true, 0.50, true, 1.0);
	g_cvAutoBind     = CreateConVar("sm_bm_autobind",        "1",    "1=玩家进服时自动把 B 键绑到 !shop（0=不碰玩家按键）", _, true, 0.0, true, 1.0);
	g_cvDmgStep      = CreateConVar("sm_bm_attr_dmg_step",     "0.10", "火力强化每级提升的枪械伤害比例（0.10 = 每级 +10%，三级 +30%）", _, true, 0.01, true, 0.50);
	g_cvMeleeStep    = CreateConVar("sm_bm_attr_melee_step",   "0.18", "近战强化每级提升的近战伤害比例（0.18 = 每级 +18%，三级 +54%）", _, true, 0.01, true, 1.00);
	g_cvSpeedStep    = CreateConVar("sm_bm_attr_speed_step",   "0.10", "体能强化每级提升的移动速度比例（0.10 = 每级 +10%，三级 +30%）", _, true, 0.01, true, 0.30);

	LoadShopTable();
	HookGameEvents();
	RegisterCommands();
	ConnectDatabase();

	// 换弹动画对齐用的两个偏移（拿不到就跳过对齐，不影响别的东西）
	g_iViewModelO   = FindSendPropInfo("CTerrorPlayer",    "m_hViewModel");
	g_iVMStartTimeO = FindSendPropInfo("CTerrorViewModel", "m_flLayerStartTime");
	if (g_iViewModelO < 0 || g_iVMStartTimeO < 0)
	{
		PrintToServer("[BlackMarket] 换弹动画对齐不可用（viewmodel 偏移未找到），音效/其它功能不受影响");
	}

	AutoExecConfig(true, "l4d2_black_market");

	PrintToServer("[BlackMarket] v%s 已加载（%d 件商品）", PLUGIN_VERSION, g_iShopCount);
}

void HookGameEvents()
{
	HookEvent("player_death",      Event_PlayerDeath,   EventHookMode_Post);
	HookEvent("witch_killed",      Event_WitchKilled,   EventHookMode_Post);
	HookEvent("revive_success",    Event_ReviveSuccess, EventHookMode_Post);
	HookEvent("defibrillator_used", Event_DefibUsed,    EventHookMode_Post);
	HookEvent("heal_success",      Event_HealSuccess,   EventHookMode_Post);
	HookEvent("map_transition",    Event_ChapterDone,   EventHookMode_Post);
	HookEvent("finale_win",        Event_ChapterDone,   EventHookMode_Post);

	// 属性系统用到的
	HookEvent("player_spawn",      Event_PlayerSpawn,   EventHookMode_Post);
	HookEvent("weapon_reload",     Event_WeaponReload,  EventHookMode_Post);

	// 一局结束：通关或全灭
	HookEvent("finale_win",        Event_CampaignEnd,   EventHookMode_Post);
	HookEvent("mission_lost",      Event_CampaignEnd,   EventHookMode_Post);
}

void RegisterCommands()
{
	RegConsoleCmd("sm_shop", Cmd_Shop,     "打开黑市商店");
	RegConsoleCmd("sm_bm",   Cmd_Shop,     "打开黑市商店（简写）");
	RegConsoleCmd("sm_pts",  Cmd_Points,   "查看自己的补给点");
	RegConsoleCmd("sm_top",  Cmd_Top,      "补给点排行榜");
	RegConsoleCmd("sm_attr", Cmd_Attr,     "属性强化面板");

	// 本地开服用的作弊命令（受 sm_bm_cheat_enabled 控制）
	RegConsoleCmd("sm_bm_add", Cmd_CheatAdd, "给自己加/减补给点，例: !bmadd 500");
	RegConsoleCmd("sm_bmadd",  Cmd_CheatAdd, "同上（聊天框 !bmadd 会映射到这个名字）");
	RegConsoleCmd("sm_bmzero", Cmd_ZeroPoints, "把自己的补给点清零");
	RegConsoleCmd("sm_bm_sndcheck", Cmd_SoundCheck, "检查音效文件是否被游戏读到");
	RegConsoleCmd("sm_bm_sndtest",  Cmd_SoundTest,  "分别用引擎和 play 命令放两声，测试哪条路通");
	RegConsoleCmd("sm_cheat",  Cmd_Cheat,    "开关自动补给点（花多少自动补满）");

	// 临时测试面板（受 sm_bm_cheat_enabled 控制，正式发布前可去掉）
	RegConsoleCmd("sm_test", Cmd_TestMenu, "黑市测试面板（临时）");

	RegAdminCmd("sm_bm_give",     Cmd_AdminGive, ADMFLAG_CHEATS, "sm_bm_give <目标> <数量>  发补给点");
	RegAdminCmd("sm_bm_resetall", Cmd_AdminReset, ADMFLAG_ROOT,  "清空所有人的补给点存档");
}

/* ============================================================
 *  商品表
 * ============================================================ */

void AddShopItem(int cat, int sub, const char[] id, int price, const char[] name, const char[] cls, const char[] note, const char[] melee = "")
{
	if (g_iShopCount >= MAX_SHOP_ITEMS)
	{
		return;
	}

	ShopEntry e;
	e.cat   = cat;
	e.sub   = sub;
	e.price = price;
	strcopy(e.id,    sizeof(e.id),    id);
	strcopy(e.name,  sizeof(e.name),  name);
	strcopy(e.cls,   sizeof(e.cls),   cls);
	strcopy(e.note,  sizeof(e.note),  note);
	strcopy(e.melee, sizeof(e.melee), melee);

	g_eShop[g_iShopCount] = e;
	g_iShopCount++;
}

void LoadShopTable()
{
	g_iShopCount = 0;

	/* 补给 */
	AddShopItem(CAT_SUPPLY, SUB_NONE, "medkit",   8,  "医疗包",     "weapon_first_aid_kit", "回满血，或救活队友");
	AddShopItem(CAT_SUPPLY, SUB_NONE, "pills",    4,  "止痛药",     "weapon_pain_pills",    "临时血量");
	AddShopItem(CAT_SUPPLY, SUB_NONE, "adren",    6,  "肾上腺素",   "weapon_adrenaline",    "加速 + 临时血量");
	AddShopItem(CAT_SUPPLY, SUB_NONE, "defib",    14, "电击器",     "weapon_defibrillator", "把死掉的队友拉起来");

	/* 投掷物 */
	AddShopItem(CAT_THROW, SUB_NONE, "pipe",     4,  "管状炸弹",   "weapon_pipe_bomb",     "引开尸潮");
	AddShopItem(CAT_THROW, SUB_NONE, "molotov",  4,  "燃烧瓶",     "weapon_molotov",       "封路清场");
	AddShopItem(CAT_THROW, SUB_NONE, "vomit",    4,  "胆汁瓶",     "weapon_vomitjar",      "把僵尸糊一脸");

	/* 弹药升级 */
	AddShopItem(CAT_UPGRADE, SUB_NONE, "incen",     6, "燃烧弹升级", "upgrade_ammo_incendiary", "子弹点燃目标");
	AddShopItem(CAT_UPGRADE, SUB_NONE, "explosive", 6, "高爆弹升级", "upgrade_ammo_explosive",  "子弹范围爆炸");
	AddShopItem(CAT_UPGRADE, SUB_NONE, "laser",     6, "激光瞄准",   "upgrade_laser_sight",     "腰射也能准");

	/* 武器（常用，平铺一页） */
	AddShopItem(CAT_WEAPON, SUB_NONE, "ak47",     10, "AK-47",      "weapon_rifle_ak47",    "高伤害步枪");
	AddShopItem(CAT_WEAPON, SUB_NONE, "m16",      8,  "M16 步枪",   "weapon_rifle",         "稳定连射");
	AddShopItem(CAT_WEAPON, SUB_NONE, "autoshot", 9,  "自动霰弹",   "weapon_autoshotgun",   "近距离清场");
	AddShopItem(CAT_WEAPON, SUB_NONE, "hunting",  8,  "猎枪",       "weapon_hunting_rifle", "远距离点杀");
	AddShopItem(CAT_WEAPON, SUB_NONE, "grenade",  16, "榴弹发射器", "weapon_grenade_launcher", "别对着墙打");

	/* 更多武器：冲锋枪 */
	AddShopItem(CAT_MORE, SUB_SMG, "smg",    5, "SMG",      "weapon_smg",          "30 发弹匣");
	AddShopItem(CAT_MORE, SUB_SMG, "smgsil", 5, "消音 SMG", "weapon_smg_silenced", "更稳，子弹更多");
	AddShopItem(CAT_MORE, SUB_SMG, "mp5",    6, "MP5",      "weapon_smg_mp5",      "冲锋枪里的全能款");

	/* 远程：霰弹枪 */
	AddShopItem(CAT_MORE, SUB_SHOTGUN, "pumpshot", 5,  "泵动霰弹", "weapon_pumpshotgun",    "一下一下推");
	AddShopItem(CAT_MORE, SUB_SHOTGUN, "chrome",   6,  "铬管霰弹", "weapon_shotgun_chrome", "比泵动好一点");
	AddShopItem(CAT_MORE, SUB_SHOTGUN, "autoshot", 9,  "自动霰弹", "weapon_autoshotgun",    "近距离清场");
	AddShopItem(CAT_MORE, SUB_SHOTGUN, "spas",     10, "SPAS",     "weapon_shotgun_spas",   "连喷里最稳");

	/* 远程：步枪 */
	AddShopItem(CAT_MORE, SUB_RIFLE, "m16",    8,  "M16 步枪", "weapon_rifle",        "稳定连射");
	AddShopItem(CAT_MORE, SUB_RIFLE, "ak47",   10, "AK-47",    "weapon_rifle_ak47",   "高伤害步枪");
	AddShopItem(CAT_MORE, SUB_RIFLE, "desert", 9,  "战斗步枪", "weapon_rifle_desert", "三连发点射");
	AddShopItem(CAT_MORE, SUB_RIFLE, "sg552",  9,  "SG552",    "weapon_rifle_sg552",  "带镜的步枪");
	AddShopItem(CAT_MORE, SUB_RIFLE, "m60",    16, "M60",      "weapon_rifle_m60",    "100 发弹链，不能换弹");

	/* 远程：狙击枪 */
	AddShopItem(CAT_MORE, SUB_SNIPER, "hunting",  8,  "猎枪",     "weapon_hunting_rifle",   "远距离点杀");
	AddShopItem(CAT_MORE, SUB_SNIPER, "military", 12, "军用狙击", "weapon_sniper_military", "秒特感");
	AddShopItem(CAT_MORE, SUB_SNIPER, "scout",    12, "侦察狙击", "weapon_sniper_scout",    "轻，换弹快");
	AddShopItem(CAT_MORE, SUB_SNIPER, "awp",      14, "AWP",      "weapon_sniper_awp",      "一枪一个特感");

	/* 远程：特殊武器 */
	AddShopItem(CAT_MORE, SUB_SPECIAL, "grenade", 16, "榴弹发射器", "weapon_grenade_launcher", "别对着墙打");

	/* 远程：手枪 */
	AddShopItem(CAT_MORE, SUB_PISTOL, "pistol", 3, "手枪",   "weapon_pistol",        "双持基础款");
	AddShopItem(CAT_MORE, SUB_PISTOL, "magnum", 6, "马格南", "weapon_pistol_magnum", "一枪一个，弹少");

	/* 近战：cls 统一 weapon_melee（电锯除外），具体种类看最后一个参数 */
	AddShopItem(CAT_MORE, SUB_MELEE, "crowbar",   3, "撬棍",       "weapon_melee", "基础近战",   "crowbar");
	AddShopItem(CAT_MORE, SUB_MELEE, "bbat",      3, "棒球棍",     "weapon_melee", "挥得快",     "baseball_bat");
	AddShopItem(CAT_MORE, SUB_MELEE, "cbat",      3, "板球棒",     "weapon_melee", "差不多",     "cricket_bat");
	AddShopItem(CAT_MORE, SUB_MELEE, "pan",       3, "平底锅",     "weapon_melee", "叮当响",     "frying_pan");
	AddShopItem(CAT_MORE, SUB_MELEE, "eguitar",   4, "电吉他",     "weapon_melee", "同上",       "electric_guitar");
	AddShopItem(CAT_MORE, SUB_MELEE, "katana",    6, "武士刀",     "weapon_melee", "范围最大",   "katana");
	AddShopItem(CAT_MORE, SUB_MELEE, "knife",     5, "小刀",       "weapon_melee", "出手快",     "knife");
	AddShopItem(CAT_MORE, SUB_MELEE, "machete",   5, "砍刀",       "weapon_melee", "经典",       "machete");
	AddShopItem(CAT_MORE, SUB_MELEE, "golf",      3, "高尔夫球杆", "weapon_melee", "同上",       "golfclub");
	AddShopItem(CAT_MORE, SUB_MELEE, "tonfa",     4, "警棍",       "weapon_melee", "快",         "tonfa");
	AddShopItem(CAT_MORE, SUB_MELEE, "fireaxe",   5, "消防斧",     "weapon_melee", "重击",       "fireaxe");
	AddShopItem(CAT_MORE, SUB_MELEE, "chainsaw",  8, "电锯",       "weapon_chainsaw", "按住就切", "chainsaw");
}

int GetPrice(int idx)
{
	float mult = g_cvPriceMult.FloatValue;
	float p = float(g_eShop[idx].price) * mult;

	if (IsOnSale(idx))
	{
		p *= 0.5;
	}

	int finalPrice = RoundToNearest(p);
	if (finalPrice < 1)
	{
		finalPrice = 1;
	}
	return finalPrice;
}

bool IsOnSale(int idx)
{
	return (g_iSale[0] == idx || g_iSale[1] == idx);
}

int ScaledPoints(int base)
{
	int amt = RoundToNearest(float(base) * g_cvPointsMult.FloatValue);
	if (amt < 1)
	{
		amt = 1;
	}
	return amt;
}

void AwardPoints(int client, int amount, const char[] reason, bool notify)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	if (!g_cvEnabled.BoolValue)
	{
		return;
	}
	if (!g_bLoaded[client])      // 存档还没读回来，先不计分，避免被读档覆盖
	{
		return;
	}

	g_iPoints[client] += amount;

	if (notify)
	{
		PrintToChat(client, "%s %s  \x04+%d\x01  (合计 %d)", BM_TAG, reason, amount, g_iPoints[client]);
	}
}

/* 提示音：音效文件由创意工坊配套包提供，没订阅的客户端听不到，但不影响任何功能。
   L4D2 里 EmitSoundToClient 对 VPK 内的自定义音效经常不发声（连预缓存都不管用），
   所以直接用客户端 play 命令读本地文件——只要客户端有这个 wav 就能响。 */
/* 提示音：必须走 soundscript 名字。
   直接给文件路径的话，L4D2 只播 registered（game_sounds_manifest 里注册过）的音效，
   新路径会被静默丢弃——这是前面几轮排查的最终结论。 */
void PlayClientSound(int client, const char[] script, const char[] file = "")
{
	if (!g_cvSounds.BoolValue)
	{
		return;
	}

	if (g_cvSoundMode.BoolValue)
	{
		EmitSoundToClient(client, script);
		return;
	}

	if (file[0] == '\0')
	{
		return;
	}

	char cmd[128];
	Format(cmd, sizeof(cmd), "play %s", file);
	ClientCommand(client, cmd);
}

/* ============================================================
 *  事件
 * ============================================================ */

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
	{
		return;
	}
	if (GetClientTeam(victim) != 3)     // 只关心特感 / Tank
	{
		return;
	}

	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		return;
	}
	if (GetClientTeam(attacker) != 2 || IsFakeClient(attacker))
	{
		return;
	}

	int zclass = GetEntProp(victim, Prop_Send, "m_zombieClass");
	if (zclass < 1 || zclass > 6)       // 1..6 = 特感；7=Witch 走 witch_killed；8=Tank
	{
		if (zclass != 8)
		{
			return;
		}
	}

	int base;
	char label[48];

	if (zclass == 8)
	{
		base = PTS_TANK;
		strcopy(label, sizeof(label), "击杀 Tank");
	}
	else
	{
		base = PTS_SPECIAL;
		switch (zclass)
		{
			case 1:  strcopy(label, sizeof(label), "击杀 Smoker");
			case 2:  strcopy(label, sizeof(label), "击杀 Boomer");
			case 3:  strcopy(label, sizeof(label), "击杀 Hunter");
			case 4:  strcopy(label, sizeof(label), "击杀 Spitter");
			case 5:  strcopy(label, sizeof(label), "击杀 Jockey");
			default: strcopy(label, sizeof(label), "击杀 Charger");
		}
	}

	int amount = ScaledPoints(base);
	AwardPoints(attacker, amount, label, g_cvKillNotify.BoolValue);

	g_iKills[attacker]++;

	if (zclass == 8)
	{
		PrintToChatAll("%s \x04%N\x01 干掉了 Tank！", BM_TAG, attacker);
		return;
	}

	HandleStreak(attacker);
}

void HandleStreak(int client)
{
	float now = GetGameTime();

	if (now - g_fLastKill[client] <= g_cvStreakWindow.FloatValue)
	{
		g_iStreak[client]++;
	}
	else
	{
		g_iStreak[client] = 1;
	}
	g_fLastKill[client] = now;

	int streak = g_iStreak[client];
	int bonus  = 0;

	switch (streak)
	{
		case 3:  bonus = 5;
		case 5:  bonus = 10;
		case 8:  bonus = 20;
		case 12: bonus = 40;
	}

	if (bonus > 0)
	{
		int scaled = ScaledPoints(bonus);
		AwardPoints(client, scaled, "连杀奖励", false);
		PrintToChatAll("%s \x04%N\x01 达成 \x04%d 连杀\x01！额外 +%d 补给点", BM_TAG, client, streak, scaled);
	}
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
	int killer = GetClientOfUserId(event.GetInt("userid"));
	if (killer < 1 || killer > MaxClients || !IsClientInGame(killer))
	{
		return;
	}
	if (GetClientTeam(killer) != 2 || IsFakeClient(killer))
	{
		return;
	}

	bool oneshot = event.GetBool("oneshot");
	int amount = ScaledPoints(PTS_WITCH);
	if (oneshot)
	{
		amount += ScaledPoints(2);
	}

	AwardPoints(killer, amount, oneshot ? "一击秒杀 Witch" : "击杀 Witch", true);
}

public void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int reviver = GetClientOfUserId(event.GetInt("userid"));
	int revived = GetClientOfUserId(event.GetInt("subject"));

	if (reviver < 1 || reviver > MaxClients || !IsClientInGame(reviver))
	{
		return;
	}
	if (revived < 1 || revived == reviver)
	{
		return;
	}

	AwardPoints(reviver, ScaledPoints(PTS_REVIVE), "救起队友", true);
}

public void Event_DefibUsed(Event event, const char[] name, bool dontBroadcast)
{
	int user  = GetClientOfUserId(event.GetInt("userid"));
	int subj  = GetClientOfUserId(event.GetInt("subject"));

	if (user < 1 || user > MaxClients || !IsClientInGame(user))
	{
		return;
	}
	if (subj < 1 || subj == user)
	{
		return;
	}

	AwardPoints(user, ScaledPoints(PTS_DEFIB), "用电击器救人", true);
	PrintToChatAll("%s \x04%N\x01 把 \x04%N\x01 从鬼门关拉了回来", BM_TAG, user, subj);
}

public void Event_HealSuccess(Event event, const char[] name, bool dontBroadcast)
{
	int healer = GetClientOfUserId(event.GetInt("userid"));
	int subj   = GetClientOfUserId(event.GetInt("subject"));

	if (healer < 1 || healer > MaxClients || !IsClientInGame(healer))
	{
		return;
	}
	if (subj < 1 || subj == healer)      // 只奖励治别人
	{
		return;
	}

	int restored = event.GetInt("health_restored");
	if (restored <= 0)
	{
		return;
	}

	AwardPoints(healer, ScaledPoints(PTS_HEAL), "治疗队友", true);
}

public void Event_ChapterDone(Event event, const char[] name, bool dontBroadcast)
{
	int bonus = g_cvChapterBonus.IntValue;
	if (bonus <= 0 || g_bChapterPaid)
	{
		return;
	}
	g_bChapterPaid = true;

	int scaled = ScaledPoints(bonus);
	int count  = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == 2)
		{
			g_iPoints[i] += scaled;
			count++;
		}
	}

	if (count > 0)
	{
		PrintToChatAll("%s 章节通过，全队 \x04+%d\x01 补给点", BM_TAG, scaled);
	}
}

/* ============================================================
 *  商店界面
 * ============================================================ */

public Action Cmd_Shop(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	if (IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	if (!g_cvEnabled.BoolValue)
	{
		PrintToChat(client, "%s 黑市暂时关门了", BM_TAG);
		return Plugin_Handled;
	}

	ShowMainMenu(client);
	return Plugin_Handled;
}

void ShowMainMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("黑市商人\n补给点: %d", g_iPoints[client]);

	char info[16];
	char text[128];

	Format(info, sizeof(info), "c:%d", CAT_SUPPLY);
	Format(text, sizeof(text), "补给  (%d 件)", CountInCat(CAT_SUPPLY));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "c:%d", CAT_THROW);
	Format(text, sizeof(text), "投掷物  (%d 件)", CountInCat(CAT_THROW));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "c:%d", CAT_UPGRADE);
	Format(text, sizeof(text), "弹药升级  (%d 件)", CountInCat(CAT_UPGRADE));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "c:%d", CAT_WEAPON);
	Format(text, sizeof(text), "武器  (%d 件)", CountInCat(CAT_WEAPON));
	menu.AddItem(info, text);

	menu.AddItem("more", "更多武器（全部种类）");
	menu.AddItem("attr", "属性强化  (本局内有效)");
	menu.AddItem("pts", "查看我的数据");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}


public int MenuHandler_Main(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			if (StrEqual(info, "pts"))
			{
				ShowMyStats(param1);
				return 0;
			}

			if (StrEqual(info, "attr"))
			{
				ShowAttrMenu(param1);
				return 0;
			}

			if (StrEqual(info, "more"))
			{
				ShowWeaponMenu(param1);
				return 0;
			}

			if (info[0] == 'c' && info[1] == ':')
			{
				int cat = StringToInt(info[2]);
				if (cat >= 0 && cat < CAT_MAX)
				{
					ShowItemList(param1, cat, SUB_NONE, 0);
				}
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}


char[] CatName(int cat)
{
	static char buf[32];
	switch (cat)
	{
		case CAT_SUPPLY:  strcopy(buf, sizeof(buf), "补给");
		case CAT_THROW:   strcopy(buf, sizeof(buf), "投掷物");
		case CAT_UPGRADE: strcopy(buf, sizeof(buf), "弹药升级");
		case CAT_WEAPON:  strcopy(buf, sizeof(buf), "武器");
		case CAT_MORE:    strcopy(buf, sizeof(buf), "更多武器");
		default:          strcopy(buf, sizeof(buf), "商店");
	}
	return buf;
}

char[] SubName(int sub)
{
	static char buf[32];
	switch (sub)
	{
		case SUB_SMG:     strcopy(buf, sizeof(buf), " · 冲锋枪");
		case SUB_SHOTGUN: strcopy(buf, sizeof(buf), " · 霰弹枪");
		case SUB_RIFLE:   strcopy(buf, sizeof(buf), " · 步枪");
		case SUB_SNIPER:  strcopy(buf, sizeof(buf), " · 狙击枪");
		case SUB_SPECIAL: strcopy(buf, sizeof(buf), " · 特殊武器");
		case SUB_PISTOL:  strcopy(buf, sizeof(buf), " · 手枪");
		case SUB_MELEE:   strcopy(buf, sizeof(buf), " · 近战武器");
		default:          strcopy(buf, sizeof(buf), "");
	}
	return buf;
}

// 当前玩家正在看哪一栏（用于返回上级）
int g_iListCat[MAXPLAYERS + 1];
int g_iListSub[MAXPLAYERS + 1];

void ShowItemList(int client, int cat, int sub, int page = 0)
{
	int items[MAX_SHOP_ITEMS];
	int count = 0;

	for (int i = 0; i < g_iShopCount; i++)
	{
		if (g_eShop[i].cat == cat && g_eShop[i].sub == sub)
		{
			items[count++] = i;
		}
	}

	if (count == 0)
	{
		PrintToChat(client, "%s 这一栏暂时没货", BM_TAG);
		return;
	}

	int pages = (count + SHOP_PER_PAGE - 1) / SHOP_PER_PAGE;
	if (page < 0) page = 0;
	if (page >= pages) page = pages - 1;

	g_iListCat[client] = cat;
	g_iListSub[client] = sub;

	Menu menu = new Menu(MenuHandler_List);
	menu.SetTitle("%s%s\n补给点: %d   (%d/%d)", CatName(cat), SubName(sub), g_iPoints[client], page + 1, pages);
	menu.ExitBackButton = true;

	char info[24];
	char text[192];

	int startIdx = page * SHOP_PER_PAGE;
	for (int k = startIdx; k < startIdx + SHOP_PER_PAGE && k < count; k++)
	{
		int i = items[k];
		int price = GetPrice(i);
		Format(info, sizeof(info), "i:%d", i);

		if (IsOnSale(i))
		{
			Format(text, sizeof(text), "[特价] %s   %d 点  -  %s", g_eShop[i].name, price, g_eShop[i].note);
		}
		else
		{
			Format(text, sizeof(text), "%s   %d 点  -  %s", g_eShop[i].name, price, g_eShop[i].note);
		}
		menu.AddItem(info, text);
	}

	if (page > 0)
	{
		Format(info, sizeof(info), "p:%d:%d:%d", cat, sub, page - 1);
		menu.AddItem(info, "<< 上一页");
	}
	if (page + 1 < pages)
	{
		Format(info, sizeof(info), "p:%d:%d:%d", cat, sub, page + 1);
		menu.AddItem(info, "下一页 >>");
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_List(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[24];
			menu.GetItem(param2, info, sizeof(info));

			if (info[0] == 'i' && info[1] == ':')
			{
				TryBuy(param1, StringToInt(info[2]));
			}
			else if (info[0] == 'p' && info[1] == ':')
			{
				char parts[4][8];
				ExplodeString(info, ":", parts, 4, 8);
				ShowItemList(param1, StringToInt(parts[1]), StringToInt(parts[2]), StringToInt(parts[3]));
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				if (g_iListSub[param1] == SUB_MELEE)
				{
					ShowWeaponMenu(param1);
				}
				else if (g_iListCat[param1] == CAT_MORE)
				{
					ShowRangedMenu(param1);
				}
				else
				{
					ShowMainMenu(param1);
				}
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void ShowWeaponMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Weapon);
	menu.SetTitle("武器\n补给点: %d", g_iPoints[client]);
	menu.AddItem("ranged", "远程武器");
	menu.AddItem("melee",  "近战武器");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Weapon(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			if (StrEqual(info, "ranged"))
			{
				ShowRangedMenu(param1);
			}
			else if (StrEqual(info, "melee"))
			{
				ShowItemList(param1, CAT_MORE, SUB_MELEE, 0);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowMainMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void ShowRangedMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Ranged);
	menu.SetTitle("远程武器\n补给点: %d", g_iPoints[client]);
	menu.AddItem("1", "冲锋枪");
	menu.AddItem("2", "霰弹枪");
	menu.AddItem("3", "步枪");
	menu.AddItem("4", "狙击枪");
	menu.AddItem("5", "特殊武器");
	menu.AddItem("6", "手枪");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Ranged(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));
			ShowItemList(param1, CAT_MORE, StringToInt(info), 0);
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowWeaponMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

// 买完 / 失败后回到同一栏（自动算页码）
void ReopenList(int client, int idx)
{
	if (client < 1 || !IsClientInGame(client) || idx < 0 || idx >= g_iShopCount)
	{
		return;
	}

	int cat = g_eShop[idx].cat;
	int sub = g_eShop[idx].sub;

	int pos = 0;
	for (int i = 0; i < idx; i++)
	{
		if (g_eShop[i].cat == cat && g_eShop[i].sub == sub)
		{
			pos++;
		}
	}

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(cat);
	dp.WriteCell(sub);
	dp.WriteCell(pos / SHOP_PER_PAGE);
	CreateTimer(0.1, Timer_ReopenList, dp, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ReopenList(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int cat    = dp.ReadCell();
	int sub    = dp.ReadCell();
	int page   = dp.ReadCell();
	delete dp;

	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		ShowItemList(client, cat, sub, page);
	}
	return Plugin_Stop;
}


/* 菜单选中后引擎会立刻关掉它，此时同步 Display 有概率被吞。
   统一延迟一拍再开：cat < 0 表示回商店主界面。 */
void ReopenMenu(int client, int cat)
{
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(cat);
	CreateTimer(0.1, Timer_ReopenMenu, dp, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ReopenMenu(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int cat = dp.ReadCell();
	delete dp;

	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	if (cat == -1)
	{
		ShowMainMenu(client);
	}
	else if (cat == -2)
	{
		ShowAttrMenu(client);
	}
	else if (cat >= 0)
	{
		ShowItemList(client, cat, SUB_NONE, 0);
	}
	return Plugin_Stop;
}

/* 弹药升级：燃烧弹 / 高爆弹不是可拾取物品，GivePlayerItem 必然返回 -1。
 * 正确做法是直接写主武器的 m_upgradeBitVec（1=燃烧 2=爆炸），
 * 再把 m_nUpgradedPrimaryAmmoLoaded 设成当前弹匣量——这就是原版升级包干的事。
 * 参考：github.com/tuan0919/l4d2-sourcemod 的 Tuan_upgrade_ammo_pack.sp
 */
bool IsAmmoUpgrade(const char[] cls)
{
	return (StrEqual(cls, "upgrade_ammo_incendiary") || StrEqual(cls, "upgrade_ammo_explosive"));
}

// 成功返回武器实体索引，失败返回 -1
int ApplyAmmoUpgrade(int client, const char[] cls)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return -1;
	}

	if (!HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
	{
		return -1;
	}

	int bit = StrEqual(cls, "upgrade_ammo_explosive") ? 2 : 1;
	int bits = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");

	// 同类型已经装过就别重复扣点
	if ((bits & bit) != 0)
	{
		return -2;
	}

	bits &= ~3;
	bits |= bit;
	SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", bits);

	if (HasEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded"))
	{
		int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
		SetEntProp(weapon, Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", clip > 0 ? clip : 0);
	}

	return weapon;
}

/* 激光瞄准：它是挂在枪上的实体，GivePlayerItem 发不出来。
 * 备选方案是引擎自带的 upgrade_add 命令（原本是作弊命令），
 * 临时开 sv_cheats 执行完立刻还原。 */
bool TryGiveLaserSight(int client)
{
	int weapon = GetPlayerWeaponSlot(client, 0);
	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return false;
	}

	ConVar cheats = FindConVar("sv_cheats");
	bool restore = false;

	if (cheats != null && cheats.IntValue == 0)
	{
		cheats.SetInt(1);
		restore = true;
	}

	ClientCommand(client, "upgrade_add laser_sight");

	if (restore)
	{
		CreateTimer(0.3, Timer_RestoreCheatsLaser, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	return true;
}

public Action Timer_RestoreCheatsLaser(Handle timer)
{
	ConVar cheats = FindConVar("sv_cheats");
	if (cheats != null)
	{
		cheats.SetInt(0);
	}
	return Plugin_Stop;
}

// 近战武器：统一 weapon_melee（电锯单独一个类），具体种类用 m_strMapSetScriptName 指定
int GiveMeleeWeapon(int client, const char[] scriptName)
{
	char cls[32];

	if (StrEqual(scriptName, "chainsaw"))
	{
		strcopy(cls, sizeof(cls), "weapon_chainsaw");
	}
	else
	{
		strcopy(cls, sizeof(cls), "weapon_melee");
	}

	int ent = CreateEntityByName(cls);
	if (ent <= 0)
	{
		return -1;
	}

	if (!StrEqual(scriptName, "chainsaw"))
	{
		if (!HasEntProp(ent, Prop_Data, "m_strMapSetScriptName"))
		{
			RemoveEntity(ent);
			return -1;
		}
		SetEntPropString(ent, Prop_Data, "m_strMapSetScriptName", scriptName);
	}

	DispatchSpawn(ent);
	EquipPlayerWeapon(client, ent);
	return ent;
}

void TryBuy(int client, int idx)
{
	if (idx < 0 || idx >= g_iShopCount)
	{
		return;
	}
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	int price = GetPrice(idx);

	if (g_iPoints[client] < price)
	{
		PrintToChat(client, "%s 补给点不够：%s 需要 \x04%d\x01，你只有 %d",
			BM_TAG, g_eShop[idx].name, price, g_iPoints[client]);
		PlayClientSound(client, "BlackMarket.Deny", "blackmarket/bm_deny.mp3");
		ReopenList(client, idx);
		return;
	}

	if (!IsPlayerAlive(client))
	{
		PrintToChat(client, "%s 死了买不了东西，先让队友把你拉起来", BM_TAG);
		ReopenList(client, idx);
		return;
	}

	char cls[48];
	strcopy(cls, sizeof(cls), g_eShop[idx].cls);

	int ent;
	if (g_eShop[idx].melee[0] != '\0')
	{
		ent = GiveMeleeWeapon(client, g_eShop[idx].melee);

		if (ent == -1)
		{
			PrintToChat(client, "%s 近战武器发放失败，没扣你的点", BM_TAG);
			ReopenList(client, idx);
			return;
		}
	}
	else if (IsAmmoUpgrade(cls))
	{
		ent = ApplyAmmoUpgrade(client, cls);
		if (ent == -1)
		{
			PrintToChat(client, "%s 需要先拿一把主武器才能装弹药升级", BM_TAG);
			ReopenList(client, idx);
			return;
		}
		if (ent == -2)
		{
			PrintToChat(client, "%s 你的枪已经是这种弹药了，没扣点", BM_TAG);
			ReopenList(client, idx);
			return;
		}
	}
	else
	{
		ent = GivePlayerItem(client, cls);
		if (ent == -1 && StrEqual(cls, "upgrade_laser_sight"))
		{
			// 激光瞄准走引擎自己的 upgrade_add
			if (TryGiveLaserSight(client))
			{
				ent = GetPlayerWeaponSlot(client, 0);
			}
		}

		if (ent == -1)
		{
			PrintToChat(client, "%s 发放失败（可能背包已满），没扣你的点", BM_TAG);
			LogError("[BlackMarket] GivePlayerItem 失败: client=%L item=%s", client, cls);
			ReopenList(client, idx);
			return;
		}
	}

	g_iPoints[client] -= price;

	if (g_bCheat[client])
	{
		int target = g_cvCheatAmount.IntValue;
		if (g_iPoints[client] < target)
		{
			g_iPoints[client] = target;
		}
	}

	PrintToChat(client, "%s 买到 \x04%s\x01，花费 \x04%d\x01，剩余 \x04%d",
		BM_TAG, g_eShop[idx].name, price, g_iPoints[client]);
	PrintHintText(client, "黑市：%s  -%d", g_eShop[idx].name, price);
	PlayClientSound(client, "BlackMarket.Buy", "blackmarket/bm_buy.mp3");

	if (IsOnSale(idx))
	{
		PrintToChatAll("%s \x04%N\x01 抢走了特价商品 \x04%s\x01！", BM_TAG, client, g_eShop[idx].name);
	}

	ReopenList(client, idx);
}

int CountInCat(int cat)
{
	int n = 0;
	for (int i = 0; i < g_iShopCount; i++)
	{
		if (g_eShop[i].cat == cat)
		{
			n++;
		}
	}
	return n;
}


void ShowMyStats(int client)
{
	PrintToChat(client, "%s 补给点 \x04%d\x01   特感击杀 \x04%d\x01   连杀 \x04%d",
		BM_TAG, g_iPoints[client], g_iKills[client], g_iStreak[client]);

	if (g_bCheat[client])
	{
		PrintToChat(client, "%s 作弊模式：自动补给到 \x04%d\x01 点（\x04!cheat\x01 关闭）",
			BM_TAG, g_cvCheatAmount.IntValue);
	}

	PrintToChat(client, "%s 输入 \x04!shop\x01 打开商店，\x04!top\x01 看排行榜", BM_TAG);
}

/* ============================================================
 *  聊天命令
 * ============================================================ */

public Action Cmd_Points(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	PrintToChat(client, "%s 你当前有 \x04%d\x01 补给点（特感击杀 %d）",
		BM_TAG, g_iPoints[client], g_iKills[client]);
	return Plugin_Handled;
}

public Action Cmd_Top(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	if (!g_bDBReady)
	{
		PrintToChat(client, "%s 没有连上数据库，排行榜不可用", BM_TAG);
		return Plugin_Handled;
	}

	char query[256];
	Format(query, sizeof(query),
		"SELECT name, points FROM bm_players ORDER BY points DESC LIMIT 10");

	SQL_TQuery(g_hDB, OnTopLoaded, query, GetClientUserId(client));
	return Plugin_Handled;
}

/* ============================================================
 *  作弊命令（本地开服自用）
 * ============================================================ */

public Action Cmd_ZeroPoints(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	if (!g_cvCheatEnabled.BoolValue)
	{
		PrintToChat(client, "%s 服务器关掉了作弊命令", BM_TAG);
		return Plugin_Handled;
	}

	int before = g_iPoints[client];
	g_iPoints[client] = 0;

	PrintToChat(client, "%s 补给点已清零（原 \x04%d\x01 → \x040\x01）", BM_TAG, before);
	return Plugin_Handled;
}

public Action Cmd_SoundCheck(int client, int args)
{
	ReplyToCommand(client, "[BM] sm_bm_sounds = %d   precache buy=%s deny=%s",
		g_cvSounds.IntValue, g_bPrecBuy ? "Y" : "N", g_bPrecDeny ? "Y" : "N");
	CheckSoundFile(client, "sound/blackmarket/bm_buy.wav");
	CheckSoundFile(client, "sound/blackmarket/bm_deny.wav");
	return Plugin_Handled;
}

public Action Cmd_SoundTest(int client, int args)
{
	ReplyToCommand(client, "[BM] 开始三段对照测试……");
	g_iSndTestCount[client] = 0;
	CreateTimer(0.1, Timer_SndStage, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

public Action Timer_SndStage(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client < 1 || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	switch (g_iSndTestCount[client])
	{
		case 0:
		{
			PrintToChat(client, "%s 1/3 购买音 (soundscript · mp3)  v%s", BM_TAG, PLUGIN_VERSION);
			EmitSoundToClient(client, "BlackMarket.Buy");
		}
		case 1:
		{
			PrintToChat(client, "%s 2/3 失败音 (soundscript · mp3)", BM_TAG);
			EmitSoundToClient(client, "BlackMarket.Deny");
		}
		case 2:
		{
			PrintToChat(client, "%s 3/3 购买音 (play 命令 · mp3)", BM_TAG);
			ClientCommand(client, "play blackmarket/bm_buy.mp3");
		}
		default:
		{
			return Plugin_Stop;
		}
	}

	g_iSndTestCount[client]++;
	if (g_iSndTestCount[client] < 3)
	{
		CreateTimer(1.8, Timer_SndStage, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Stop;
}

void CheckSoundFile(int client, const char[] path)
{
	bool onDisk = FileExists(path);
	bool inVfs  = FileExists(path, true);
	int  size   = FileSize(path, true);

	ReplyToCommand(client, "[BM] %s  disk=%s engine=%s size=%d",
		path, onDisk ? "Y" : "N", inVfs ? "Y" : "N", size);
}

public Action Cmd_CheatAdd(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	if (!g_cvCheatEnabled.BoolValue)
	{
		PrintToChat(client, "%s 服务器关掉了作弊命令", BM_TAG);
		return Plugin_Handled;
	}

	if (args < 1)
	{
		PrintToChat(client, "%s 用法: !bmadd <数量>     清零用 !bmzero", BM_TAG);
		return Plugin_Handled;
	}

	char buf[32];
	GetCmdArg(1, buf, sizeof(buf));

	int amount = StringToInt(buf);
	if (amount == 0)
	{
		PrintToChat(client, "%s 数量得是非零整数", BM_TAG);
		return Plugin_Handled;
	}

	g_iPoints[client] += amount;
	if (g_iPoints[client] < 0)
	{
		g_iPoints[client] = 0;
	}

	if (amount > 0)
	{
		PrintToChat(client, "%s \x04+%d\x01 补给点，现有 \x04%d", BM_TAG, amount, g_iPoints[client]);
	}
	else
	{
		PrintToChat(client, "%s %d 补给点，现有 \x04%d", BM_TAG, amount, g_iPoints[client]);
	}

	return Plugin_Handled;
}

public Action Cmd_Cheat(int client, int args)
{
	if (!client || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}

	if (!g_cvCheatEnabled.BoolValue)
	{
		PrintToChat(client, "%s 服务器关掉了作弊命令", BM_TAG);
		return Plugin_Handled;
	}

	g_bCheat[client] = !g_bCheat[client];

	if (g_bCheat[client])
	{
		int target = g_cvCheatAmount.IntValue;
		if (g_iPoints[client] < target)
		{
			g_iPoints[client] = target;
		}
		PrintToChat(client, "%s \x04自动补给已开启\x01：买多少都自动补到 \x04%d\x01 点", BM_TAG, target);
		PrintHintText(client, "黑市：作弊模式 ON");
	}
	else
	{
		PrintToChat(client, "%s 自动补给已关闭，当前 \x04%d\x01 点", BM_TAG, g_iPoints[client]);
	}

	return Plugin_Handled;
}

public void OnTopLoaded(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	if (results == null || error[0])
	{
		PrintToChat(client, "%s 排行榜查询失败", BM_TAG);
		LogError("[BlackMarket] 排行榜查询失败: %s", error);
		return;
	}

	PrintToChat(client, "%s \x04==== 补给点排行榜 ====", BM_TAG);

	int rank = 1;
	while (results.FetchRow() && rank <= 10)
	{
		char nm[64];
		int  pts = results.FetchInt(1);
		results.FetchString(0, nm, sizeof(nm));
		PrintToChat(client, "%s \x04#%d\x01  %s  -  %d 点", BM_TAG, rank, nm, pts);
		rank++;
	}

	if (rank == 1)
	{
		PrintToChat(client, "%s 还没有任何记录", BM_TAG);
	}
}

/* ============================================================
 *  管理员
 * ============================================================ */

public Action Cmd_AdminGive(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "[BlackMarket] 用法: sm_bm_give <目标> <数量>");
		return Plugin_Handled;
	}

	char target[64];
	char num[16];
	GetCmdArg(1, target, sizeof(target));
	GetCmdArg(2, num, sizeof(num));

	int amount = StringToInt(num);
	if (amount == 0)
	{
		ReplyToCommand(client, "[BlackMarket] 数量必须是非零整数");
		return Plugin_Handled;
	}

	int victim = FindTarget(client, target, true, false);
	if (victim == -1)
	{
		ReplyToCommand(client, "[BlackMarket] 找不到目标: %s", target);
		return Plugin_Handled;
	}

	g_iPoints[victim] += amount;

	PrintToChat(victim, "%s 管理员给你发了 \x04%d\x01 补给点（现有 %d）", BM_TAG, amount, g_iPoints[victim]);
	ReplyToCommand(client, "[BlackMarket] 已给 %N 发放 %d 点", victim, amount);
	return Plugin_Handled;
}

public Action Cmd_AdminReset(int client, int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iPoints[i] = 0;
		g_iKills[i]  = 0;
		g_iStreak[i] = 0;
	}

	if (g_bDBReady)
	{
		SQL_TQuery(g_hDB, OnQueryDone, "DELETE FROM bm_players", 0);
	}

	ReplyToCommand(client, "[BlackMarket] 已清空所有人的补给点");
	PrintToChatAll("%s 管理员重置了所有人的补给点", BM_TAG);
	return Plugin_Handled;
}

/* ============================================================
 *  数据库
 * ============================================================ */

void ConnectDatabase()
{
	char err[256];
	g_hDB = SQL_Connect("storage-local", true, err, sizeof(err));

	if (g_hDB == null)
	{
		LogError("[BlackMarket] 数据库连接失败，降级为内存模式: %s", err);
		g_bDBReady = false;
		return;
	}

	char create[512];
	strcopy(create, sizeof(create), "CREATE TABLE IF NOT EXISTS bm_players (steamid TEXT PRIMARY KEY, name TEXT, points INTEGER DEFAULT 0, sp_kills INTEGER DEFAULT 0, updated INTEGER DEFAULT 0);");

	if (!SQL_FastQuery(g_hDB, create))
	{
		char e[256];
		SQL_GetError(g_hDB, e, sizeof(e));
		LogError("[BlackMarket] 建表失败: %s", e);
		g_bDBReady = false;
		return;
	}

	char create2[256];
	strcopy(create2, sizeof(create2), "CREATE TABLE IF NOT EXISTS bm_attrs (steamid TEXT PRIMARY KEY, bits INTEGER DEFAULT 0);");

	if (!SQL_FastQuery(g_hDB, create2))
	{
		char e2[256];
		SQL_GetError(g_hDB, e2, sizeof(e2));
		LogError("[BlackMarket] 建属性表失败: %s", e2);
	}

	g_bDBReady = true;
}

void LoadPlayer(int client)
{
	if (!g_bDBReady)
	{
		g_bLoaded[client] = true;    // 没有数据库就走内存模式
		return;
	}

	char sid[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sid, sizeof(sid), false))
	{
		g_bLoaded[client] = true;
		return;
	}

	char query[256];
	Format(query, sizeof(query),
		"SELECT name, points, sp_kills FROM bm_players WHERE steamid = '%s'", sid);

	SQL_TQuery(g_hDB, OnPlayerLoaded, query, GetClientUserId(client));
}

public void OnPlayerLoaded(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	if (results == null || error[0])
	{
		LogError("[BlackMarket] 读取玩家数据失败: %s", error);
		g_bLoaded[client] = true;
		return;
	}

	if (results.FetchRow())
	{
		g_iPoints[client] = results.FetchInt(1);
		g_iKills[client]  = results.FetchInt(2);
	}

	LoadAttrs(client);
}

void SavePlayer(int client)
{
	if (!g_bDBReady || client < 1 || client > MaxClients)
	{
		return;
	}

	char sid[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sid, sizeof(sid), false))
	{
		return;
	}
	if (sid[0] == '\0')
	{
		return;
	}

	char rawName[MAX_NAME_LENGTH];
	char escName[(MAX_NAME_LENGTH * 2) + 1];

	GetClientName(client, rawName, sizeof(rawName));
	SQL_EscapeString(g_hDB, rawName, escName, sizeof(escName));

	char query[512];
	Format(query, sizeof(query), "REPLACE INTO bm_players (steamid, name, points, sp_kills, updated) VALUES ('%s', '%s', %d, %d, %d)", sid, escName, g_iPoints[client], g_iKills[client], GetTime());

	SQL_TQuery(g_hDB, OnQueryDone, query, 0);

	char qattr[256];
	Format(qattr, sizeof(qattr), "REPLACE INTO bm_attrs (steamid, bits) VALUES ('%s', %d)", sid, EncodeAttrs(client));
	SQL_TQuery(g_hDB, OnQueryDone, qattr, 0);
}

public void OnQueryDone(Database db, DBResultSet results, const char[] error, any data)
{
	if (error[0])
	{
		LogError("[BlackMarket] SQL 执行失败: %s", error);
	}
}

/* ============================================================
 *  客户端生命周期
 * ============================================================ */

public void OnClientPutInServer(int client)
{
	g_iPoints[client]  = 0;
	g_iKills[client]   = 0;
	g_iStreak[client]  = 0;
	g_fLastKill[client] = 0.0;
	g_bLoaded[client]  = false;
	g_bCheat[client]   = false;

	for (int i = 0; i < ATTR_MAX; i++)
	{
		g_iAttr[client][i] = 0;
	}

	SDKHook(client, SDKHook_OnTakeDamage, OnPlayerDamage);
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	LoadPlayer(client);

	// 等客户端完全就绪再发 bind（引擎允许服务器代发 bind，但命令要用 "say !shop" 这种可执行写法）
	if (g_cvAutoBind.BoolValue)
	{
		CreateTimer(2.0, Timer_AutoBind, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_AutoBind(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	ClientCommand(client, "bind b \"say !shop\"");
	PrintToChat(client, "%s 已把 \x04B 键\x01 绑定为打开商店（聊天框 \x04!shop\x01 也可以用）", BM_TAG);
	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}
	SavePlayer(client);
}

/* ============================================================
 *  地图
 * ============================================================ */

public void OnMapStart()
{
	g_iSale[0] = -1;
	g_iSale[1] = -1;
	g_bChapterPaid = false;

	// 自定义音效必须预缓存，否则 EmitSound 会被引擎静默丢弃
	if (g_cvSounds.BoolValue)
	{
		g_bPrecBuy  = PrecacheSound("BlackMarket.Buy", true);
		g_bPrecDeny = PrecacheSound("BlackMarket.Deny", true);

		// 联机时让没订阅工坊包的客户端也能拿到文件
		AddFileToDownloadsTable("sound/blackmarket/bm_buy.wav");
		AddFileToDownloadsTable("sound/blackmarket/bm_deny.wav");
	}

	if (g_iShopCount >= 2)
	{
		g_iSale[0] = GetRandomInt(0, g_iShopCount - 1);

		do
		{
			g_iSale[1] = GetRandomInt(0, g_iShopCount - 1);
		}
		while (g_iSale[1] == g_iSale[0]);

		CreateTimer(12.0, Timer_SaleAnnounce, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_SaleAnnounce(Handle timer)
{
	if (g_iSale[0] < 0 || g_iSale[1] < 0)
	{
		return Plugin_Stop;
	}

	PrintToChatAll("%s 本图特价商品：\x04%s\x01、\x04%s\x01（五折）",
		BM_TAG, g_eShop[g_iSale[0]].name, g_eShop[g_iSale[1]].name);
	return Plugin_Stop;
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			SavePlayer(i);
		}
	}
}

public void OnPluginEnd()
{
	OnMapEnd();

	if (g_hDB != null)
	{
		delete g_hDB;
		g_hDB = null;
	}
}

/* ============================================================
 *  属性强化
 * ============================================================ */

enum
{
	ATTR_DMG = 0,
	ATTR_MELEE,
	ATTR_THROW,
	ATTR_RELOAD,
	ATTR_SPD
};

int AttrBasePrice(int attr)
{
	switch (attr)
	{
		case ATTR_DMG:    return 14;
		case ATTR_MELEE:  return 12;
		case ATTR_THROW:  return 12;
		case ATTR_RELOAD: return 16;
		case ATTR_SPD:    return 18;
	}
	return 10;
}

int AttrPrice(int attr, int curLevel)
{
	int mult = 1;
	if (curLevel == 1) mult = 2;
	else if (curLevel >= 2) mult = 3;

	float p = float(AttrBasePrice(attr) * mult) * g_cvPriceMult.FloatValue;
	int price = RoundToNearest(p);
	if (price < 1)
	{
		price = 1;
	}
	return price;
}

void AttrName(int attr, char[] buf, int maxlen)
{
	switch (attr)
	{
		case ATTR_DMG:    strcopy(buf, maxlen, "火力强化");
		case ATTR_MELEE:  strcopy(buf, maxlen, "近战强化");
		case ATTR_THROW:  strcopy(buf, maxlen, "投掷强化");
		case ATTR_RELOAD: strcopy(buf, maxlen, "换弹强化");
		case ATTR_SPD:    strcopy(buf, maxlen, "体能强化");
		default:          strcopy(buf, maxlen, "未知");
	}
}

void AttrEffectText(int attr, char[] buf, int maxlen)
{
	switch (attr)
	{
		case ATTR_DMG:
		{
			Format(buf, maxlen, "枪械伤害 +%d%%/级", RoundToNearest(g_cvDmgStep.FloatValue * 100.0));
		}
		case ATTR_MELEE:
		{
			Format(buf, maxlen, "近战伤害 +%d%%/级", RoundToNearest(g_cvMeleeStep.FloatValue * 100.0));
		}
		case ATTR_THROW:  strcopy(buf, maxlen, "投掷初速 +22%/级");
		case ATTR_RELOAD:
		{
			int pct = RoundToNearest(g_cvReloadStep.FloatValue * 100.0);
			Format(buf, maxlen, "换弹 -%d%%/级", pct);
		}
		case ATTR_SPD:
		{
			int pct = RoundToNearest(g_cvSpeedStep.FloatValue * 100.0);
			Format(buf, maxlen, "移动速度 +%d%%/级", pct);
		}
		default:          strcopy(buf, maxlen, "");
	}
}

public Action Cmd_Attr(int client, int args)
{
	if (!client || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue)
	{
		PrintToChat(client, "%s 属性系统没有开启", BM_TAG);
		return Plugin_Handled;
	}

	ShowAttrMenu(client);
	return Plugin_Handled;
}

void ShowAttrMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Attr);
	menu.SetTitle("属性强化 · 本局内有效\n补给点: %d", g_iPoints[client]);

	char info[8];
	char name[32];
	char eff[64];
	char text[192];

	for (int i = 0; i < ATTR_MAX; i++)
	{
		int lvl = g_iAttr[client][i];
		AttrName(i, name, sizeof(name));
		AttrEffectText(i, eff, sizeof(eff));
		Format(info, sizeof(info), "%d", i);

		if (lvl >= ATTR_LV_MAX)
		{
			Format(text, sizeof(text), "%s  Lv.%d/%d  [已满级]  %s", name, lvl, ATTR_LV_MAX, eff);
			menu.AddItem(info, text, ITEMDRAW_DISABLED);
		}
		else
		{
			Format(text, sizeof(text), "%s  Lv.%d -> %d  |  %d 点  |  %s",
				name, lvl, lvl + 1, AttrPrice(i, lvl), eff);
			menu.AddItem(info, text);
		}
	}

	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Attr(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(param2, info, sizeof(info));
			TryUpgradeAttr(param1, StringToInt(info));
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowMainMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void TryUpgradeAttr(int client, int attr)
{
	if (attr < 0 || attr >= ATTR_MAX)
	{
		return;
	}
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	int lvl = g_iAttr[client][attr];
	if (lvl >= ATTR_LV_MAX)
	{
		PrintToChat(client, "%s 这一项已经满级了", BM_TAG);
		ReopenMenu(client, -2);
		return;
	}

	int price = AttrPrice(attr, lvl);
	if (g_iPoints[client] < price)
	{
		PrintToChat(client, "%s 补给点不够：升级需要 \x04%d\x01，你有 %d", BM_TAG, price, g_iPoints[client]);
		PlayClientSound(client, "BlackMarket.Deny", "blackmarket/bm_deny.mp3");
		ReopenMenu(client, -2);
		return;
	}

	g_iPoints[client] -= price;
	g_iAttr[client][attr] = lvl + 1;

	if (g_bCheat[client])
	{
		int target = g_cvCheatAmount.IntValue;
		if (g_iPoints[client] < target)
		{
			g_iPoints[client] = target;
		}
	}

	char name[32];
	AttrName(attr, name, sizeof(name));

	PrintToChat(client, "%s \x04%s\x01 升到 Lv.%d，花费 %d，剩余 %d",
		BM_TAG, name, lvl + 1, price, g_iPoints[client]);
	PrintHintText(client, "属性：%s Lv.%d", name, lvl + 1);
	PlayClientSound(client, "BlackMarket.Buy", "blackmarket/bm_buy.mp3");

	ApplyAttrs(client);
	SaveAttrs(client);

	ReopenMenu(client, -2);
}

/* ---------- 测试面板（临时） ----------
 *  !test 打开。受 sm_bm_cheat_enabled 控制，正式发布前整段可以删掉。
 *  目前只有一项：撤销加点（把已买属性的点数原价退回，等级清零）。
 */

public Action Cmd_TestMenu(int client, int args)
{
	if (client == 0)
	{
		return Plugin_Handled;
	}

	if (!g_cvCheatEnabled.BoolValue)
	{
		PrintToChat(client, "%s 测试面板已关闭（把 sm_bm_cheat_enabled 设成 1 才能用）", BM_TAG);
		return Plugin_Handled;
	}

	ShowTestMenu(client);
	return Plugin_Handled;
}

void ShowTestMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Test);
	menu.SetTitle("黑市测试面板\n点数 %d ｜ 火力 %d / 近战 %d / 投掷 %d / 换弹 %d / 体能 %d",
		g_iPoints[client],
		g_iAttr[client][ATTR_DMG],
		g_iAttr[client][ATTR_MELEE],
		g_iAttr[client][ATTR_THROW],
		g_iAttr[client][ATTR_RELOAD],
		g_iAttr[client][ATTR_SPD]);

	menu.AddItem("refund", "撤销加点（按原价退还全部已花点数）");
	menu.AddItem("speed",  "速度 / 体能调试");
	menu.AddItem("dmg",    "伤害诊断（火力 / 近战）");
	menu.AddItem("killbots", "杀死所有人机队友");
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Test(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			if (StrEqual(info, "refund"))
			{
				int refund = RefundAllAttrs(param1);
				if (refund > 0)
				{
					PrintToChat(param1, "%s 已撤销加点，退还 \x04%d\x01 点，当前 \x04%d\x01 点",
						BM_TAG, refund, g_iPoints[param1]);
				}
				else
				{
					PrintToChat(param1, "%s 当前没有可撤销的加点（属性全是 0 级）", BM_TAG);
				}
				CreateTimer(0.1, Timer_ReopenTestMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
			}
			else if (StrEqual(info, "speed"))
			{
				ShowSpeedTestMenu(param1);
			}
			else if (StrEqual(info, "dmg"))
			{
				PrintDmgDiag(param1);
				CreateTimer(0.1, Timer_ReopenTestMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
			}
			else if (StrEqual(info, "killbots"))
			{
				KillBotTeammates(param1);
				CreateTimer(0.1, Timer_ReopenTestMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void KillBotTeammates(int client)
{
	int killed = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
		{
			ForcePlayerSuicide(i);
			killed++;
		}
	}

	PrintToChat(client, "%s 已处决 %d 个人机队友", BM_TAG, killed);
}

void ShowSpeedTestMenu(int client)
{
	Menu menu = new Menu(MenuHandler_TestSpeed);

	float lagged = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");

	menu.SetTitle("速度调试（只影响自己）\n体能 Lv.%d ｜ 当前倍率 %.2f ｜ 强制 %.0f",
		g_iAttr[client][ATTR_SPD], lagged, g_fSpeedForce[client]);

	menu.AddItem("diag", "打印诊断信息");
	menu.AddItem("f600", "强制移速 600");
	menu.AddItem("f440", "强制移速 440");
	menu.AddItem("f330", "强制移速 330");
	menu.AddItem("f0",   "关闭强制移速");
	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_TestSpeed(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			if (StrEqual(info, "diag"))
			{
				PrintSpeedDiag(param1);
			}
			else if (StrEqual(info, "f600"))
			{
				ApplySpeedForce(param1, 600.0);
			}
			else if (StrEqual(info, "f440"))
			{
				ApplySpeedForce(param1, 440.0);
			}
			else if (StrEqual(info, "f330"))
			{
				ApplySpeedForce(param1, 330.0);
			}
			else if (StrEqual(info, "f0"))
			{
				ApplySpeedForce(param1, 0.0);
			}

			CreateTimer(0.1, Timer_ReopenSpeedMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				ShowTestMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

public Action Timer_ReopenTestMenu(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		ShowTestMenu(client);
	}
	return Plugin_Stop;
}

public Action Timer_ReopenSpeedMenu(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client))
	{
		ShowSpeedTestMenu(client);
	}
	return Plugin_Stop;
}

// 把五项属性全清零，并按当初的售价把点数退回去
int RefundAllAttrs(int client)
{
	int refund = 0;

	for (int a = 0; a < ATTR_MAX; a++)
	{
		int lvl = g_iAttr[client][a];
		if (lvl > ATTR_LV_MAX)
		{
			lvl = ATTR_LV_MAX;
		}

		for (int i = 0; i < lvl; i++)
		{
			refund += AttrPrice(a, i);
		}

		g_iAttr[client][a] = 0;
	}

	g_iPoints[client] += refund;

	ApplyAttrs(client);
	SavePlayer(client);   // 点数和属性一起写库

	return refund;
}

/* ---------- 效果 ---------- */

#define SURVIVOR_BASE_SPEED 220.0

/* 体能强化（无依赖实现）。
 * 实测：写 m_flMaxspeed（datamap / send）在 L4D2 里不生效。
 * 改用 m_flLaggedMovementValue —— 移动速度倍率，L4D2 的速度类插件基本都用这个字段。
 * 已知副作用：倍率同时作用于跳跃，调高后跳跃手感会变。
 */
void SetPlayerSpeed(int client, float target)
{
	float mult = target / SURVIVOR_BASE_SPEED;

	if (HasEntProp(client, Prop_Send, "m_flLaggedMovementValue"))
	{
		SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", mult);
	}

	// 顺手也写一份 maxspeed，引擎若认这个字段也能生效
	SetEntPropFloat(client, Prop_Data, "m_flMaxspeed", target);
	if (HasEntProp(client, Prop_Send, "m_flMaxspeed"))
	{
		SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", target);
	}
}

void ApplyAttrs(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}

	int lvl = g_iAttr[client][ATTR_SPD];
	if (lvl > ATTR_LV_MAX)
	{
		lvl = ATTR_LV_MAX;
	}

	if (lvl <= 0)
	{
		SetPlayerSpeed(client, SURVIVOR_BASE_SPEED);
		return;
	}

	SetPlayerSpeed(client, SURVIVOR_BASE_SPEED * (1.0 + g_cvSpeedStep.FloatValue * float(lvl)));
}

// 每帧兜底：游戏把倍率改回 1.0 时补回来（只在“正常状态”下补，不覆盖肾上腺素等特殊状态）
void MaintainSpeedAttr()
{
	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue)
	{
		return;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || !IsPlayerAlive(i))
		{
			continue;
		}

		// 调试：只影响下命令的那个人
		if (g_fSpeedForce[i] > 1.0)
		{
			float wantForce = g_fSpeedForce[i] / SURVIVOR_BASE_SPEED;
			float curForce = GetEntPropFloat(i, Prop_Send, "m_flLaggedMovementValue");
			if (curForce < wantForce - 0.02 || curForce > wantForce + 0.02)
			{
				SetPlayerSpeed(i, g_fSpeedForce[i]);
			}
			continue;
		}

		int lvl = g_iAttr[i][ATTR_SPD];
		if (lvl <= 0)
		{
			continue;
		}
		if (lvl > ATTR_LV_MAX)
		{
			lvl = ATTR_LV_MAX;
		}

		float mult = 1.0 + g_cvSpeedStep.FloatValue * float(lvl);
		float cur = GetEntPropFloat(i, Prop_Send, "m_flLaggedMovementValue");

		// 只补“被游戏重置回 1.0”的情况；其它值（肾上腺素 1.3 等）不覆盖
		if (cur > 0.98 && cur < 1.02)
		{
			SetEntPropFloat(i, Prop_Send, "m_flLaggedMovementValue", mult);
			SetEntPropFloat(i, Prop_Data, "m_flMaxspeed", SURVIVOR_BASE_SPEED * mult);
			if (HasEntProp(i, Prop_Send, "m_flMaxspeed"))
			{
				SetEntPropFloat(i, Prop_Send, "m_flMaxspeed", SURVIVOR_BASE_SPEED * mult);
			}
		}
	}
}

void PrintSpeedDiag(int client)
{
	int lvl = g_iAttr[client][ATTR_SPD];
	float target = SURVIVOR_BASE_SPEED * (1.0 + g_cvSpeedStep.FloatValue * float(lvl));
	float lagged = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
	float maxspd = GetEntPropFloat(client, Prop_Data, "m_flMaxspeed");

	PrintToChat(client, "%s 诊断 v%s", BM_TAG, PLUGIN_VERSION);
	PrintToChat(client, "体能 Lv.%d ｜ step=%.2f 目标跑速=%.1f ｜ force=%.0f",
		lvl, g_cvSpeedStep.FloatValue, target, g_fSpeedForce[client]);
	PrintToChat(client, "当前 Lagged=%.2f ｜ Maxspeed=%.0f", lagged, maxspd);
}


void PrintDmgDiag(int client)
{
	PrintToChat(client, "%s 伤害诊断 v%s", BM_TAG, PLUGIN_VERSION);
	PrintToChat(client, "火力 Lv.%d ｜ 近战 Lv.%d ｜ 最近武器 %s",
		g_iAttr[client][ATTR_DMG], g_iAttr[client][ATTR_MELEE],
		g_sDmgWeapon[client][0] ? g_sDmgWeapon[client] : "（还没有记录）");
	PrintToChat(client, "伤害回调 %d 次 ｜ 实际加成 %d 次 ｜ 最近倍率 x%.2f",
		g_iDmgSeen[client], g_iDmgBoosted[client], g_fDmgMult[client]);
}

void ApplySpeedForce(int client, float value)
{
	g_fSpeedForce[client] = value;

	if (value > 1.0)
	{
		if (IsPlayerAlive(client))
		{
			SetPlayerSpeed(client, value);
		}
		PrintToChat(client, "%s 强制移速 = %.0f（只影响你自己）", BM_TAG, value);
		return;
	}

	int lvl = g_iAttr[client][ATTR_SPD];
	if (lvl > ATTR_LV_MAX)
	{
		lvl = ATTR_LV_MAX;
	}

	float normal = SURVIVOR_BASE_SPEED * (1.0 + g_cvSpeedStep.FloatValue * float(lvl));
	if (IsPlayerAlive(client))
	{
		SetPlayerSpeed(client, normal);
	}
	PrintToChat(client, "%s 已关闭强制移速，恢复为 %.0f", BM_TAG, normal);
}


public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	CreateTimer(0.2, Timer_ApplyAttrs, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ApplyAttrs(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0)
	{
		ApplyAttrs(client);
	}
	return Plugin_Stop;
}

/* ---------- 换弹强化 ----------
 *  参考实现：hardmod2 / l4d_powerups_rush.sp（tPoncho 的 fast reload 代码）
 *    https://github.com/spumer/hardmod2/blob/master/sources/l4d_powerups_rush.sp
 *
 *  旧写法只改 m_flNextPrimaryAttack —— 换弹结束时引擎会重新写这个值，所以等于没做。
 *  可用的做法是在 weapon_reload 当下同时改这几处：
 *    1. m_flPlaybackRate = 1/rate      让换弹动画本身加速
 *    2. m_flTimeWeaponIdle             武器空闲时间跟着提前
 *    3. m_flNextPrimaryAttack          武器可开火时间提前
 *    4. 玩家 m_flNextAttack            玩家动作时间提前
 *    5. 换弹结束后把 m_flPlaybackRate 还原成 1.0
 *  霰弹枪不是弹匣类（按发塞弹），走 CBaseShotgun 的
 *  m_reloadStartDuration / m_reloadInsertDuration / m_reloadEndDuration。
 */

// 调试信息：开了 sm_bm_debug 时同时打到聊天框和服务器控制台，方便实机验证
void DebugChat(int client, const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}

	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 3);

	if (client > 0)
	{
		PrintToChat(client, "%s [调试] %s", BM_TAG, buf);
	}
	PrintToServer("[BlackMarket] %s", buf);
}

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue)
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	int lvl = g_iAttr[client][ATTR_RELOAD];
	if (lvl <= 0)
	{
		return;
	}

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= 0 || !IsValidEntity(weapon))
	{
		return;
	}

	float rate = 1.0 - g_cvReloadStep.FloatValue * float(lvl);
	if (rate < g_cvReloadFloor.FloatValue)
	{
		rate = g_cvReloadFloor.FloatValue;
	}

	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));

	if (StrContains(cls, "shotgun") != -1)
	{
		BoostShotgunReload(client, weapon, cls, rate);
	}
	else
	{
		BoostMagazineReload(client, weapon, cls, rate);
	}
}

void BoostMagazineReload(int client, int weapon, const char[] cls, float rate)
{
	float now = GetGameTime();
	float npa = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
	float dur = npa - now;

	if (dur <= 0.05 || dur > 6.0)
	{
		DebugChat(client, "换弹加速跳过 %s：间隔异常 %.3f 秒", cls, dur);
		return;
	}

	// 榴弹发射器：在强化基础上再多缩一点
	if (StrContains(cls, "grenade_launcher") != -1)
	{
		rate *= g_cvGrenadeMult.FloatValue;
		if (rate < g_cvReloadFloor.FloatValue)
		{
			rate = g_cvReloadFloor.FloatValue;
		}
		DebugChat(client, "榴弹发射器额外加速：本发倍率 %.2f", rate);
	}

	float newEnd = now + dur * rate;

	bool hasPb   = HasEntProp(weapon, Prop_Send, "m_flPlaybackRate");
	bool hasIdle = HasEntProp(weapon, Prop_Send, "m_flTimeWeaponIdle");

	if (hasPb)
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", 1.0 / rate);
		SchedulePlaybackReset(client, weapon, dur * rate);
	}

	if (hasIdle)
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flTimeWeaponIdle", newEnd);
	}

	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", newEnd);
	SetEntPropFloat(client, Prop_Send, "m_flNextAttack", newEnd);

	// 同步给狙击拉栓的轮询：让那边把“这次写入”当成已知值，避免在换弹上再缩一次
	g_iBoltWeapon[client] = weapon;
	g_fBoltNext[client]   = newEnd;
	g_fReloadBusy[client] = newEnd;   // 换弹期间别让拉栓那条逻辑抢播放倍率

	// 动画对齐：把 viewmodel 的层起始时间往前推掉“省下来”的那段时间，
	// 否则客户端时间轴还是按原时长走，会出现整套换弹动画重播一遍的情况
	if (g_iViewModelO >= 0 && g_iVMStartTimeO >= 0)
	{
		float cut = dur * (1.0 - rate);
		float delay = dur * rate - 0.4;
		if (delay > 0.0)
		{
			DataPack dp = new DataPack();
			dp.WriteCell(GetClientUserId(client));
			dp.WriteFloat(now - cut);
			CreateTimer(delay, Timer_AlignViewModel, dp, TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);
		}
	}

	DebugChat(client, "换弹加速 %s：%.3fs -> %.3fs（rate %.2f, playbackRate=%s, idle=%s）",
		cls, dur, dur * rate, rate,
		hasPb ? "有" : "无", hasIdle ? "有" : "无");
}

// 把 viewmodel 的动画层起始时间往前挪，让客户端动画和加速后的服务端时间对得上
public Action Timer_AlignViewModel(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	float startTime = dp.ReadFloat();

	int client = GetClientOfUserId(userid);
	if (client <= 0 || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	int vm = GetEntDataEnt2(client, g_iViewModelO);
	if (vm <= 0 || !IsValidEntity(vm))
	{
		DebugChat(client, "换弹动画对齐跳过：拿不到 viewmodel");
		return Plugin_Stop;
	}

	SetEntDataFloat(vm, g_iVMStartTimeO, startTime, true);
	DebugChat(client, "换弹动画已对齐 viewmodel（start=%.3f）", startTime);

	return Plugin_Stop;
}

/* ---------- 狙击枪拉栓（射击间隔） ----------
 *  L4D2 的狙击枪每打一发都要等拉栓，这段时间就是 m_flNextPrimaryAttack 的间隔。
 *  做法参考 hardmod2 的 double-tap：每帧轮询，一旦发现间隔被引擎重新写大（= 刚开过枪），
 *  就按倍率缩短。必须记录“上次写入的值”，否则每帧都会再乘一次，越缩越短。
 */

// 需要缩短“每发间隔”的武器：狙击（拉栓）+ 散弹枪（泵动/上膛）
bool IsBoltWeapon(const char[] cls)
{
	return (StrContains(cls, "hunting_rifle") != -1
		|| StrContains(cls, "sniper") != -1
		|| StrContains(cls, "shotgun") != -1);
}

void RestoreWeaponPlayback(int weapon)
{
	if (weapon > 0 && IsValidEntity(weapon) && HasEntProp(weapon, Prop_Send, "m_flPlaybackRate"))
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", 1.0);
	}
}

public void OnGameFrame()
{
	MaintainSpeedAttr();

	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue || !g_cvSniperBolt.BoolValue)
	{
		return;
	}

	float now = GetGameTime();

	for (int i = 1; i <= MaxClients; i++)
	{
		int prev = g_iBoltWeapon[i];
		int weapon = -1;
		char cls[64];

		bool ok = (IsClientInGame(i) && !IsFakeClient(i) && IsPlayerAlive(i)
		           && g_iAttr[i][ATTR_RELOAD] > 0);

		if (ok)
		{
			weapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
			if (weapon <= 0 || !IsValidEntity(weapon))
			{
				ok = false;
			}
			else
			{
				GetEntityClassname(weapon, cls, sizeof(cls));
				if (!IsBoltWeapon(cls))
				{
					ok = false;
				}
			}
		}

		if (!ok)
		{
			RestoreWeaponPlayback(prev);
			g_iBoltWeapon[i] = 0;
			g_fBoltNext[i]   = 0.0;
			continue;
		}

		float rate = 1.0 - g_cvReloadStep.FloatValue * float(g_iAttr[i][ATTR_RELOAD]);
		if (rate < g_cvSniperFloor.FloatValue)
		{
			rate = g_cvSniperFloor.FloatValue;
		}

		// 换枪 / 刚拿起：把上一把的倍率还原，这一帧只记录，不改
		if (prev != weapon)
		{
			if (prev != 0)
			{
				RestoreWeaponPlayback(prev);
			}
			g_iBoltWeapon[i] = weapon;
			g_fBoltNext[i] = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
			continue;
		}

		// 拉栓动画：常驻倍速。先前“开火后那一刻才改倍率”会让动画中途变速，整套动作重播一遍
		// 注意：SendWeaponAnim 每次发动画都会把武器的 m_flPlaybackRate 重置成 1.0，
		// 所以这里改倍率必然发生在“动画已经开始之后”，引擎会把整段开火动画重发一次
		// （表现就是多发一个弹壳）。狙击默认关闭；散弹枪默认开启，否则泵动动画会卡住节奏。
		bool isShotgun = (StrContains(cls, "shotgun") != -1);
		bool wantFastAnim = isShotgun ? g_cvShotgunAnim.BoolValue : g_cvSniperAnim.BoolValue;

		if (now >= g_fReloadBusy[i] && HasEntProp(weapon, Prop_Send, "m_flPlaybackRate"))
		{
			if (wantFastAnim && rate < 1.0)
			{
				float desired = 1.0 / rate;
				float cur = GetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate");
				if (cur > desired + 0.01 || cur < desired - 0.01)
				{
					SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", desired);
					g_iPlaybackGen[i]++;   // 作废还挂着的倍率复位
				}
			}
			else if (GetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate") > 1.01)
			{
				RestoreWeaponPlayback(weapon);
			}
		}

		float npa = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
		if (npa <= g_fBoltNext[i] + 0.01)
		{
			continue;
		}

		float interval = npa - now;
		if (interval <= 0.0 || interval > 3.0)
		{
			g_fBoltNext[i] = npa;
			continue;
		}

		float newTime = now + interval * rate;
		g_fBoltNext[i] = newTime;

		SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", newTime);
		if (HasEntProp(weapon, Prop_Send, "m_flTimeWeaponIdle"))
		{
			SetEntPropFloat(weapon, Prop_Send, "m_flTimeWeaponIdle", newTime);
		}
		SetEntPropFloat(i, Prop_Send, "m_flNextAttack", newTime);

		DebugChat(i, "射击间隔 %s：%.3fs -> %.3fs（rate %.2f）", cls, interval, interval * rate, rate);
	}
}

void BoostShotgunReload(int client, int weapon, const char[] cls, float rate)
{
	if (!HasEntProp(weapon, Prop_Send, "m_reloadStartDuration"))
	{
		DebugChat(client, "霰弹枪加速不可用：%s 没有 m_reloadStartDuration", cls);
		return;
	}

	if (weapon <= 0 || weapon >= BM_MAX_ENT)
	{
		return;
	}

	// 第一次遇到这把枪时记下真实时长（不要硬编码，L4D2 里每把枪的值都不同）
	if (!g_bShotBase[weapon])
	{
		g_fShotBase[weapon][0] = GetEntPropFloat(weapon, Prop_Send, "m_reloadStartDuration");
		g_fShotBase[weapon][1] = GetEntPropFloat(weapon, Prop_Send, "m_reloadInsertDuration");
		g_fShotBase[weapon][2] = GetEntPropFloat(weapon, Prop_Send, "m_reloadEndDuration");
		g_bShotBase[weapon] = true;
	}

	SetEntPropFloat(weapon, Prop_Send, "m_reloadStartDuration",  g_fShotBase[weapon][0] * rate);
	SetEntPropFloat(weapon, Prop_Send, "m_reloadInsertDuration", g_fShotBase[weapon][1] * rate);
	SetEntPropFloat(weapon, Prop_Send, "m_reloadEndDuration",    g_fShotBase[weapon][2] * rate);

	if (HasEntProp(weapon, Prop_Send, "m_flPlaybackRate"))
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", 1.0 / rate);
	}

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(EntIndexToEntRef(weapon));
	CreateTimer(0.3, Timer_ShotgunReloadWatch, dp, TIMER_REPEAT | TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);

	// 换弹期间每 0.1 秒重写一次缩放后的时长：万一是游戏每塞一发就把属性重置了，这样能压住
	DataPack keep = new DataPack();
	keep.WriteCell(GetClientUserId(client));
	keep.WriteCell(EntIndexToEntRef(weapon));
	keep.WriteFloat(rate);
	g_iShotTicks[client] = 0;
	CreateTimer(0.1, Timer_ShotgunKeepBoost, keep, TIMER_REPEAT | TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);

	DebugChat(client, "霰弹枪加速 %s：start %.3f→%.3f  insert %.3f→%.3f  end %.3f→%.3f（rate %.2f）",
		cls,
		g_fShotBase[weapon][0], g_fShotBase[weapon][0] * rate,
		g_fShotBase[weapon][1], g_fShotBase[weapon][1] * rate,
		g_fShotBase[weapon][2], g_fShotBase[weapon][2] * rate,
		rate);
}

// 记下发一个“播放倍率复位”，带代号：如果期间又被新的倍率覆盖，这次复位就作废
void SchedulePlaybackReset(int client, int weapon, float delay)
{
	g_iPlaybackGen[client]++;

	DataPack dp = new DataPack();
	dp.WriteCell(GetClientUserId(client));
	dp.WriteCell(g_iPlaybackGen[client]);
	dp.WriteCell(EntIndexToEntRef(weapon));
	CreateTimer(delay, Timer_ResetPlayback, dp, TIMER_DATA_HNDL_CLOSE | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ResetPlayback(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	int gen    = dp.ReadCell();
	int entref = dp.ReadCell();

	if (client <= 0 || gen != g_iPlaybackGen[client])
	{
		return Plugin_Stop;
	}

	int weapon = EntRefToEntIndex(entref);
	if (weapon > 0 && IsValidEntity(weapon))
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", 1.0);
	}
	return Plugin_Stop;
}

public Action Timer_ShotgunKeepBoost(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int entref = dp.ReadCell();
	float rate = dp.ReadFloat();

	int client = GetClientOfUserId(userid);
	int weapon = EntRefToEntIndex(entref);

	if (client <= 0 || !IsClientInGame(client) || weapon <= 0 || !IsValidEntity(weapon))
	{
		return Plugin_Stop;
	}

	if (!HasEntProp(weapon, Prop_Send, "m_reloadState") || GetEntProp(weapon, Prop_Send, "m_reloadState") == 0)
	{
		return Plugin_Stop;
	}

	if (weapon < BM_MAX_ENT && g_bShotBase[weapon])
	{
		SetEntPropFloat(weapon, Prop_Send, "m_reloadStartDuration",  g_fShotBase[weapon][0] * rate);
		SetEntPropFloat(weapon, Prop_Send, "m_reloadInsertDuration", g_fShotBase[weapon][1] * rate);
		SetEntPropFloat(weapon, Prop_Send, "m_reloadEndDuration",    g_fShotBase[weapon][2] * rate);
	}

	// 调试：每 5 次（0.5 秒）报一次换弹状态和剩余时间
	g_iShotTicks[client]++;
	if (g_cvDebug.BoolValue && (g_iShotTicks[client] % 5) == 0)
	{
		float npa = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
		int clip = GetEntProp(weapon, Prop_Send, "m_iClip1");
		DebugChat(client, "换弹中 state=%d 弹匣=%d 剩余=%.3fs",
			GetEntProp(weapon, Prop_Send, "m_reloadState"), clip, npa - GetGameTime());
	}

	return Plugin_Continue;
}

public Action Timer_ShotgunReloadWatch(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int entref = dp.ReadCell();

	int client = GetClientOfUserId(userid);
	int weapon = EntRefToEntIndex(entref);

	if (client <= 0 || weapon <= 0 || !IsValidEntity(weapon) || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}

	// m_reloadState: 0 = 没在换弹，1/2 = 正在塞弹
	if (HasEntProp(weapon, Prop_Send, "m_reloadState") && GetEntProp(weapon, Prop_Send, "m_reloadState") != 0)
	{
		return Plugin_Continue;
	}

	if (HasEntProp(weapon, Prop_Send, "m_flPlaybackRate"))
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flPlaybackRate", 1.0);
	}

	float now = GetGameTime();
	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", now + 0.1);
	if (HasEntProp(weapon, Prop_Send, "m_flTimeWeaponIdle"))
	{
		SetEntPropFloat(weapon, Prop_Send, "m_flTimeWeaponIdle", now + 0.1);
	}
	SetEntPropFloat(client, Prop_Send, "m_flNextAttack", now + 0.1);

	DebugChat(client, "霰弹枪换弹结束，playbackRate 已还原");

	return Plugin_Stop;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// 普通僵尸是 infected；Witch 是 witch。特感 / Tank 走 OnClientPutInServer 里的玩家钩子。
	if (StrEqual(classname, "infected") || StrEqual(classname, "witch"))
	{
		SDKHook(entity, SDKHook_OnTakeDamage, OnInfectedDamage);
		return;
	}

	if (IsThrowableClass(classname))
	{
		if (entity > 0 && entity < BM_MAX_ENT)
		{
			g_bThrowBoosted[entity] = false;
			g_bThrowTracked[entity] = false;
			g_iThrowTicks[entity]   = 0;
			g_iThrowOwner[entity]   = 0;
		}
		CreateTimer(0.03, Timer_ThrowWatch, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	if (g_cvDebug.BoolValue && StrContains(classname, "projectile") != -1)
	{
		PrintToServer("[BlackMarket] 未识别的投射物实体: %s (ent %d)", classname, entity);
	}
}

bool IsThrowableClass(const char[] cls)
{
	if (StrContains(cls, "projectile") == -1)
	{
		return false;
	}
	if (StrContains(cls, "tank") != -1 || StrContains(cls, "spitter") != -1)
	{
		return false;
	}
	return true;
}

/* 先看 m_hOwnerEntity，不可信就按距离找最近的生还者（投掷物出膛时离手最近） */
int ResolveThrower(int ent)
{
	int owner = GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity");
	if (owner > 0 && owner <= MaxClients && IsClientInGame(owner))
	{
		return owner;
	}

	float pos[3];
	GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);

	int best = 0;
	float bestDist = 220.0;
	float eye[3];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
		{
			continue;
		}
		GetClientEyePosition(i, eye);
		float d = GetVectorDistance(eye, pos);
		if (d < bestDist)
		{
			bestDist = d;
			best = i;
		}
	}
	return best;
}

public Action Timer_ThrowWatch(Handle timer, any ref)
{
	int ent = EntRefToEntIndex(ref);
	if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent) || ent <= 0 || ent >= BM_MAX_ENT)
	{
		return Plugin_Stop;
	}
	if (g_bThrowBoosted[ent])
	{
		return Plugin_Stop;
	}

	g_iThrowTicks[ent]++;
	if (g_iThrowTicks[ent] > 90)      // 0.03 * 90 ≈ 2.7 秒还没出手就不管了
	{
		if (g_cvDebug.BoolValue)
		{
			PrintToServer("[BlackMarket] 投掷物 ent=%d 超时未出手", ent);
		}
		return Plugin_Stop;
	}

	// 投掷物还在手上时离手最近，趁这会儿把投掷者认准
	if (g_iThrowOwner[ent] <= 0)
	{
		int found = ResolveThrower(ent);
		if (found > 0)
		{
			g_iThrowOwner[ent] = found;
		}
	}

	int owner = g_iThrowOwner[ent];
	if (owner <= 0)
	{
		return Plugin_Continue;
	}

	int lvl = g_iAttr[owner][ATTR_THROW];
	if (lvl <= 0)
	{
		return Plugin_Stop;
	}

	float vel[3];
	GetEntPropVector(ent, Prop_Data, "m_vecVelocity", vel);
	float speed = GetVectorLength(vel);

	if (speed >= 100.0)
	{
		ScaleVector(vel, 1.0 + 0.22 * lvl);
		SetEntPropVector(ent, Prop_Data, "m_vecVelocity", vel);
		TeleportEntity(ent, NULL_VECTOR, NULL_VECTOR, vel);
		g_bThrowBoosted[ent] = true;

		if (g_cvDebug.BoolValue)
		{
			PrintToServer("[BlackMarket] 投掷物加速 ent=%d 玩家=%N Lv=%d -> %.1f",
				ent, owner, lvl, GetVectorLength(vel));
		}
		return Plugin_Stop;
	}

	// 速度属性还没写：用位移差分兜底（物理实体的 m_vecVelocity 可能一直为 0）
	float cur[3];
	GetEntPropVector(ent, Prop_Send, "m_vecOrigin", cur);

	if (g_bThrowTracked[ent])
	{
		float d[3];
		d[0] = (cur[0] - g_fThrowLast[ent][0]) / 0.03;
		d[1] = (cur[1] - g_fThrowLast[ent][1]) / 0.03;
		d[2] = (cur[2] - g_fThrowLast[ent][2]) / 0.03;

		if (GetVectorLength(d) > 100.0)
		{
			ScaleVector(d, 1.0 + 0.22 * lvl);
			TeleportEntity(ent, NULL_VECTOR, NULL_VECTOR, d);
			g_bThrowBoosted[ent] = true;

			if (g_cvDebug.BoolValue)
			{
				PrintToServer("[BlackMarket] 投掷物加速(位移法) ent=%d 玩家=%N Lv=%d -> %.1f",
					ent, owner, lvl, GetVectorLength(d));
			}
			return Plugin_Stop;
		}
	}

	g_fThrowLast[ent][0] = cur[0];
	g_fThrowLast[ent][1] = cur[1];
	g_fThrowLast[ent][2] = cur[2];
	g_bThrowTracked[ent] = true;

	if (g_cvDebug.BoolValue && (g_iThrowTicks[ent] % 10) == 0)
	{
		PrintToServer("[BlackMarket] 等待出手 ent=%d 玩家=%N Lv=%d tick=%d 速度=%.1f",
			ent, owner, lvl, g_iThrowTicks[ent], speed);
	}
	return Plugin_Continue;
}

public Action OnInfectedDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	return ApplyDamageBonus(attacker, damage);
}

public Action OnPlayerDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
	{
		return Plugin_Continue;
	}
	if (GetClientTeam(victim) != 3)      // 只强化打特感
	{
		return Plugin_Continue;
	}
	return ApplyDamageBonus(attacker, damage);
}

Action ApplyDamageBonus(int attacker, float &damage)
{
	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue)
	{
		return Plugin_Continue;
	}
	if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
	{
		return Plugin_Continue;
	}
	if (GetClientTeam(attacker) != 2 || IsFakeClient(attacker) || !g_bLoaded[attacker])
	{
		return Plugin_Continue;
	}

	char weapon[64];
	GetClientWeapon(attacker, weapon, sizeof(weapon));

	bool isMelee = (StrContains(weapon, "melee") != -1) || StrEqual(weapon, "weapon_chainsaw");

	// 诊断计数：能看到回调有没有进来、武器识别对不对
	g_iDmgSeen[attacker]++;
	strcopy(g_sDmgWeapon[attacker], sizeof(g_sDmgWeapon[]), weapon);

	if (isMelee)
	{
		int lvl = g_iAttr[attacker][ATTR_MELEE];
		if (lvl <= 0)
		{
			return Plugin_Continue;
		}
		g_fDmgMult[attacker] = 1.0 + g_cvMeleeStep.FloatValue * float(lvl);
	}
	else
	{
		int lvl = g_iAttr[attacker][ATTR_DMG];
		if (lvl <= 0)
		{
			return Plugin_Continue;
		}
		g_fDmgMult[attacker] = 1.0 + g_cvDmgStep.FloatValue * float(lvl);
	}

	damage *= g_fDmgMult[attacker];
	g_iDmgBoosted[attacker]++;

	return Plugin_Changed;
}

/* ---------- 存档 ---------- */

int EncodeAttrs(int client)
{
	int bits = 0;
	for (int i = 0; i < ATTR_MAX; i++)
	{
		bits |= ((g_iAttr[client][i] & 0x7) << (i * 3));
	}
	return bits;
}

void DecodeAttrs(int client, int bits)
{
	for (int i = 0; i < ATTR_MAX; i++)
	{
		g_iAttr[client][i] = (bits >> (i * 3)) & 0x7;
		if (g_iAttr[client][i] > ATTR_LV_MAX)
		{
			g_iAttr[client][i] = ATTR_LV_MAX;
		}
	}
}

void LoadAttrs(int client)
{
	if (!g_bDBReady)
	{
		FinishLoad(client);
		return;
	}

	char sid[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sid, sizeof(sid), false) || sid[0] == '\0')
	{
		FinishLoad(client);
		return;
	}

	char query[256];
	Format(query, sizeof(query), "SELECT bits FROM bm_attrs WHERE steamid = '%s'", sid);
	SQL_TQuery(g_hDB, OnAttrsLoaded, query, GetClientUserId(client));
}

public void OnAttrsLoaded(Database db, DBResultSet results, const char[] error, any data)
{
	int client = GetClientOfUserId(data);
	if (client < 1 || !IsClientInGame(client))
	{
		return;
	}

	if (results != null && !error[0] && results.FetchRow())
	{
		DecodeAttrs(client, results.FetchInt(0));
	}

	FinishLoad(client);
}

void FinishLoad(int client)
{
	g_bLoaded[client] = true;

	if (IsFakeClient(client))
	{
		return;
	}

	ApplyAttrs(client);

	if (g_iPoints[client] > 0)
	{
		PrintToChat(client, "%s 欢迎回来，你有 \x04%d\x01 补给点。\x04!shop\x01 商店 · \x04!attr\x01 属性",
			BM_TAG, g_iPoints[client]);
	}
	else
	{
		PrintToChat(client, "%s 欢迎新客人。击杀特感、救队友赚补给点，\x04!shop\x01 花钱 · \x04!attr\x01 强化",
			BM_TAG);
	}
}

void SaveAttrs(int client)
{
	if (!g_bDBReady)
	{
		return;
	}

	char sid[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, sid, sizeof(sid), false) || sid[0] == '\0')
	{
		return;
	}

	char query[256];
	Format(query, sizeof(query), "REPLACE INTO bm_attrs (steamid, bits) VALUES ('%s', %d)", sid, EncodeAttrs(client));
	SQL_TQuery(g_hDB, OnQueryDone, query, 0);
}

/* ---------- 一局结束：属性清零 ---------- */

public void Event_CampaignEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvCampaignReset.BoolValue)
	{
		return;
	}

	bool clearPoints = g_cvResetPoints.BoolValue;
	int affected = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}

		bool changed = false;

		for (int a = 0; a < ATTR_MAX; a++)
		{
			if (g_iAttr[i][a] > 0)
			{
				changed = true;
				g_iAttr[i][a] = 0;
			}
		}

		if (clearPoints && g_iPoints[i] > 0)
		{
			changed = true;
			g_iPoints[i] = 0;
		}

		ApplyAttrs(i);
		SavePlayer(i);

		if (changed)
		{
			affected++;
			PrintToChat(i, "%s \x04本局结束\x01，属性已清零%s，下一局从头开始",
				BM_TAG, clearPoints ? "、补给点也一起清了" : "");
		}
	}

	if (affected > 0)
	{
		PrintToServer("[BlackMarket] 一局结束，%d 名玩家的属性已重置", affected);
	}
}
