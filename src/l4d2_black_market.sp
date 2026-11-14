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

#define PLUGIN_VERSION  "1.3.7"
#define BM_TAG          "\x04[黑市]\x01"
#define MAX_SHOP_ITEMS  32
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
	CAT_WEAPON,         // 武器
	CAT_MAX
};

enum struct ShopEntry
{
	int  cat;
	int  price;         // 基础价（再乘 sm_bm_price_mult）
	char id[24];
	char name[48];
	char cls[48];
	char note[64];
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

	LoadShopTable();
	HookGameEvents();
	RegisterCommands();
	ConnectDatabase();

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
	RegConsoleCmd("sm_cheat",  Cmd_Cheat,    "开关自动补给点（花多少自动补满）");

	RegAdminCmd("sm_bm_give",     Cmd_AdminGive, ADMFLAG_CHEATS, "sm_bm_give <目标> <数量>  发补给点");
	RegAdminCmd("sm_bm_resetall", Cmd_AdminReset, ADMFLAG_ROOT,  "清空所有人的补给点存档");
}

/* ============================================================
 *  商品表
 * ============================================================ */

void AddShopItem(int cat, const char[] id, int price, const char[] name, const char[] cls, const char[] note)
{
	if (g_iShopCount >= MAX_SHOP_ITEMS)
	{
		return;
	}

	ShopEntry e;
	e.cat   = cat;
	e.price = price;
	strcopy(e.id,   sizeof(e.id),   id);
	strcopy(e.name, sizeof(e.name), name);
	strcopy(e.cls,  sizeof(e.cls),  cls);
	strcopy(e.note, sizeof(e.note), note);

	g_eShop[g_iShopCount] = e;
	g_iShopCount++;
}

void LoadShopTable()
{
	g_iShopCount = 0;

	/* 补给 */
	AddShopItem(CAT_SUPPLY, "medkit",   8,  "医疗包",     "weapon_first_aid_kit", "回满血，或救活队友");
	AddShopItem(CAT_SUPPLY, "pills",    4,  "止痛药",     "weapon_pain_pills",    "临时血量");
	AddShopItem(CAT_SUPPLY, "adren",    6,  "肾上腺素",   "weapon_adrenaline",    "加速 + 临时血量");
	AddShopItem(CAT_SUPPLY, "defib",    14, "电击器",     "weapon_defibrillator", "把死掉的队友拉起来");

	/* 投掷物 */
	AddShopItem(CAT_THROW,  "pipe",     4,  "管状炸弹",   "weapon_pipe_bomb",     "引开尸潮");
	AddShopItem(CAT_THROW,  "molotov",  4,  "燃烧瓶",     "weapon_molotov",       "封路清场");
	AddShopItem(CAT_THROW,  "vomit",    4,  "胆汁瓶",     "weapon_vomitjar",      "把僵尸糊一脸");

	/* 弹药升级 */
	AddShopItem(CAT_UPGRADE, "incen",   6,  "燃烧弹升级", "upgrade_ammo_incendiary", "子弹点燃目标");
	AddShopItem(CAT_UPGRADE, "explosive", 6, "高爆弹升级", "upgrade_ammo_explosive",  "子弹范围爆炸");
	AddShopItem(CAT_UPGRADE, "laser",   6,  "激光瞄准",   "upgrade_laser_sight",     "腰射也能准");

	/* 武器 */
	AddShopItem(CAT_WEAPON, "ak47",     10, "AK-47",      "weapon_rifle_ak47",    "高伤害步枪");
	AddShopItem(CAT_WEAPON, "m16",      8,  "M16 步枪",   "weapon_rifle",         "稳定连射");
	AddShopItem(CAT_WEAPON, "autoshot", 9,  "自动霰弹",   "weapon_autoshotgun",   "近距离清场");
	AddShopItem(CAT_WEAPON, "hunting",  8,  "猎枪",       "weapon_hunting_rifle", "远距离点杀");
	AddShopItem(CAT_WEAPON, "grenade",  16, "榴弹发射器", "weapon_grenade_launcher", "别对着墙打");
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

/* ============================================================
 *  积分发放
 * ============================================================ */

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

/* 提示音：音效文件由创意工坊配套包提供，没订阅的客户端听不到，但不影响任何功能 */
void PlayClientSound(int client, const char[] file)
{
	if (!g_cvSounds.BoolValue)
	{
		return;
	}
	EmitSoundToClient(client, file);
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

	char info[8];
	char text[128];

	Format(info, sizeof(info), "%d", CAT_SUPPLY);
	Format(text, sizeof(text), "补给  (%d 件)", CountInCat(CAT_SUPPLY));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "%d", CAT_THROW);
	Format(text, sizeof(text), "投掷物  (%d 件)", CountInCat(CAT_THROW));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "%d", CAT_UPGRADE);
	Format(text, sizeof(text), "弹药升级  (%d 件)", CountInCat(CAT_UPGRADE));
	menu.AddItem(info, text);

	Format(info, sizeof(info), "%d", CAT_WEAPON);
	Format(text, sizeof(text), "武器  (%d 件)", CountInCat(CAT_WEAPON));
	menu.AddItem(info, text);

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

			int cat = StringToInt(info);
			if (cat >= 0 && cat < CAT_MAX)
			{
				ShowCategoryMenu(param1, cat);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	return 0;
}

void ShowCategoryMenu(int client, int cat)
{
	Menu menu = new Menu(MenuHandler_Category);
	menu.SetTitle("%s\n补给点: %d", CatName(cat), g_iPoints[client]);
	menu.ExitBackButton = true;

	char info[8];
	char text[160];

	for (int i = 0; i < g_iShopCount; i++)
	{
		if (g_eShop[i].cat != cat)
		{
			continue;
		}

		Format(info, sizeof(info), "%d", i);

		int price = GetPrice(i);
		if (IsOnSale(i))
		{
			Format(text, sizeof(text), "[特价] %s  %d 点  -  %s", g_eShop[i].name, price, g_eShop[i].note);
		}
		else
		{
			Format(text, sizeof(text), "%s  %d 点  -  %s", g_eShop[i].name, price, g_eShop[i].note);
		}

		menu.AddItem(info, text);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Category(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));
			TryBuy(param1, StringToInt(info));
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
		ShowCategoryMenu(client, cat);
	}
	return Plugin_Stop;
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
		PlayClientSound(client, "blackmarket/bm_deny.wav");
		ReopenMenu(client, -1);
		return;
	}

	if (!IsPlayerAlive(client))
	{
		PrintToChat(client, "%s 死了买不了东西，先让队友把你拉起来", BM_TAG);
		ReopenMenu(client, -1);
		return;
	}

	char cls[48];
	strcopy(cls, sizeof(cls), g_eShop[idx].cls);

	int ent = GivePlayerItem(client, cls);
	if (ent == -1)
	{
		PrintToChat(client, "%s 发放失败（可能背包已满），没扣你的点", BM_TAG);
		LogError("[BlackMarket] GivePlayerItem 失败: client=%L item=%s", client, cls);
		ReopenMenu(client, -1);
		return;
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
	PlayClientSound(client, "blackmarket/bm_buy.wav");

	if (IsOnSale(idx))
	{
		PrintToChatAll("%s \x04%N\x01 抢走了特价商品 \x04%s\x01！", BM_TAG, client, g_eShop[idx].name);
	}

	ReopenMenu(client, g_eShop[idx].cat);
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

char[] CatName(int cat)
{
	static char buf[32];
	switch (cat)
	{
		case CAT_SUPPLY:  strcopy(buf, sizeof(buf), "补给");
		case CAT_THROW:   strcopy(buf, sizeof(buf), "投掷物");
		case CAT_UPGRADE: strcopy(buf, sizeof(buf), "弹药升级");
		default:          strcopy(buf, sizeof(buf), "武器");
	}
	return buf;
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
	ReplyToCommand(client, "[BM] sm_bm_sounds = %d", g_cvSounds.IntValue);
	CheckSoundFile(client, "sound/blackmarket/bm_buy.wav");
	CheckSoundFile(client, "sound/blackmarket/bm_deny.wav");
	return Plugin_Handled;
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
		PrecacheSound("blackmarket/bm_buy.wav", true);
		PrecacheSound("blackmarket/bm_deny.wav", true);
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
		case ATTR_DMG:    strcopy(buf, maxlen, "枪械伤害 +8%/级");
		case ATTR_MELEE:  strcopy(buf, maxlen, "近战伤害 +15%/级");
		case ATTR_THROW:  strcopy(buf, maxlen, "投掷初速 +22%/级");
		case ATTR_RELOAD: strcopy(buf, maxlen, "换弹时间 -12%/级");
		case ATTR_SPD:    strcopy(buf, maxlen, "移动速度 +5%/级");
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
		PlayClientSound(client, "blackmarket/bm_deny.wav");
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
	PlayClientSound(client, "blackmarket/bm_buy.wav");

	ApplyAttrs(client);
	SaveAttrs(client);

	ReopenMenu(client, -2);
}

/* ---------- 效果 ---------- */

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

	SetEntPropFloat(client, Prop_Send, "m_flMaxspeed", 220.0 * (1.0 + 0.05 * lvl));
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

public void Event_WeaponReload(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvAttrs.BoolValue || !g_cvEnabled.BoolValue)
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
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

	float now = GetGameTime();
	float npa = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
	if (npa <= now)
	{
		return;
	}

	float factor = 1.0 - 0.12 * lvl;
	if (factor < 0.5)
	{
		factor = 0.5;
	}

	SetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack", now + (npa - now) * factor);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "infected"))
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

	if (isMelee)
	{
		int lvl = g_iAttr[attacker][ATTR_MELEE];
		if (lvl <= 0)
		{
			return Plugin_Continue;
		}
		damage *= (1.0 + 0.15 * lvl);
		return Plugin_Changed;
	}

	int lvl = g_iAttr[attacker][ATTR_DMG];
	if (lvl <= 0)
	{
		return Plugin_Continue;
	}
	damage *= (1.0 + 0.08 * lvl);
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
