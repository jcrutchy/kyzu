unit kyzu_types;

{$mode objfpc}{$H+}

interface

uses
  kyzu_pathfinding;


// All former first-pass tuning constants (Balance.BaseSpeed, growth/upkeep
// costs, combat ranges, veterancy thresholds, etc.) now live in the
// Balance global (TGameBalance, loaded from game_balance.json) rather
// than as compile-time const values here - see the type's own comment
// for what stayed in code vs what moved to config.

type
  TUnit = record
    ID: string;
    Owner: string;      // faction/player id, '' = unowned
    UnitType: string;   // key into UnitDefs - see TUnitDef below
    GX, GY: Double; // fractional grid position, for smooth interpolated reporting
    Path: TGridPath;
    PathIndex: Integer; // index of the path node the unit is currently departing from
    HP: Integer;    // current hit points, initialized from UnitDefs[UnitType].MaxHP at spawn
    XP: Integer;     // combat experience - see Balance.VeterancyXPPerHit/Balance.VeterancyMaxLevel
    Level: Integer;  // 0 = green, up to Balance.VeterancyMaxLevel - boosts effective Attack/MaxHP
  end;

  // Static resource nodes - placed once from resource_nodes.json at
  // startup, never moved, only depleted. GX/GY are cached grid
  // coordinates computed once at load, so HandleCollect's distance
  // check against a moving unit doesn't repeat the lon/lat conversion
  // on every call.
  TResourceNode = record
    ID: string;
    ResourceType: string;
    Lon, Lat: Double;
    GX, GY: Double;
    Amount: Integer;
  end;

  // Cities are stationary, cell-snapped population centers seeded either
  // from cities.json at startup or founded live via game.cmd.found_city.
  // Population is the sole driver of a city's development footprint -
  // see RecomputeDevelopment.
  TCity = record
    ID: string;
    Owner: string;
    GX, GY: Integer;
    Population: Integer;
    LastGrowthTick: Int64;
    LastUpkeepTick: Int64; // separate clock from LastGrowthTick - see ProcessCityUpkeep
  end;

  // A built connection between two cities - path is computed once via
  // the same A* used for unit movement, then cached and reused as a
  // linear development source. Roads never move and are never removed
  // once built (no despawn/demolish command exists yet).
  TRoad = record
    ID: string;
    FromCityID, ToCityID: string;
    Owner: string;
    Path: TGridPath;
  end;

  // Quantized development intensity for one cell, carrying its own GX/GY
  // so callers never need to parse them back out of a "gx,gy" string key.
  TDensityCell = record
    GX, GY: Integer;
    Level: Byte; // 0..255
  end;

  // A unit type's gameplay-affecting stats, keyed by the free-form
  // UnitType string on TUnit. Loaded once from unit_types.json into a
  // static registry (UnitDefs) - not per-unit-instance data, since every
  // unit of a given type shares the same def. An unrecognized or absent
  // UnitType falls back to DefaultUnitDef (see GetUnitDef), which
  // preserves the pre-this-change behavior (any speed, can found, can
  // collect) so existing spawned units and old event logs keep working
  // unchanged.
  TUnitDef = record
    TypeID: string;
    DisplayName: string;
    SpeedMultiplier: Double;
    CanFoundCity: Boolean;
    CanCollect: Boolean;
    CollectMultiplier: Double;
    MaxHP: Integer;
    // 0 = this type cannot initiate an attack at all (the common case -
    // settlers/workers/scouts are non-combatants). Any unit, combat-
    // capable or not, can still be damaged/killed BY an attack; Attack
    // only gates who can throw the first punch.
    Attack: Integer;
    // '' = spawnable by anyone regardless of research (matches every
    // pre-tech unit type exactly). Non-empty = the spawning faction must
    // have this TechID in ResearchedTech first - see HandleSpawn. Deliberately
    // NOT enforced for Owner = '' (unowned/free-for-all spawns): there is
    // no faction to have researched anything against, same free-for-all
    // carve-out HandleMove/HandleDespawn already give unowned units.
    RequiresTech: string;
  end;

  // One line of a resource cost - "5 wood", "2 stone". Growth and
  // upkeep costs are both just lists of these rather than fixed
  // wood/stone fields, so a NEW resource type (anything seeded in
  // resource_nodes.json) can be made part of either cost purely by
  // editing game_balance.json - no code change, no recompile.
  TResourceCost = record
    ResourceType: string;
    Amount: Integer;
  end;
  TResourceCostList = array of TResourceCost;

  // One entry in tech.json - a researchable upgrade, gated behind its own
  // prerequisite techs and a resource cost, that unlocks new unit types
  // once completed. Loaded once into TechDefs at startup, same tolerant
  // pattern as UnitDefs; TechOrder preserves load order separately since
  // TDictionary enumeration order isn't something to rely on for "walk
  // techs in a sensible order" (used by RunAI's research picker).
  TTechDef = record
    TechID: string;
    DisplayName: string;
    Prerequisites: array of string;
    Cost: TResourceCostList;
    ResearchTicks: Integer;
  end;

  // A faction's in-flight research - one at a time per faction (see
  // ResearchInProgress, keyed by owner). StartTick resets to 0 alongside
  // Tick on every restart - see ReplayEventLog's 'research_started'
  // branch for why that's the same precedent as city clocks.
  TResearchInProgress = record
    TechID: string;
    StartTick: Int64;
  end;

  // Every first-pass tuning number in the game, loaded once at startup
  // from game_balance.json (see LoadGameBalance) with defaults that
  // exactly match what used to be hardcoded const values - editing the
  // JSON and restarting the server is now how you rebalance the game,
  // not editing this source file. What's deliberately NOT in here: the
  // actual mechanics (why upkeep runs on its own clock, how damage is
  // computed, the density falloff shape) - those are relationships
  // between numbers, not the numbers themselves, and turning THOSE
  // into data would mean building a small rules/expression engine,
  // not a config file. This only externalizes the inputs to formulas
  // that stay in code.
  TGameBalance = record
    BaseSpeed: Double;
    CollectRadiusCells: Double;
    CollectAmountPerAction: Integer;

    CityInitialPopulation: Integer;
    CityGrowthAmount: Integer;
    CityGrowthTicks: Integer;
    CityMaxPopulation: Integer;
    CityGrowthCost: TResourceCostList;

    DevelopmentRadiusCells: Double;
    DevelopmentMinRadiusCells: Double;
    DevelopmentUpdateTicks: Integer;
    RoadDevelopmentRadiusCells: Integer; // used as a raw FOR-loop bound (see RecomputeDevelopment) - must stay a whole number of cells, unlike the other *Cells fields which are fractional distance thresholds
    RoadDevelopmentPeak: Double;
    DevelopmentBroadcastThreshold: Integer;

    AttackRangeCells: Double;
    SiegeDamagePerAttack: Integer;
    CityCaptureResetPopulation: Integer;

    CityUpkeepTicks: Integer;
    CityUpkeepCost: TResourceCostList;
    CityDecayAmount: Integer;

    AiFactionName: string;
    AiTickInterval: Integer;
    AiTargetWorkerCount: Integer;
    // Expansion: how many settlers the AI keeps in flight at once, and
    // where it's willing to found. AiExpansionSearchRadiusCells bounds
    // the search around each AI-owned city; AiExpansionMinCityDistanceCells
    // is the minimum distance a candidate site must keep from EVERY
    // existing city (any owner) so the AI doesn't found on top of
    // someone else's back yard.
    AiTargetSettlerCount: Integer;
    AiExpansionSearchRadiusCells: Double;
    AiExpansionMinCityDistanceCells: Double;
    // Military: how many soldiers the AI keeps up, and how far a soldier
    // will proactively range from its spawn city looking for a target
    // before giving up and heading home to garrison.
    AiTargetSoldierCount: Integer;
    AiAggressionRangeCells: Double;
    // Research: whether the AI ever starts research at all. Off by
    // default (False) in DefaultGameBalance so an existing deployment
    // with no ai_research_enabled key in game_balance.json sees no
    // behavior change until the operator opts in.
    AiResearchEnabled: Boolean;

    VeterancyXPPerHit: Integer;
    VeterancyXPPerLevel: Integer;
    VeterancyMaxLevel: Integer;
    VeterancyAttackBonusPerLevel: Integer;
    VeterancyHPBonusPerLevel: Integer;
  end;

  // One entry in ai_factions.json - a single AI-controlled faction's
  // identity plus its own copy of every knob RunAI reads. Letting each
  // faction carry its own numbers (rather than RunAI reaching for the
  // single shared Balance.Ai* fields directly) is what makes multiple
  // AI factions with different "personalities" possible - one entry
  // tuned aggressive (high soldier count, wide aggression range), one
  // tuned as a builder (more settlers/workers, research always on),
  // etc, all from JSON with no code change. See LoadAiFactionConfigs
  // for how a faction entry inherits from Balance.Ai* for any field it
  // doesn't specify.
  TAiFactionConfig = record
    FactionName: string;
    TickInterval: Integer;
    TargetWorkerCount: Integer;
    TargetSettlerCount: Integer;
    ExpansionSearchRadiusCells: Double;
    ExpansionMinCityDistanceCells: Double;
    TargetSoldierCount: Integer;
    AggressionRangeCells: Double;
    ResearchEnabled: Boolean;
    // This faction's position in AiFactionConfigs, used purely to
    // stagger which tick each faction's decision pass falls on
    // ((Tick + Offset) mod TickInterval = 0) so N AI factions sharing
    // the same TickInterval don't all recompute on the exact same
    // tick - see RunAllAI.
    Offset: Integer;
  end;

  // One AI-owned city's local "governor" state for the current RunAI
  // pass - computed fresh every call (never persisted, never locked -
  // same reasoning as AiUnitTargets: only ever touched from the single
  // main tick-loop thread). Exists so spawning/garrisoning can be
  // decided per-city rather than always favouring whichever city the
  // faction happened to found first - see RunAI's use of
  // ComputeAiRegions/NearestAiRegion.
  TAiRegion = record
    CityID: string;
    GX, GY: Integer;
    WorkerCount, SettlerCount, SoldierCount: Integer;
  end;

implementation

end.
