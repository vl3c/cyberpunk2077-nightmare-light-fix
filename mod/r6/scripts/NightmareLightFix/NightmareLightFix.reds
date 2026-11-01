// Nightmare Light Fix for Cyberpunk 2077 2.5
//
// Restores the red "nightmare" lighting when Johnny first appears in V's apartment (start of Act 2,
// quest Playing for Time). Based on the nightmare part of Deceptious Bug Fixes.
//
// The fix's quest phase switches 56 apartment lamps off while its red lamps are on. Those lamps live in
// a vanilla sector and have no node refs, so this script gives them the refs
// $/03_night_city/#nightmare_fix/#nightmare_node_01..56 when the sector loads (the red-light sector lists
// the same refs in its nodeRefs).
//
// The original script found the lamps by fixed index (41 + i) and only ran for four exact pre-2.5 node
// counts (830, 846, 827, 843). Game 2.5 has 837 (base) or 853 (Phantom Liberty), so it did nothing.
// This version finds each lamp by its world position, checks that it is a static light, and logs
// everything (gamelog via ModLog and FTLog), so it keeps working if the sector's size or order changes.
//
// Requires Codeware (Resource/Ready callback, worldStreamingSector node setup access).

class NightmareLightFixService extends ScriptableService {
    private let m_expected: array<Vector4>;

    private cb func OnLoad() {
        this.FillExpected();
        let callbacks = GameInstance.GetCallbackSystem();
        callbacks.RegisterCallback(n"Resource/Ready", this, n"OnSectorReady")
            .AddTarget(ResourceTarget.Path(r"base\\worlds\\03_night_city\\_compiled\\default\\exterior_-22_19_1_0.streamingsector"));
        callbacks.RegisterCallback(n"Resource/Ready", this, n"OnNightmareSectorReady")
            .AddTarget(ResourceTarget.Path(r"base\\worlds\\nightmare.streamingsector"));
        callbacks.RegisterCallback(n"Session/Ready", this, n"OnSessionReady");
        NightmareLightFixLog("loaded, watching sector exterior_-22_19_1_0 for " + ToString(ArraySize(this.m_expected)) + " lamps");
    }

    private cb func OnSessionReady(event: ref<GameSessionEvent>) {
        GameInstance.GetQuestsSystem(GetGameInstance()).RegisterListener(n"nightmare_fix_done", this, n"OnNightmareFixDone");
    }

    // Set by the fix's Johnny scene when the nightmare ends; the quest phase then turns the lamps back on.
    private final func OnNightmareFixDone(value: Int32) {
        NightmareLightFixLog("fact nightmare_fix_done = " + ToString(value) + ", " + this.ClockText());
    }

    // The red lights live in this quest-only sector. It streams in only while the fix's quest step has its
    // prefab active, so this line in the log means the nightmare lighting started.
    private cb func OnNightmareSectorReady(event: ref<ResourceEvent>) {
        let sector = event.GetResource() as worldStreamingSector;
        if !IsDefined(sector) {
            NightmareLightFixLog("ERROR: red-light sector Resource/Ready fired but the resource is not a worldStreamingSector");
            return;
        }
        NightmareLightFixLog("red-light sector loaded (" + ToString(sector.GetNodeSetupCount()) + " node setups), " + this.ClockText());
    }

    private cb func OnSectorReady(event: ref<ResourceEvent>) {
        let sector = event.GetResource() as worldStreamingSector;
        if !IsDefined(sector) {
            NightmareLightFixLog("ERROR: Resource/Ready fired but the resource is not a worldStreamingSector");
            return;
        }
        let setupCount = sector.GetNodeSetupCount();
        NightmareLightFixLog("sector ready, " + ToString(setupCount) + " node setups");

        let used: array<Int32>;
        let found = 0;
        let i = 0;
        while i < ArraySize(this.m_expected) {
            let index = this.FindLamp(sector, setupCount, i, used);
            let label = this.NodeLabel(i + 1);
            if index >= 0 {
                ArrayPush(used, index);
                sector.GetNodeSetup(index).SetNodeRef(CreateNodeRef("$/03_night_city/#nightmare_fix/" + label));
                found += 1;
                if index != 42 + i {
                    NightmareLightFixLog(label + " -> setup " + ToString(index) + " (moved, old index was " + ToString(42 + i) + ")");
                }
            } else {
                NightmareLightFixLog("WARNING: " + label + " not found near " + this.PosText(this.m_expected[i]));
            }
            i += 1;
        }
        if found == ArraySize(this.m_expected) {
            NightmareLightFixLog("all " + ToString(found) + " lamps tagged");
        } else {
            NightmareLightFixLog("WARNING: tagged " + ToString(found) + " of " + ToString(ArraySize(this.m_expected)) + " lamps; the untagged ones stay on during the nightmare");
        }
    }

    private func ClockText() -> String {
        let t = GameInstance.GetTimeSystem(GetGameInstance()).GetGameTime();
        let h = GameTime.Hours(t);
        let m = GameTime.Minutes(t);
        return "game time " + ToString(h) + ":" + ((m < 10) ? ("0" + ToString(m)) : ToString(m));
    }

    // Returns the setup index of lamp i, or -1. A candidate must be a static light within 1 cm (per axis) of
    // the expected position and not already used. When two setups share a spot (setup 89 sits on a
    // romance scene light, setup 611), the one closest to the lamp's original index wins.
    private func FindLamp(sector: ref<worldStreamingSector>, setupCount: Int32, i: Int32, used: array<Int32>) -> Int32 {
        let want = this.m_expected[i];
        let oldIndex = 42 + i;
        // Fast path: the lamp is still at its old index (true for game 2.5).
        if oldIndex < setupCount && !ArrayContains(used, oldIndex) && this.IsLampAt(sector.GetNodeSetup(oldIndex), want) {
            return oldIndex;
        }
        let best = -1;
        let bestGap = 1000000;
        let s = 0;
        while s < setupCount {
            if !ArrayContains(used, s) {
                if this.IsLampAt(sector.GetNodeSetup(s), want) {
                    let gap = s - oldIndex;
                    if gap < 0 {
                        gap = -gap;
                    }
                    if gap < bestGap {
                        best = s;
                        bestGap = gap;
                    }
                }
            }
            s += 1;
        }
        return best;
    }

    private func IsLampAt(setup: ref<WorldNodeSetupWrapper>, want: Vector4) -> Bool {
        if !IsDefined(setup) || !this.CloseTo(setup.GetPosition(), want) {
            return false;
        }
        let light = setup.GetNode() as worldStaticLightNode;
        return IsDefined(light);
    }

    // True when a is within 1 cm of b on every axis.
    private func CloseTo(a: Vector4, b: Vector4) -> Bool {
        let dx = a.X - b.X;
        let dy = a.Y - b.Y;
        let dz = a.Z - b.Z;
        return dx > -0.01 && dx < 0.01 && dy > -0.01 && dy < 0.01 && dz > -0.01 && dz < 0.01;
    }

    private func NodeLabel(n: Int32) -> String {
        return "#nightmare_node_" + ((n < 10) ? ("0" + ToString(n)) : ToString(n));
    }

    private func PosText(v: Vector4) -> String {
        return "(" + ToString(v.X) + ", " + ToString(v.Y) + ", " + ToString(v.Z) + ")";
    }

    // World positions of the 56 lamps, in the original fix's order (old setups 42..97).
    // Read from the game 2.5 copy of exterior_-22_19_1_0.streamingsector.
    private func FillExpected() {
        ArrayClear(this.m_expected);
        ArrayPush(this.m_expected, new Vector4(-1383.7369, 1276.0906, 124.4258, 1.0)); // 01: 2.5 setup 42, light_018
        ArrayPush(this.m_expected, new Vector4(-1382.8125, 1275.7841, 124.8501, 1.0)); // 02: 2.5 setup 43, light_025
        ArrayPush(this.m_expected, new Vector4(-1377.4393, 1270.0883, 123.0563, 1.0)); // 03: 2.5 setup 44, light_005
        ArrayPush(this.m_expected, new Vector4(-1377.4745, 1269.7953, 122.8749, 1.0)); // 04: 2.5 setup 45, light_004
        ArrayPush(this.m_expected, new Vector4(-1380.3033, 1268.3790, 123.0563, 1.0)); // 05: 2.5 setup 46, light_002
        ArrayPush(this.m_expected, new Vector4(-1380.0106, 1268.3424, 122.8749, 1.0)); // 06: 2.5 setup 47, light_001
        ArrayPush(this.m_expected, new Vector4(-1383.2875, 1266.9741, 125.2145, 1.0)); // 07: 2.5 setup 48, {closet}_005
        ArrayPush(this.m_expected, new Vector4(-1383.8237, 1267.0978, 124.8948, 1.0)); // 08: 2.5 setup 49, {closet}_006
        ArrayPush(this.m_expected, new Vector4(-1384.5216, 1267.0978, 124.8813, 1.0)); // 09: 2.5 setup 50, {closet}_007
        ArrayPush(this.m_expected, new Vector4(-1384.6812, 1267.1261, 125.1816, 1.0)); // 10: 2.5 setup 51, {closet}_008
        ArrayPush(this.m_expected, new Vector4(-1383.8237, 1267.0978, 125.1952, 1.0)); // 11: 2.5 setup 52, {closet}_009
        ArrayPush(this.m_expected, new Vector4(-1382.9413, 1266.4382, 124.7809, 1.0)); // 12: 2.5 setup 53, {closet}_002
        ArrayPush(this.m_expected, new Vector4(-1383.8237, 1267.0978, 124.6217, 1.0)); // 13: 2.5 setup 54, {closet}_003
        ArrayPush(this.m_expected, new Vector4(-1383.2802, 1266.9500, 124.9298, 1.0)); // 14: 2.5 setup 55, {closet}_004
        ArrayPush(this.m_expected, new Vector4(-1376.7028, 1274.3491, 123.1261, 1.0)); // 15: 2.5 setup 56, light_010
        ArrayPush(this.m_expected, new Vector4(-1383.2393, 1266.9366, 124.6234, 1.0)); // 16: 2.5 setup 57, {closet}_002
        ArrayPush(this.m_expected, new Vector4(-1387.5824, 1274.4431, 124.0789, 1.0)); // 17: 2.5 setup 58, {vroom_computer_light}_002
        ArrayPush(this.m_expected, new Vector4(-1386.7938, 1274.2562, 125.3782, 1.0)); // 18: 2.5 setup 59, {pc_lights}_005
        ArrayPush(this.m_expected, new Vector4(-1386.9485, 1273.2631, 125.3501, 1.0)); // 19: 2.5 setup 60, {pc_lights}_006
        ArrayPush(this.m_expected, new Vector4(-1386.8984, 1275.0632, 125.6284, 1.0)); // 20: 2.5 setup 61, {pc_lights}_008
        ArrayPush(this.m_expected, new Vector4(-1386.6821, 1274.9675, 125.3782, 1.0)); // 21: 2.5 setup 62, {pc_lights}_007
        ArrayPush(this.m_expected, new Vector4(-1387.0636, 1274.2307, 125.6325, 1.0)); // 22: 2.5 setup 63, {pc_lights}_003
        ArrayPush(this.m_expected, new Vector4(-1387.0248, 1273.2913, 125.6321, 1.0)); // 23: 2.5 setup 64, {pc_lights}_004
        ArrayPush(this.m_expected, new Vector4(-1386.0598, 1267.2493, 124.8574, 1.0)); // 24: 2.5 setup 65, {closet_}_002
        ArrayPush(this.m_expected, new Vector4(-1386.0404, 1267.3291, 125.2173, 1.0)); // 25: 2.5 setup 66, {closet_}_003
        ArrayPush(this.m_expected, new Vector4(-1383.3785, 1276.5099, 124.0807, 1.0)); // 26: 2.5 setup 67, light_019
        ArrayPush(this.m_expected, new Vector4(-1383.6694, 1276.3588, 125.6739, 1.0)); // 27: 2.5 setup 68, light_018
        ArrayPush(this.m_expected, new Vector4(-1382.0497, 1276.5646, 127.1481, 1.0)); // 28: 2.5 setup 69, {vroom_bathroom_bounce_door}_004
        ArrayPush(this.m_expected, new Vector4(-1381.9508, 1277.1338, 126.1325, 1.0)); // 29: 2.5 setup 70, {vroom_bathroom_bounce_door}_003
        ArrayPush(this.m_expected, new Vector4(-1383.4530, 1276.8680, 124.6004, 1.0)); // 30: 2.5 setup 71, light_007
        ArrayPush(this.m_expected, new Vector4(-1382.9935, 1278.0927, 125.9325, 1.0)); // 31: 2.5 setup 72, light_015
        ArrayPush(this.m_expected, new Vector4(-1382.5861, 1275.8680, 125.8149, 1.0)); // 32: 2.5 setup 73, {vroom_bathroom_bounce_door}_001
        ArrayPush(this.m_expected, new Vector4(-1383.6652, 1276.3588, 125.8027, 1.0)); // 33: 2.5 setup 74, light_011
        ArrayPush(this.m_expected, new Vector4(-1379.9475, 1263.6710, 125.8703, 1.0)); // 34: 2.5 setup 75, {vroom_armory_fill}_004
        ArrayPush(this.m_expected, new Vector4(-1387.4203, 1273.9026, 124.7083, 1.0)); // 35: 2.5 setup 76, {pc_lights}
        ArrayPush(this.m_expected, new Vector4(-1381.0651, 1262.5123, 125.8465, 1.0)); // 36: 2.5 setup 77, {vroom_armory_fill}_010
        ArrayPush(this.m_expected, new Vector4(-1383.6855, 1262.8390, 124.3252, 1.0)); // 37: 2.5 setup 78, {vroom_armory_machine_inside}
        ArrayPush(this.m_expected, new Vector4(-1384.5970, 1273.6262, 126.5965, 1.0)); // 38: 2.5 setup 79, {pc_lights}_001
        ArrayPush(this.m_expected, new Vector4(-1378.1345, 1267.6099, 124.6353, 1.0)); // 39: 2.5 setup 80, {vroom_braindance}_003
        ArrayPush(this.m_expected, new Vector4(-1375.7922, 1276.2382, 125.8007, 1.0)); // 40: 2.5 setup 81, light_008
        ArrayPush(this.m_expected, new Vector4(-1383.3137, 1278.0927, 125.8880, 1.0)); // 41: 2.5 setup 82, light_014
        ArrayPush(this.m_expected, new Vector4(-1378.3728, 1269.2471, 124.5901, 1.0)); // 42: 2.5 setup 83, {vroom_braindance}_004
        ArrayPush(this.m_expected, new Vector4(-1379.1930, 1268.3145, 124.5843, 1.0)); // 43: 2.5 setup 84, {vroom_braindance}_007
        ArrayPush(this.m_expected, new Vector4(-1383.3566, 1264.7208, 125.6226, 1.0)); // 44: 2.5 setup 85, {vroom_armory_fill}_011
        ArrayPush(this.m_expected, new Vector4(-1377.1217, 1276.2382, 125.9769, 1.0)); // 45: 2.5 setup 86, light_012
        ArrayPush(this.m_expected, new Vector4(-1381.1310, 1277.1398, 125.3694, 1.0)); // 46: 2.5 setup 87, light_024
        ArrayPush(this.m_expected, new Vector4(-1397.2379, 1267.0234, 123.3684, 1.0)); // 47: 2.5 setup 88, {floor_lights_A}_007
        ArrayPush(this.m_expected, new Vector4(-1388.0887, 1271.1460, 126.1336, 1.0)); // 48: 2.5 setup 89, light_016
        ArrayPush(this.m_expected, new Vector4(-1387.4940, 1270.9680, 126.5176, 1.0)); // 49: 2.5 setup 90, light_013
        ArrayPush(this.m_expected, new Vector4(-1400.6703, 1266.2065, 124.0767, 1.0)); // 50: 2.5 setup 91, {drop_point_spot}
        ArrayPush(this.m_expected, new Vector4(-1394.4619, 1277.8059, 124.5303, 1.0)); // 51: 2.5 setup 92, {shwab_machine_next_to_v}
        ArrayPush(this.m_expected, new Vector4(-1378.4042, 1268.3059, 124.6515, 1.0)); // 52: 2.5 setup 93, light_006
        ArrayPush(this.m_expected, new Vector4(-1376.4327, 1267.8281, 125.3015, 1.0)); // 53: 2.5 setup 94, light
        ArrayPush(this.m_expected, new Vector4(-1396.1249, 1279.6934, 123.3684, 1.0)); // 54: 2.5 setup 95, {floor_lights_A}_006
        ArrayPush(this.m_expected, new Vector4(-1397.5170, 1254.0736, 125.7539, 1.0)); // 55: 2.5 setup 96, {orange_lights_Walls_}_005
        ArrayPush(this.m_expected, new Vector4(-1377.3942, 1274.7466, 123.1676, 1.0)); // 56: 2.5 setup 97, light_009
    }
}

func NightmareLightFixLog(text: String) {
    ModLog(n"NightmareLightFix", text);
    FTLog("[NightmareLightFix] " + text);
}
