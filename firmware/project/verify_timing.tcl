package require ::quartus::project
package require ::quartus::sta
if {[llength $quartus(args)] != 1} { error "Expected the exact project name" }
set project_name [lindex $quartus(args) 0]
file mkdir reports
project_open $project_name
set summaries {}
set failures {}

foreach model {slow fast} {
    create_timing_netlist -model $model
    read_sdc
    update_timing_netlist

    # Native E is timed from the native falling edge, not waived as async.
    # Constrained checks depend on an ASSUMED 5 ns unmeasured board budget.
    set e_source [hold_exact_port M68K_E]
    set e_destination [hold_exact_register {e_native_sync[0]}]
    foreach analysis {setup hold} {
        report_timing -$analysis -from $e_source -to $e_destination -npaths 1 -detail full_path -file reports/${model}_native_e_${analysis}.rpt
        set e_paths [get_timing_paths -$analysis -from $e_source -to $e_destination -npaths 1]
        if {[get_collection_size $e_paths] != 1} { error "Missing/ambiguous $model native E $analysis path" }
        foreach_in_collection e_path $e_paths {
            set e_launch_clock [get_path_info $e_path -from_clock]
            set e_latch_clock [get_path_info $e_path -to_clock]
            if {$e_launch_clock eq "" || $e_latch_clock eq ""} { error "Missing $model native E clock association" }
            if {[get_clock_info $e_launch_clock -name] ne "M68K_CLK" || [get_clock_info $e_latch_clock -name] ne "M68K_CLK"} { error "Unexpected $model native E launch/latch clock" }
            if {[get_path_info $e_path -from_clock_is_inverted] != 1 || [get_path_info $e_path -to_clock_is_inverted] != 0} { error "Native E must launch on falling CLK and latch on positive CLK in $model/$analysis" }
            set e_slack [get_path_info $e_path -slack]
            if {![string is double -strict $e_slack]} { error "Non-numeric $model native E $analysis slack" }
            lappend summaries "$model/native_e_$analysis=$e_slack"
            if {$e_slack < 0.0} { lappend failures "$model/native_e_$analysis=$e_slack" }
        }
    }

    # Retained Hold has two real input-clock domains. A stale generated-clock file or an
    # accidentally omitted native clock must not produce an apparent pass.
    set actual_clock_count [get_collection_size [get_clocks *]]
    if {$actual_clock_count != 5} {
        lappend failures "$model/clock_count=$actual_clock_count"
    }
    foreach {expected_clock expected_period} {PI_CLK 5.0 M68K_CLK 139.0 UFM_OSC 181.818 UFM_ARCLK 363.636 UFM_DRCLK 363.636} {
        set selected_clock [get_clocks -nowarn $expected_clock]
        if {[get_collection_size $selected_clock] != 1} {
            lappend failures "$model/missing_clock=$expected_clock"
            continue
        }
        foreach_in_collection clock $selected_clock {
            set actual_period [get_clock_info $clock -period]
            if {![string is double -strict $actual_period] || abs($actual_period-$expected_period)>0.0001} {
                lappend failures "$model/clock_period/$expected_clock=$actual_period"
            }
            lappend summaries "$model/clock_period/$expected_clock=$actual_period"
        }
    }

    # Preserve all reports before applying numerical failure gates. Full paths
    # trace generated-clock ancestry too; no clock-name/domain filter is used.
    report_clocks -file reports/${model}_clocks.rpt
    report_clock_transfers -file reports/${model}_clock_transfers.rpt
    report_clock_fmax_summary -file reports/${model}_fmax.rpt
    report_sdc -file reports/${model}_effective_constraints.rpt
    report_sdc -ignored -file reports/${model}_constraint_history.rpt
    write_sdc -expand reports/${model}_effective_constraints.sdc
    check_timing -include {no_clock multiple_clock loops latches no_input_delay no_output_delay} -file reports/${model}_constraint_checks.rpt
    report_ucp -file reports/${model}_unconstrained_paths.rpt
    # Both the 200 MHz PI clock and the real native-clock bus domain must
    # satisfy device pulse-width/period requirements. Do not infer from Fmax.
    report_min_pulse_width -nworst 100 -file reports/${model}_minimum_pulse_width.rpt
    set pulse_file [open reports/${model}_minimum_pulse_width.rpt r]
    set pulse_text [read $pulse_file]
    close $pulse_file
    if {![regexp {Found ([0-9]+) results \(([0-9]+) violated\)\.\s+Worst case slack is ([-+0-9.eE]+)} $pulse_text match pulse_count pulse_violations pulse_slack]} {
        error "Cannot read $model minimum-pulse-width result; review report format"
    }
    if {$pulse_count == 0 || ![string is double -strict $pulse_slack]} {
        error "No numeric $model minimum-pulse-width checks"
    }
    lappend summaries "$model/minimum_pulse_width=$pulse_slack"
    if {$pulse_violations != 0 || $pulse_slack < 0.0} {
        lappend failures "$model/minimum_pulse_width=$pulse_slack"
    }

    # Missing clocks must not turn a two-clock implementation into an
    # apparent pass merely because another clock still has constrained paths.
    # External input/output delays remain intentionally unqualified.
    set check_file [open reports/${model}_constraint_checks.rpt r]
    set check_text [read $check_file]
    close $check_file
    foreach check {no_clock multiple_clock loops latches} {
        set pattern [format {;\s*%s\s*;\s*([0-9]+)\s*;} $check]
        if {![regexp -nocase $pattern $check_text match issue_count]} {
            error "Cannot read $model/$check constraint-check count; review report format"
        }
        lappend summaries "$model/$check=$issue_count"
        if {$issue_count != 0} { lappend failures "$model/$check=$issue_count" }
    }

    # Ignored constraints are a failure even if Quartus calls them a warning.
    set history_file [open reports/${model}_constraint_history.rpt r]
    set history_text [read $history_file]
    close $history_file
    if {[string first "No constraints were ignored." $history_text] < 0} {
        lappend failures "$model/ignored_constraints=REVIEW_REQUIRED"
    } else {
        lappend summaries "$model/ignored_constraints=0"
    }

    foreach type {setup hold recovery removal} {
        # This must precede every failure on this analysis so failed candidates
        # retain useful endpoint/routing/generated-clock detail for diagnosis.
        report_timing -$type -npaths 100 -detail full_path -file reports/${model}_${type}.rpt
        set paths [get_timing_paths -$type -npaths 1]
        set path_count [get_collection_size $paths]
        if {$path_count == 0} {
            lappend summaries "$model/$type=NO_PATHS"
            if {$type eq "setup" || $type eq "hold"} {
                lappend failures "$model/$type=NO_PATHS"
            }
            continue
        }
        foreach_in_collection path $paths {
            set slack [get_path_info $path -slack]
            if {![string is double -strict $slack]} {
                error "Unrecognized $model/$type slack: $slack"
            }
            lappend summaries "$model/$type=$slack"
            if {$slack < 0.0} { lappend failures "$model/$type=$slack" }
        }
    }
    delete_timing_netlist
}
project_close

# Each build script uses a fresh snapshot, so a previous success record cannot
# be inherited. A failing run never creates the success record or an SVF.
if {[llength $failures] != 0} {
    set report [open reports/internal-timing-failed.json w]
    puts $report [format {{"scope":"constrained internal paths and assumed native-E input budget only; external IO remains unqualified","checks":"%s","failures":"%s"}} [join $summaries {; }] [join $failures {; }]]
    close $report
    error "Internal timing/constraint verification failed: [join $failures {; }]. Detailed slow/fast reports were retained."
}

set report [open reports/internal-timing-passed.json w]
puts $report [format {{"scope":"constrained internal paths and assumed native-E input budget only; external IO remains unqualified","checks":"%s"}} [join $summaries {; }]]
close $report
post_message -type info "Internal timing passed. External IO and physical hardware are NOT qualified."
