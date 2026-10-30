/*
 * Copyright 2020 Claude Schwarz; Copyright 2020 Niklas Ekstrom
 * SPDX-License-Identifier: MIT
 * Experimental retained-68000 extended-hold reconstruction, based on V5 and the
 * physically checked Original control. Not an attested rebuild of 2021 Long Hold.
 * LazarusStorm BRJP-OPEN retained-CPU correction, based on Hold A.
 * Native E and /BG are inputs. The native CPU /BR remains low through R1.
 * PiStorm-side /BR is isolated and pulled HIGH through R2; it is an unused
 * input and must not qualify, release, or fault the native bus ownership.
 * Local read clocks retain the direct Original S7 decode, without a mux.
 * The native E receiver assumes <=60ns falling-CLK-to-CPLD-input delay;
 * this is an explicit project timing assumption, not a board measurement.
 */
module pistorm(
    output reg PI_TXN_IN_PROGRESS=0, output reg PI_IPL_ZERO=0,
    input [1:0] PI_A, input PI_CLK, output reg PI_RESET=0,
    input PI_RD,PI_WR, inout [15:0] PI_D,
    output LTCH_A_0,LTCH_A_8,LTCH_A_16,LTCH_A_24,LTCH_A_OE_n,
    output LTCH_D_RD_U,LTCH_D_RD_L,LTCH_D_RD_OE_n,
    output LTCH_D_WR_U,LTCH_D_WR_L,LTCH_D_WR_OE_n,
    input M68K_CLK, inout [2:0] M68K_FC,
    inout M68K_AS_n,M68K_UDS_n,M68K_LDS_n,M68K_RW,
    input M68K_DTACK_n,M68K_BERR_n,M68K_VPA_n,M68K_E,
    inout M68K_VMA_n, input [2:0] M68K_IPL_n,
    inout M68K_RESET_n,M68K_HALT_n,
    input M68K_BR_n,M68K_BG_n,M68K_BGACK_n
);
  wire c200m=PI_CLK,c7m=M68K_CLK;
  localparam REG_DATA=2'd0,REG_ADDR_LO=2'd1,REG_ADDR_HI=2'd2,REG_STATUS=2'd3;
  reg [1:0] rd_sync=0,wr_sync=0;
  reg [2:0] s1_sync=0,c7m_sync=0;
  reg [15:0] data_out=0,status=0;
  reg op_req=0,op_rw=1,op_uds_n=1,op_lds_n=1,a0=0;
  reg op_req_sync=0,normal_rw=1;
  reg [2:0] ipl=0,ipl_1=0,ipl_2=0;
  reg [1:0] state=0;
  reg wait_req=1,wait_dtack=0;
  // A=0 adds a half-native-period AS tail. B=1 adds one more native period.
  localparam integer EXTRA_HOLD_CYCLES=0;
  reg normal_as_hold=0,normal_finish_hold=0;
  reg [1:0] extra_hold_remaining=0;

  // Original host edge detection, including its functional first-stage use.
  wire rd_rising=!rd_sync[1]&&rd_sync[0];
  wire wr_rising=!wr_sync[1]&&wr_sync[0];
  wire rising_s1=!s1_sync[2]&&s1_sync[1];
  wire c7m_falling=c7m_sync[2]&&!c7m_sync[1];
  wire reset_out=!status[1];
  assign M68K_RESET_n=reset_out?1'b0:1'bz;
  assign M68K_HALT_n=reset_out?1'b0:1'bz;
  wire abort_native=reset_out||!M68K_RESET_n||!M68K_HALT_n;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] native_release_sync=2'b11,pi_release_sync=2'b11;
  wire native_reset=native_release_sync[1],pi_reset=pi_release_sync[1];
  always @(posedge c7m or posedge abort_native)
    if(abort_native)native_release_sync<=2'b11;
    else native_release_sync<={native_release_sync[0],1'b0};
  always @(posedge c200m or posedge abort_native)
    if(abort_native)pi_release_sync<=2'b11;
    else pi_release_sync<={pi_release_sync[0],1'b0};

  wire S0=state==2'd0&&c7m&&!wait_req;
  wire Sr=state==2'd0&&wait_req;
  wire S1=state==2'd1&&!c7m;
  wire S2=state==2'd1&&c7m;
  wire S3=state==2'd2&&!c7m&&!wait_dtack;
  wire S4=state==2'd2&&c7m&&!wait_dtack;
  wire Sw=state==2'd2&&wait_dtack;
  wire S5=state==2'd3&&!c7m;
  wire S6=state==2'd3&&c7m;
  wire S7=state==2'd0&&!c7m&&!wait_req;

  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] e_native_sync=0;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [2:0] bg_native_sync=7,as_native_sync=7,dtack_native_sync=7,
      bgack_native_sync=7,berr_native_sync=7;
  reg e_previous=0,e_seen_rise=0,e_seen_fall=0;
  reg [1:0] acquire_count=0;
  reg owned=0,fault=0;
  reg raw_loss_latched=0;
  reg bus_interrupted_pi=0;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] interrupted_native_sync=0;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] fault_pi_sync=0;
  wire e_rise=e_native_sync[1]&&!e_previous;
  wire e_fall=!e_native_sync[1]&&e_previous;
  wire acquisition_ok=e_seen_rise&&e_seen_fall&&
      !bg_native_sync[2]&&as_native_sync[2]&&dtack_native_sync[2]&&
      bgack_native_sync[2]&&berr_native_sync[2];
  wire native_enable=owned&&!fault&&!native_reset;
  // Asynchronous assertion prevents a prerequisite pulse from re-enabling
  // bus outputs while the PI-domain interruption detector is still sampling
  // it. Clear only during native reset, before ownership can be reacquired.
  // Device minimum asynchronous-control pulse width remains a physical limit.
  wire raw_ownership_loss=owned&&!native_reset&&
      (M68K_BG_n||!M68K_BGACK_n||!M68K_BERR_n);
  always @(posedge c7m or posedge raw_ownership_loss)
    if(raw_ownership_loss)raw_loss_latched<=1;
    else if(native_reset)raw_loss_latched<=0;
  // Withdraw physical drive immediately on reset or loss of a fixed-owner
  // prerequisite. The synchronized monitor latches a fault; no retry occurs.
  wire drive_bus=native_enable&&!abort_native&&!raw_loss_latched&&!bus_interrupted_pi&&
      !M68K_BG_n&&
      M68K_BGACK_n&&M68K_BERR_n;

  reg peripheral_req=0,peripheral_capture_ready=0,peripheral_done=0;
  reg peripheral_vma_low=0,transfer_complete_toggle=0;
  localparam P_IDLE=3'd0,P_WAIT_FALL=3'd1,P_WAIT_RISE=3'd2,
             P_WAIT_END=3'd3,P_DONE=3'd4;
  reg [2:0] peripheral_state=P_IDLE;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [2:0] transfer_complete_pi_sync=0,
      native_ready_pi_sync=0;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] drive_eligible_pi_sync=0;
  reg transfer_complete_pi_previous=0;
  wire transfer_completion=transfer_complete_pi_sync[2]^
      transfer_complete_pi_previous;

  // Diagnostic storage is observational. None of these signals enters the
  // functional bus controller or any reset/interrupt/ownership equation.
  // Capture and UFM evidence survive Amiga/Pi resets. UFM also survives power
  // loss once its final commit word has completed. Reflashing can erase it.
  // Observation only: these per-source pulse flags never drive the controller.
  // They record sources seen before the snapshot, not strict edge ordering.
  reg diag_bg_seen=0,diag_bgack_seen=0,diag_berr_seen=0;
  wire diag_bg_event=owned&&!native_reset&&M68K_BG_n;
  wire diag_bgack_event=owned&&!native_reset&&!M68K_BGACK_n;
  wire diag_berr_event=owned&&!native_reset&&!M68K_BERR_n;
  always @(posedge c7m or posedge diag_bg_event)
    if(diag_bg_event)diag_bg_seen<=1;
    else if(native_reset)diag_bg_seen<=0;
  always @(posedge c7m or posedge diag_bgack_event)
    if(diag_bgack_event)diag_bgack_seen<=1;
    else if(native_reset)diag_bgack_seen<=0;
  always @(posedge c7m or posedge diag_berr_event)
    if(diag_berr_event)diag_berr_seen<=1;
    else if(native_reset)diag_berr_seen<=0;
  (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
  reg [1:0] diag_busy_native_sync=0;
  reg [12:0] diag_busy_count=0;
  (* preserve *) reg diag_snapshot_valid=0;
  (* preserve *) reg [11:0] diag_snapshot=0;
  wire [1:0] diag_reason=raw_loss_latched?2'd1:
      fault?2'd2:interrupted_native_sync[1]?2'd3:2'd0;
  always @(posedge c7m)begin
    diag_busy_native_sync<={diag_busy_native_sync[0],PI_TXN_IN_PROGRESS};
    if(native_reset||!diag_busy_native_sync[1])diag_busy_count<=0;
    // The first all-ones count captures below; stop counting thereafter.
    // Wrapping on the capture edge is harmless and avoids a saturation mux.
    else if(!diag_snapshot_valid)diag_busy_count<=diag_busy_count+1'b1;
    if(!diag_snapshot_valid&&!native_reset&&
        (raw_loss_latched||fault||interrupted_native_sync[1]||(&diag_busy_count)))begin
      diag_snapshot_valid<=1;
      diag_snapshot<={diag_reason,owned,state,peripheral_state,
          diag_bg_seen,diag_bgack_seen,diag_berr_seen,M68K_VPA_n};
    end
  end
  diagnostic_ufm diag_ufm(.snapshot(diag_snapshot),.snapshot_valid(diag_snapshot_valid),
      .flash_busy(),.ready(),.locked());

  wire normal_address_enable=S1||S2||S3||S4||Sw||S5||S6||S7;
  wire normal_write_enable=!op_rw&&(S3||S4||Sw||S5||S6||S7);
  wire normal_as_n=!(S2||S3||S4||Sw||S5||S6);
  wire normal_uds_n=((op_rw&&(S2||S3))||(S4||Sw||S5||S6))?op_uds_n:1'b1;
  wire normal_lds_n=((op_rw&&(S2||S3))||(S4||Sw||S5||S6))?op_lds_n:1'b1;
  assign LTCH_A_0=PI_A==REG_ADDR_LO&&PI_WR;
  assign LTCH_A_8=LTCH_A_0;
  assign LTCH_A_16=PI_A==REG_ADDR_HI&&PI_WR;
  assign LTCH_A_24=LTCH_A_16;
  assign LTCH_D_WR_U=PI_A==REG_DATA&&PI_WR;
  assign LTCH_D_WR_L=LTCH_D_WR_U;
  assign LTCH_D_RD_OE_n=!(PI_A==REG_DATA&&PI_RD);
  assign LTCH_A_OE_n=!(drive_bus&&(peripheral_req||normal_finish_hold||normal_address_enable));
  assign LTCH_D_WR_OE_n=!(drive_bus&&
      (((peripheral_req||normal_finish_hold)&&!op_rw)||normal_write_enable));
  assign M68K_FC=drive_bus?3'b000:3'bzzz;
  assign M68K_AS_n=drive_bus?((peripheral_req||normal_as_hold)?1'b0:normal_as_n):1'bz;
  assign M68K_UDS_n=drive_bus?((peripheral_req||normal_as_hold)?op_uds_n:normal_uds_n):1'bz;
  assign M68K_LDS_n=drive_bus?((peripheral_req||normal_as_hold)?op_lds_n:normal_lds_n):1'bz;
  assign M68K_RW=drive_bus?((peripheral_req||normal_finish_hold)?op_rw:normal_rw):1'bz;
  assign M68K_VMA_n=drive_bus?!(peripheral_req&&peripheral_vma_low):1'bz;

  // These are local 16374 clock inputs, not motherboard bus drivers.
  // Keep the exact Original four-input capture decode. Ownership/peripheral
  // selection must never add a combinational gate to this clock path.
  assign LTCH_D_RD_U=S7;
  assign LTCH_D_RD_L=S7;

  always @(posedge c200m) begin
    rd_sync<={rd_sync[0],PI_RD};wr_sync<={wr_sync[0],PI_WR};
    s1_sync<={s1_sync[1:0],S1};
    c7m_sync<={c7m_sync[1:0],M68K_CLK};
    if(rd_rising&&PI_A==REG_STATUS)data_out<={ipl,13'd0};
    if(pi_reset)begin
      op_req<=0;PI_TXN_IN_PROGRESS<=0;
      fault_pi_sync<=0;native_ready_pi_sync<=0;
      drive_eligible_pi_sync<=0;bus_interrupted_pi<=0;
      transfer_complete_pi_sync<=0;transfer_complete_pi_previous<=0;
    end else begin
      fault_pi_sync<={fault_pi_sync[0],fault};
      native_ready_pi_sync<={native_ready_pi_sync[1:0],native_enable};
      drive_eligible_pi_sync<={drive_eligible_pi_sync[0],drive_bus};
      if(PI_TXN_IN_PROGRESS&&native_ready_pi_sync[2]&&!drive_eligible_pi_sync[1])
        bus_interrupted_pi<=1;
      transfer_complete_pi_sync<={transfer_complete_pi_sync[1:0],
          transfer_complete_toggle};
      transfer_complete_pi_previous<=transfer_complete_pi_sync[2];
      if(rising_s1)op_req<=0;
      // Completion histories settle during native reset/reacquisition, before
      // this ready chain allows them to affect a newly queued command.
      if(native_ready_pi_sync[2]&&drive_eligible_pi_sync[1]&&!bus_interrupted_pi&&
          transfer_completion)
        PI_TXN_IN_PROGRESS<=0;
      if(fault_pi_sync[1]||bus_interrupted_pi)PI_TXN_IN_PROGRESS<=1;
    end
    if(wr_rising)begin
      case(PI_A)
        REG_ADDR_LO:begin
          a0<=PI_D[0];
          if(!pi_reset)PI_TXN_IN_PROGRESS<=1;
        end
        REG_ADDR_HI:begin
          if(!pi_reset)op_req<=1;
          op_rw<=PI_D[9];
          op_uds_n<=PI_D[8]?a0:1'b0;
          op_lds_n<=PI_D[8]?!a0:1'b0;
        end
        REG_STATUS:status<=PI_D;
      endcase
    end
    if(c7m_falling)begin ipl_1<=~M68K_IPL_n;ipl_2<=ipl_1;end
    if(ipl_2==ipl_1)ipl<=ipl_2;
    PI_IPL_ZERO<=ipl==0;
    PI_RESET<=reset_out?1'b1:M68K_RESET_n;
  end
  assign PI_D=PI_A==REG_STATUS&&PI_RD?data_out:16'bz;

  // wait_req has exactly one, positive-edge writer. The intended S7 edge is
  // followed by CLK high, then wait_req=1 BEFORE another CLK falling edge.
  // This prevents recapture after native E fall during peripheral hold.
  always @(posedge c7m)begin
    if(native_reset||!native_enable)begin
      op_req_sync<=0;normal_rw<=1;wait_req<=1;
    end else begin
      op_req_sync<=op_req;
      case(state)
        2'd0:begin normal_rw<=1;wait_req<=1;end
        2'd1:begin normal_rw<=op_rw;wait_req<=0;end
      endcase
    end
  end

  // Assert the AS extension while the original AS is still low (S6),
  // a half-cycle BEFORE S7 read capture. It cannot create a release glitch
  // at S6->S7. Deassert at a later positive edge; address/data/RW remain held
  // until the following negative edge, when host completion is generated.
  always @(posedge c7m)begin
    if(native_reset||!native_enable)begin
      normal_as_hold<=0;extra_hold_remaining<=0;
    end else if(state==2'd3)begin
      normal_as_hold<=1;extra_hold_remaining<=EXTRA_HOLD_CYCLES;
    end else if(state==2'd0&&normal_as_hold)begin
      if(extra_hold_remaining!=0)extra_hold_remaining<=extra_hold_remaining-1'b1;
      else normal_as_hold<=0;
    end
  end

  always @(negedge c7m)begin
    if(native_reset)begin
      state<=0;wait_dtack<=0;peripheral_req<=0;transfer_complete_toggle<=0;normal_finish_hold<=0;
    end else if(!native_enable)begin
      state<=0;wait_dtack<=0;peripheral_req<=0;normal_finish_hold<=0;
    end else case(state)
      2'd0:begin
        if(normal_finish_hold)begin
          if(!normal_as_hold)begin
            normal_finish_hold<=0;
            transfer_complete_toggle<=!transfer_complete_toggle;
          end
        end else if(peripheral_req)begin
          if(peripheral_done)begin
            // Only here are peripheral AS/DS/address/data released. The
            // separate PI completion follows this release, never early S7.
            peripheral_req<=0;
            transfer_complete_toggle<=!transfer_complete_toggle;
          end
        end else if(peripheral_state==P_IDLE&&op_req_sync)state<=2'd1;
      end
      2'd1:state<=2'd2;
      2'd2:begin
        // Sticky peripheral selection wins over simultaneous DTACK.
        if(peripheral_req||!M68K_VPA_n)begin
          peripheral_req<=1;
          if(peripheral_capture_ready)begin
            // Skip S5/S6 on this path only. S7 captures late in E high,
            // while peripheral_req independently holds all bus controls.
            state<=0;wait_dtack<=0;
          end else wait_dtack<=1;
        end else if(!M68K_DTACK_n)begin
          wait_dtack<=0;state<=2'd3;normal_finish_hold<=1;
        end
        else wait_dtack<=1;
      end
      2'd3:state<=0;
    endcase
  end

  always @(posedge c7m)begin
    if(native_reset)begin
      e_native_sync<=0;e_previous<=0;e_seen_rise<=0;e_seen_fall<=0;
      bg_native_sync<=7;as_native_sync<=7;dtack_native_sync<=7;
      bgack_native_sync<=7;berr_native_sync<=7;
      interrupted_native_sync<=0;
      acquire_count<=0;owned<=0;fault<=0;
      peripheral_state<=P_IDLE;peripheral_capture_ready<=0;
      peripheral_done<=0;peripheral_vma_low<=0;
    end else begin
      e_native_sync<={e_native_sync[0],M68K_E};
      e_previous<=e_native_sync[1];
      bg_native_sync<={bg_native_sync[1:0],M68K_BG_n};
      as_native_sync<={as_native_sync[1:0],M68K_AS_n};
      dtack_native_sync<={dtack_native_sync[1:0],M68K_DTACK_n};
      bgack_native_sync<={bgack_native_sync[1:0],M68K_BGACK_n};
      berr_native_sync<={berr_native_sync[1:0],M68K_BERR_n};
      interrupted_native_sync<={interrupted_native_sync[0],bus_interrupted_pi};
      if(e_rise)e_seen_rise<=1;
      if(e_fall)e_seen_fall<=1;
      if(!owned)begin
        if(!fault&&acquisition_ok)begin
          if(acquire_count==3)begin owned<=1;acquire_count<=0;end
          else acquire_count<=acquire_count+1'b1;
        end else acquire_count<=0;
      end else if(bg_native_sync[2]||
          !bgack_native_sync[2]||!berr_native_sync[2]||interrupted_native_sync[1]||
          raw_loss_latched)fault<=1;

      if(!native_enable)begin
        peripheral_state<=P_IDLE;peripheral_capture_ready<=0;
        peripheral_done<=0;peripheral_vma_low<=0;
      end else case(peripheral_state)
        P_IDLE:begin
          peripheral_capture_ready<=0;peripheral_done<=0;peripheral_vma_low<=0;
          if(peripheral_req)peripheral_state<=P_WAIT_FALL;
        end
        P_WAIT_FALL:if(e_fall)begin
          peripheral_vma_low<=1;peripheral_state<=P_WAIT_RISE;
        end
        P_WAIT_RISE:if(e_rise)begin
          peripheral_capture_ready<=1;peripheral_state<=P_WAIT_END;
        end
        P_WAIT_END:if(e_fall)begin peripheral_done<=1;peripheral_state<=P_DONE;end
        P_DONE:if(!peripheral_req)begin
          peripheral_done<=0;peripheral_vma_low<=0;
          peripheral_capture_ready<=0;peripheral_state<=P_IDLE;
        end
        default:fault<=1;
      endcase
    end
  end
endmodule
