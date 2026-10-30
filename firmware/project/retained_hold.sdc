# Exactly two real input clocks; no relaxed or generated substitute clocks.
foreach {clock_name clock_period} {PI_CLK 5.000 M68K_CLK 139.000} {
    set clock_port [get_ports -nowarn [list $clock_name]]
    if {[get_collection_size $clock_port] != 1} { error "Missing/ambiguous Retained Hold clock: $clock_name" }
    foreach_in_collection port $clock_port {
        if {[get_port_info $port -name] ne $clock_name} { error "Unexpected Retained Hold clock match: $clock_name" }
    }
    create_clock -name $clock_name -period $clock_period $clock_port
}
source hold_cdc_constraints.tcl
source diagnostic_constraints.tcl

# The native 68000 changes E after a falling edge of its clock. CPU maximum
# CLK-low -> E transition is 55 ns for the 8 MHz part. The additional 5 ns
# board/connector/skew allowance is an ASSUMPTION, not a measured board bound.
# Both setup and hold are timed at the actual first E receiver. No E false
# path or clock-domain-wide cut is allowed. Later E storage remains timed.
set e_port [hold_exact_port M68K_E]
set e_first [hold_exact_register {e_native_sync[0]}]
set_input_delay -clock [get_clocks M68K_CLK] -clock_fall -max 60.000 $e_port
set_input_delay -clock [get_clocks M68K_CLK] -clock_fall -min 0.000 $e_port
post_message -type info "Retained Hold native E timed input: falling CLK reference; max60ns/min0ns; includes ASSUMED unmeasured 5ns board allowance"

# Other external PI, motherboard and 16374 input/output delays remain unknown
# and visible in check_timing/report_ucp. Internal setup/hold, pulse-width,
# recovery/removal and all later receiving stages remain checked.
