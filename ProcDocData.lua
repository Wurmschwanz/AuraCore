-- Original ProcDoc 2.6 proc database adapted only for the AuraCore namespace.
-- Buff names, icon filters, artwork, styles and action durations are kept 1:1.

AuraCoreProcDocData = {
  buffs = {
    WARLOCK = {
      ["shadow trance"] = { id="shadow_trance", name="Shadow Trance", icon="Interface\\Icons\\Spell_Shadow_Twilight", texture="WarlockShadowTrance.tga", style="SIDES", dual=true },
      ["nightfall"] = { id="shadow_trance", name="Shadow Trance", icon="Interface\\Icons\\Spell_Shadow_Twilight", texture="WarlockShadowTrance.tga", style="SIDES", dual=true },
    },
    MAGE = {
      ["clearcasting"] = { name="Clearcasting", icon="Interface\\Icons\\Spell_Shadow_ManaBurn", texture="DruidClearcasting.tga", style="TOP" },
      ["netherwind focus"] = { name="Netherwind Focus", icon="Interface\\Icons\\Spell_Shadow_Teleport", texture="MageT2.tga", style="SIDES2", dual=true },
      ["temporal convergence"] = { name="Temporal Convergence", icon="Interface\\Icons\\Spell_Nature_StormReach", texture="MageTemporalConvergence.tga", style="SIDES2", dual=true },
      ["flash freeze"] = { name="Flash Freeze", icon="Interface\\Icons\\Spell_Fire_FrostResistanceTotem", texture="MageFlashFreeze.tga", style="SIDES", dual=true },
      ["arcane rupture"] = { name="Arcane Rupture", icon="Interface\\Icons\\Spell_Arcane_Blast", texture="MageArcaneRupture.tga", style="SIDES", dual=true },
      ["hot streak"] = { id="hot_streak", name="Hot Streak", special="HOT_STREAK" },
    },
    DRUID = {
      ["clearcasting"] = { name="Clearcasting", icon="Interface\\Icons\\Spell_Shadow_ManaBurn", texture="DruidClearcasting.tga", style="TOP" },
      ["nature's grace"] = { name="Nature's Grace", icon="Interface\\Icons\\Spell_Nature_NaturesBlessing", texture="DruidNaturesGrace.tga", style="SIDES", dual=true },
      ["tiger's fury"] = { name="Tiger's Fury", icon="Interface\\Icons\\Ability_Mount_JungleTiger", texture="HunterMongooseBite.tga", style="SIDES2", dual=true },
      ["astral boon"] = { name="Astral Boon", icon="Interface\\Icons\\Spell_Arcane_StarFire", texture="DruidAstralBoon.tga", style="TOP2" },
      ["natural boon"] = { name="Natural Boon", icon="Interface\\Icons\\Spell_Nature_AbolishMagic", texture="DruidNaturalBoon.tga", style="TOP2" },
      ["arcane eclipse"] = { name="Arcane Eclipse", icon="Interface\\Icons\\Spell_Nature_WispSplode", texture="DruidArcaneEclipse.tga", style="SIDES2", dual=true },
      ["nature eclipse"] = { name="Nature Eclipse", icon="Interface\\Icons\\Spell_Nature_AbolishMagic", texture="DruidNatureEclipse.tga", style="SIDES2", dual=true },
    },
    SHAMAN = {
      ["clearcasting"] = { name="Clearcasting", icon="Interface\\Icons\\Spell_Shadow_ManaBurn", texture="DruidClearcasting.tga", style="TOP" },
      ["nature's swiftness"] = { name="Nature's Swiftness", icon="Interface\\Icons\\Spell_Nature_RavenForm", texture="DruidNaturesGrace.tga", style="SIDES", dual=true },
      ["stormstrike"] = { name="Stormstrike", icon="Interface\\Icons\\Ability_Shaman_StormStrike", texture="ShamanStormstrike.tga", style="TOP2" },
      ["flurry"] = { name="Flurry", icon="Interface\\Icons\\Ability_GhoulFrenzy", texture="HunterMongooseBite.tga", style="SIDES2", dual=true },
    },
    HUNTER = {
      ["quick shots"] = { name="Quick Shots", icon="Interface\\Icons\\Ability_Warrior_InnerRage", texture="HunterQuickShots.tga", style="SIDES2", dual=true },
      ["lock and load"] = { name="Lock and Load", texture="lock_and_load.blp", style="TOP2" },
      ["explosive ammunition"] = { id="explosive_ammunition", name="Explosive Ammunition", texture="impact.blp", style="TOP" },
      ["poisonous ammunition"] = { id="poisonous_ammunition", name="Poisonous Ammunition", texture="DruidNaturesGrace.tga", style="TOP_ROTATED" },
      ["enchanted ammunition"] = { id="enchanted_ammunition", name="Enchanted Ammunition", texture="serendipity.blp", style="TOP" },
    },
    WARRIOR = {
      ["enrage"] = { name="Enrage", icon="Interface\\Icons\\Spell_Shadow_UnholyFrenzy", texture="WarriorEnrage.tga", style="SIDES", dual=true },
    },
    PRIEST = {
      ["resurgence"] = { name="Resurgence", icon="Interface\\Icons\\Spell_Holy_MindVision", texture="PriestResurgence.tga", style="SIDES", dual=true },
      ["enlightened"] = { name="Enlightened", icon="Interface\\Icons\\Spell_Holy_PowerInfusion", texture="PriestEnlightened.tga", style="TOP" },
      ["searing light"] = { name="Searing Light", icon="Interface\\Icons\\Spell_Holy_SearingLightPriest", texture="PriestSearingLight.tga", style="SIDES2", dual=true },
      ["shadow veil"] = { name="Shadow Veil", icon="Interface\\Icons\\Spell_Shadow_GatherShadows", texture="PriestShadowVeil.tga", style="SIDES", dual=true },
      ["spell blasting"] = { name="Spell Blasting", icon="Interface\\Icons\\Spell_Lightning_LightningBolt01", texture="PriestSpellBlasting.tga", style="TOP2" },
    },
    PALADIN = {
      ["daybreak"] = { name="Daybreak", icon="Interface\\Icons\\Spell_Holy_AuraMastery", texture="PaladinDaybreak.tga", style="TOP" },
      ["zealous defence"] = { name="Zealous Defence", texture="Grand_Crusader.tga", style="SIDES2", dual=true },
    },
    ROGUE = {
      ["remorseless"] = { name="Remorseless", icon="Interface\\Icons\\Ability_FiegnDead", texture="RogueRemorseless.tga", style="SIDES", dual=true },
      ["tricks of the trade"] = { name="Tricks of the Trade", icon="Interface\\Icons\\INV_Misc_Key_03", texture="RogueTricksoftheTrade.tga", style="TOP" },
    },
  },
  actions = {
    ROGUE = {
      { id="action_riposte", name="Riposte", spellName="Riposte", actionTexture="Interface\\Icons\\Ability_Warrior_Challange", texture="RogueRiposte.tga", style="SIDES", dual=true },
      { id="action_surprise_attack", name="Surprise Attack", spellName="Surprise Attack", actionTexture="Interface\\Icons\\Ability_Rogue_SurpriseAttack", texture="RogueSuddenDeath.tga", style="SIDES2", dual=true },
    },
    WARRIOR = {
      { id="action_overpower", name="Overpower", spellName="Overpower", actionTexture="Interface\\Icons\\Ability_MeleeDamage", texture="WarriorOverpower.tga", style="TOP" },
      { id="action_execute", name="Execute", spellName="Execute", actionTexture="Interface\\Icons\\inv_sword_48", texture="WarriorExecute.tga", style="TOP2" },
      { id="action_counterattack", name="Counterattack", spellName="Counterattack", actionTexture="Interface\\Icons\\Ability_Warrior_Riposte", texture="WarriorCounterattack.tga", style="LEFT" },
      { id="action_revenge", name="Revenge", spellName="Revenge", actionTexture="Interface\\Icons\\Ability_Warrior_Revenge", texture="WarriorRevenge.tga", style="RIGHT" },
    },
    MAGE = {
      { id="action_arcane_surge", name="Arcane Surge", spellName="Arcane Surge", actionTexture="Interface\\Icons\\INV_Enchant_EssenceMysticalLarge", texture="MageArcaneSurge.tga", style="TOP2" },
    },
    HUNTER = {
      { id="action_lacerate", name="Lacerate", spellName="Lacerate", actionTexture="Interface\\Icons\\Spell_Lacerate_1c", texture="HunterMongooseBite.tga", style="SIDES", dual=true },
      { id="action_kill_command", name="Kill Command", spellName="Kill Command", actionTexture="Interface\\Icons\\ability_hunter_killcommand", texture="HunterBaitedShot.tga", style="TOP", checkSpellbookCooldown=true },
    },
    PALADIN = {
      { id="action_hammer_of_wrath", name="Hammer of Wrath", spellName="Hammer of Wrath", actionTexture="Interface\\Icons\\Ability_Thunderclap", texture="PaladinHammer.tga", style="SIDES", dual=true },
      { id="action_judgement", name="Judgement", spellName="Judgement", texture="PaladinJudgement.tga", style="RIGHT", useSpellbook=true },
      { id="action_hammer_of_justice", name="Hammer of Justice", spellName="Hammer of Justice", texture="PaladinJustice.tga", style="LEFT", useSpellbook=true },
    },
  },
  durations = {
    action_overpower=5, action_riposte=5, action_counterattack=5,
    action_revenge=5, action_surprise_attack=5, action_arcane_surge=4,
    action_lacerate=4, action_kill_command=4,
  }
}
