# Narrow, exact endpoint constraints. No asynchronous clock groups, output
# cuts, or downstream synchronizer-stage exceptions are allowed.
proc hold_lookup_pattern {name} {
    return [string map [list {[} {?} {]} {?}] $name]
}
proc hold_exact_register {name} {
    set pattern [hold_lookup_pattern $name]
    set registers [get_registers -no_duplicates -nowarn [list $pattern "*|$pattern"]]
    if {[get_collection_size $registers] != 1} { error "Missing/ambiguous Retained Hold register: $name" }
    foreach_in_collection register $registers {
        if {[lindex [split [get_register_info $register -name] |] end] ne $name} { error "Unexpected Retained Hold register match: $name" }
    }
    return $registers
}
proc hold_exact_port {name} {
    set ports [get_ports -nowarn [list [hold_lookup_pattern $name]]]
    if {[get_collection_size $ports] != 1} { error "Missing/ambiguous Retained Hold port: $name" }
    foreach_in_collection port $ports {
        if {[get_port_info $port -name] ne $name} { error "Unexpected Retained Hold port match: $name" }
    }
    return $ports
}
proc hold_cut_port_to_first {source_name first_stage} {
    set_false_path -from [hold_exact_port $source_name] -to [hold_exact_register $first_stage]
    post_message -type info "Retained Hold first-stage port cut: $source_name -> $first_stage"
}
proc hold_cut_register_to_first {source_name first_stage} {
    set_false_path -from [hold_exact_register $source_name] -to [hold_exact_register $first_stage]
    post_message -type info "Retained Hold first-stage handshake cut: $source_name -> $first_stage"
}
proc hold_cut_clock_to_first {clock_name first_stage} {
    set source [get_clocks -nowarn [list $clock_name]]
    if {[get_collection_size $source] != 1} { error "Missing/ambiguous Retained Hold source clock: $clock_name" }
    foreach_in_collection clock $source {
        if {[get_clock_info $clock -name] ne $clock_name} { error "Unexpected Retained Hold source clock match: $clock_name" }
    }
    set_false_path -from $source -to [hold_exact_register $first_stage]
    post_message -type info "Retained Hold first-stage clock cut: $clock_name -> $first_stage"
}

# E is deliberately absent: it has real min/max input timing constraints.
# Original WR/RD first stages still participate in edge detection directly;
# these inherited cuts do not claim fully isolated metastability filtering.
foreach {source_name first_stage} {
    PI_WR             {wr_sync[0]}
    PI_RD             {rd_sync[0]}
    M68K_CLK          {c7m_sync[0]}
    M68K_BG_n         {bg_native_sync[0]}
    M68K_AS_n         {as_native_sync[0]}
    M68K_DTACK_n      {dtack_native_sync[0]}
    M68K_BGACK_n      {bgack_native_sync[0]}
    M68K_BERR_n       {berr_native_sync[0]}
    {M68K_IPL_n[0]}  {ipl_1[0]}
    {M68K_IPL_n[1]}  {ipl_1[1]}
    {M68K_IPL_n[2]}  {ipl_1[2]}
} {
    hold_cut_port_to_first $source_name $first_stage
}

# S1 contains native storage and native CLK as combinational data. Only the
# first PI sample receives cuts; all subsequent sample stages remain timed.
foreach first_stage {{s1_sync[0]}} {
    hold_cut_clock_to_first M68K_CLK $first_stage
    hold_cut_port_to_first M68K_CLK $first_stage
}
foreach {source_name first_stage} {
    op_req                       op_req_sync
    fault                        {fault_pi_sync[0]}
    transfer_complete_toggle   {transfer_complete_pi_sync[0]}
    owned                        {native_ready_pi_sync[0]}
    fault                        {native_ready_pi_sync[0]}
    {native_release_sync[1]}      {native_ready_pi_sync[0]}
    bus_interrupted_pi           {interrupted_native_sync[0]}
} {
    hold_cut_register_to_first $source_name $first_stage
}

# Physical drive eligibility is monitored in PI separately from the sticky
# native fault path. Cut only its asynchronous/native sources at the first PI
# receiver. Local PI status[1] -> abort_native -> eligibility stays TIMED;
# neither the second stage nor the sticky interruption qualifier is excepted.
foreach source_name {owned fault {native_release_sync[1]} raw_loss_latched} {
    hold_cut_register_to_first $source_name {drive_eligible_pi_sync[0]}
}
foreach source_name {M68K_BG_n M68K_BGACK_n M68K_BERR_n M68K_RESET_n M68K_HALT_n} {
    hold_cut_port_to_first $source_name {drive_eligible_pi_sync[0]}
}

# Both reset-release stages have an asynchronous control input. These exact
# cuts cover that input only; the inter-stage data and downstream controller
# recovery/removal/setup/hold paths remain timed.
foreach release_stage {
    {native_release_sync[0]} {native_release_sync[1]}
    {pi_release_sync[0]} {pi_release_sync[1]}
} {
    hold_cut_register_to_first {status[1]} $release_stage
    hold_cut_port_to_first M68K_RESET_n $release_stage
    hold_cut_port_to_first M68K_HALT_n $release_stage
}

# Original bundled R/W command: op_rw and op_req launch together. Earliest
# normal_rw capture is at least one full native period after payload launch;
# host keeps the payload through its completion handshake. Bound this one
# path instead of discarding PI/native payload timing. Quartus 24.1 Standard
# lacks -datapath_only here; fitted clock latencies are included.
set_max_delay -from [hold_exact_register op_rw] -to [hold_exact_register normal_rw] 100.000
set_min_delay -from [hold_exact_register op_rw] -to [hold_exact_register normal_rw] 0.000
post_message -type info "Retained Hold bundled R/W bound: op_rw -> normal_rw max100ns/min0ns"
