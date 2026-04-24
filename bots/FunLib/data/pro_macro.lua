--[[ Pro-match macro timings. Use to replace hardcoded thresholds in team plan / focus / commit logic. ]]
local ____exports = {}

____exports.ProMacro = {
    match_duration_p25 = 1733,
    match_duration_p50 = 1999,
    match_duration_p75 = 2295,
    sample_size = 100,
    first_rosh_typical_sec = 900,
    first_t1_fall_typical_sec = 720,
    first_rax_fall_typical_sec = 1680,
    smoke_gank_cadence_min = 3,
}

return ____exports