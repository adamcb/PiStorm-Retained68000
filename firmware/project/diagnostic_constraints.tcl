# The UFM oscillator is independent of the Amiga and Pi input clocks. Its
# documented fastest period is 180 ns. It runs during USB-only retrieval.
proc diag_exact_pin {leaf} {
    set pins [get_pins -hierarchical -nowarn [list "*$leaf"]]
    if {[get_collection_size $pins] != 1} { error "Missing/ambiguous diagnostic primitive pin: $leaf" }
    return $pins
}
set diag_osc_pin [diag_exact_pin {storage|osc}]
create_clock -name UFM_OSC -period 181.818 $diag_osc_pin
# These are registered, potentially stopped strobes. Control/data use the
# positive oscillator edge; actual strobe registers use its NEGATIVE edge.
# Minimum rise spacing is two periods, with >=one period high and low.
# Source edges2/4/6 express that half-period phase and fastest waveform.
foreach {name regname} {UFM_ARCLK arclk UFM_DRCLK drclk} {
    create_generated_clock -name $name -source $diag_osc_pin -edges {2 4 6} [hold_exact_register $regname]
}

# Only exact first receiving stages are asynchronous exceptions. Every later
# stage is timed. No complete clock-domain groups are waived.
foreach {source first} {
    diag_snapshot_valid {valid_sync[0]}
} {
    # Hierarchy names are resolved explicitly below for scoped sources.
    if {[string first {|} $source] >= 0} {
        set leaf [lindex [split $source |] end]
        hold_cut_register_to_first $leaf $first
    } else { hold_cut_register_to_first $source $first }
}
hold_cut_clock_to_first PI_CLK {diag_busy_native_sync[0]}
foreach {pin first} {
    {storage|busy} {busy_sync[0]}
} {
    set_false_path -from [diag_exact_pin $pin] -to [hold_exact_register $first]
}

# Snapshot is held bundled data, not a continuously changing bus.
# Valid passes two oscillator receiver stages before it can be used.
# Bound their physical data paths to 100 ns, less than one 180 ns oscillator
# period. Keep the downstream controller and mux timing fully constrained.
set diag_patterns {}
for {set bit 0} {$bit < 12} {incr bit} {
    lappend diag_patterns [hold_lookup_pattern [format {diag_snapshot[%d]} $bit]]
}
set diag_bundle [get_registers -nowarn $diag_patterns]
if {[get_collection_size $diag_bundle] != 12} { error "Expected exactly 12 snapshot bundled source registers" }
set_max_delay -from $diag_bundle -to [get_clocks UFM_OSC] 100.000
set_min_delay -from $diag_bundle -to [get_clocks UFM_OSC] 0.000
post_message -type info "Diagnostic UFM hardwareosc181.818ns with4ns envelope reserve; opposite-edge AR/DR strobes363.636ns; exact first-stage CDC cuts; held bundle max100ns/min0ns"

# Quartus models the hard oscillator as 5.5 MHz (181.818 ns). Do not override
# its hardware clock parameter. A 4 ns setup reserve covers the handbook's
# faster 180 ns end and a two-period strobe's 360 ns minimum. This reserve is
# an oscillator-envelope allowance, not measured board/Pi clock jitter.
set_clock_uncertainty -setup -to [get_clocks {UFM_OSC UFM_ARCLK UFM_DRCLK}] 4.000
