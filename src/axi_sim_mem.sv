// Copyright (c) 2020 ETH Zurich and University of Bologna
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Andreas Kurth <akurth@iis.ee.ethz.ch>
// - Samuel Riedel <sriedel@iis.ee.ethz.ch>
// - Michael Rogenmoser <michaero@iis.ee.ethz.ch>
// - Thomas Benz <tbenz@iis.ee.ethz.ch>

`include "axi/typedef.svh"

/// Infinite (Simulation-Only) Memory with AXI Slave Port
///
/// The memory array is named `mem`, and it is *not* initialized or reset.  This makes it possible to
/// load the memory of this module in simulation with an external `$readmem*` command, e.g.,
/// ```sv
/// axi_sim_mem #( ... ) i_sim_mem ( ... );
/// initial begin
///   $readmemh("file_with_memory_addrs_and_data.mem", i_sim_mem.mem);
///   $readmemh("file_with_memory_addrs_and_read_errors.mem", i_sim_mem.rerr);
///   $readmemh("file_with_memory_addrs_and_write_errors.mem", i_sim_mem.werr);
/// end
/// ```
/// `mem` is addressed (or indexed) byte-wise with `AddrWidth`-wide addresses.
///
/// This module does not support atomic operations (ATOPs).
module axi_sim_mem #(
  /// AXI Address Width
  parameter int unsigned AddrWidth = 32'd0,
  /// AXI Data Width
  parameter int unsigned DataWidth = 32'd0,
  /// AXI ID Width
  parameter int unsigned IdWidth = 32'd0,
  /// AXI User Width.
  parameter int unsigned UserWidth = 32'd0,
  /// Number of request ports
  parameter int unsigned NumPorts  = 32'd1,
  /// AXI4 request struct definition
  parameter type axi_req_t = logic,
  /// AXI4 response struct definition
  parameter type axi_rsp_t = logic,
  /// Warn on accesses to uninitialized bytes
  parameter bit WarnUninitialized = 1'b0,
  /// Default value for uninitialized memory (undefined, zeros, ones, random)
  parameter UninitializedData = "undefined",
  /// Clear error on access
  parameter bit ClearErrOnAccess = 1'b0,
  /// Application delay (measured after rising clock edge)
  parameter time ApplDelay = 0ps,
  /// Acquisition delay (measured after rising clock edge)
  parameter time AcqDelay = 0ps
) (
  /// Rising-edge clock
  input  logic clk_i,
  /// Active-low reset
  input  logic rst_ni,
  /// AXI4 request struct
  input  axi_req_t [NumPorts-1:0] axi_req_i,
  /// AXI4 response struct
  output axi_rsp_t [NumPorts-1:0] axi_rsp_o,
  /// Memory monitor write valid.  All `mon_w_*` outputs are only valid if this signal is high.
  /// A write to the memory is visible on the `mon_w_*` outputs in the clock cycle after it has
  /// happened.
  output logic [NumPorts-1:0]                mon_w_valid_o,
  /// Memory monitor write address
  output logic [NumPorts-1:0][AddrWidth-1:0] mon_w_addr_o,
  /// Memory monitor write data
  output logic [NumPorts-1:0][DataWidth-1:0] mon_w_data_o,
  /// Memory monitor write ID
  output logic [NumPorts-1:0][IdWidth-1:0]   mon_w_id_o,
  /// Memory monitor write user
  output logic [NumPorts-1:0][UserWidth-1:0] mon_w_user_o,
  /// Memory monitor write beat count
  output axi_pkg::len_t [NumPorts-1:0]       mon_w_beat_count_o,
  /// Memory monitor write last
  output logic [NumPorts-1:0]                mon_w_last_o,
  /// Memory monitor read valid.  All `mon_r_*` outputs are only valid if this signal is high.
  /// A read from the memory is visible on the `mon_w_*` outputs in the clock cycle after it has
  /// happened.
  output logic [NumPorts-1:0]                mon_r_valid_o,
  /// Memory monitor read address
  output logic [NumPorts-1:0][AddrWidth-1:0] mon_r_addr_o,
  /// Memory monitor read data
  output logic [NumPorts-1:0][DataWidth-1:0] mon_r_data_o,
  /// Memory monitor read ID
  output logic [NumPorts-1:0][IdWidth-1:0]   mon_r_id_o,
  /// Memory monitor read user
  output logic [NumPorts-1:0][UserWidth-1:0] mon_r_user_o,
  /// Memory monitor read beat count
  output axi_pkg::len_t [NumPorts-1:0]       mon_r_beat_count_o,
  /// Memory monitor read last
  output logic [NumPorts-1:0]                mon_r_last_o
);

  localparam int unsigned StrbWidth = DataWidth / 8;
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdWidth-1:0]   id_t;
  typedef logic [StrbWidth-1:0] strb_t;
  typedef logic [UserWidth-1:0] user_t;
  `AXI_TYPEDEF_AW_CHAN_T(aw_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_W_CHAN_T(w_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_B_CHAN_T(b_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(ar_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_R_CHAN_T(r_t, data_t, id_t, user_t)

  typedef struct packed {
    logic                 valid;
    logic [AddrWidth-1:0] addr;
    logic [DataWidth-1:0] data;
    logic [IdWidth-1:0]   id;
    logic [UserWidth-1:0] user;
    axi_pkg::len_t        beat_count;
    logic                 last;
  } monitor_t;

  monitor_t [NumPorts-1:0] mon_w, mon_r;
  logic [7:0]     mem[addr_t];
  axi_pkg::resp_t rerr[addr_t] = '{default: 2'b0}; // default: 'axi_pkg::RESP_OKAY'
  axi_pkg::resp_t werr[addr_t] = '{default: 2'b0}; // default: 'axi_pkg::RESP_OKAY'
  // - Verilator cannot determine the type of 'axi_pkg::RESP_OKAY' in this context.
  //   The 'axi_pkg::RESP_OKAY' is expanded to 0 for Verilator compatibility.

  // error happened in write burst
  axi_pkg::resp_t [NumPorts-1:0] error_happened = axi_pkg::RESP_OKAY;

  for (genvar i = 0; i < NumPorts; i++) begin
    initial begin
      automatic ar_t ar_queue[$];
      automatic aw_t aw_queue[$];
      automatic b_t b_queue[$];
      automatic shortint unsigned r_cnt = 0, w_cnt = 0;
      axi_rsp_o[i] = '0;
      // Monitor interface
      mon_w[i] = '0;
      mon_r[i] = '0;
      wait (rst_ni);
      fork
        // AW
        forever begin
          @(posedge clk_i);
          #(ApplDelay);
          axi_rsp_o[i].aw_ready = 1'b1;
          #(AcqDelay - ApplDelay);
          if (axi_req_i[i].aw_valid) begin
            automatic aw_t aw = axi_req_i[i].aw;
            aw_queue.push_back(aw);
          end
        end
        // W
        forever begin
          @(posedge clk_i);
          #(ApplDelay);
          axi_rsp_o[i].w_ready = 1'b0;
          mon_w[i] = '0;
          if (aw_queue.size() != 0) begin
            axi_rsp_o[i].w_ready = 1'b1;
            #(AcqDelay - ApplDelay);
            if (axi_req_i[i].w_valid) begin
              automatic axi_pkg::burst_t burst = aw_queue[0].burst;
              automatic axi_pkg::len_t len = aw_queue[0].len;
              automatic axi_pkg::size_t size = aw_queue[0].size;
              automatic addr_t addr = axi_pkg::beat_addr(aw_queue[0].addr, size, len, burst,
                  w_cnt);
              mon_w[i].valid = 1'b1;
              mon_w[i].addr = addr;
              mon_w[i].data = axi_req_i[i].w.data;
              mon_w[i].id = aw_queue[0].id;
              mon_w[i].user = aw_queue[0].user;
              mon_w[i].beat_count = w_cnt;
              for (shortint unsigned
                  i_byte = axi_pkg::beat_lower_byte(aw_queue[0].addr, size, len, burst, StrbWidth, w_cnt);
                  i_byte <= axi_pkg::beat_upper_byte(aw_queue[0].addr, size, len, burst, StrbWidth, w_cnt);
                  i_byte++) begin
                if (axi_req_i[i].w.strb[i_byte]) begin
                  automatic addr_t byte_addr = (addr / StrbWidth) * StrbWidth + i_byte;
                  mem[byte_addr] = axi_req_i[i].w.data[i_byte*8+:8];
                  error_happened[i] = axi_pkg::resp_precedence(werr[byte_addr], error_happened[i]);
                  if (ClearErrOnAccess)
                    werr[byte_addr] = axi_pkg::RESP_OKAY;
                end
              end
              if (w_cnt == aw_queue[0].len) begin
                automatic b_t b_beat = '0;
                assert (axi_req_i[i].w.last) else $error("Expected last beat of W burst!");
                b_beat.id = aw_queue[0].id;
                b_beat.resp = error_happened[i];
                b_beat.user = aw_queue[0].user;
                b_queue.push_back(b_beat);
                w_cnt = 0;
                mon_w[i].last = 1'b1;
                error_happened[i] = axi_pkg::RESP_OKAY;
                void'(aw_queue.pop_front());
              end else begin
                assert (!axi_req_i[i].w.last) else $error("Did not expect last beat of W burst!");
                w_cnt++;
              end
            end
          end
        end
        // B
        forever begin
          @(posedge clk_i);
          #(ApplDelay);
          axi_rsp_o[i].b_valid = 1'b0;
          if (b_queue.size() != 0) begin
            axi_rsp_o[i].b = b_queue[0];
            axi_rsp_o[i].b_valid = 1'b1;
            #(AcqDelay - ApplDelay);
            if (axi_req_i[i].b_ready) begin
              void'(b_queue.pop_front());
            end
          end
        end
        // AR
        forever begin
          @(posedge clk_i);
          #(ApplDelay);
          axi_rsp_o[i].ar_ready = 1'b1;
          #(AcqDelay - ApplDelay);
          if (axi_req_i[i].ar_valid) begin
            automatic ar_t ar = axi_req_i[i].ar;
            ar_queue.push_back(ar);
          end
        end
        // R
        forever begin
          @(posedge clk_i);
          #(ApplDelay);
          axi_rsp_o[i].r_valid = 1'b0;
          mon_r[i] = '0;
          if (ar_queue.size() != 0) begin
            automatic axi_pkg::burst_t burst = ar_queue[0].burst;
            automatic axi_pkg::len_t len = ar_queue[0].len;
            automatic axi_pkg::size_t size = ar_queue[0].size;
            automatic addr_t addr = axi_pkg::beat_addr(ar_queue[0].addr, size, len, burst, r_cnt);
            automatic r_t r_beat = '0;
            automatic data_t r_data = 'x; // compatibility reasons
            r_beat.data = 'x;
            r_beat.id = ar_queue[0].id;
            r_beat.resp = axi_pkg::RESP_OKAY;
            r_beat.user = ar_queue[0].user;
            for (shortint unsigned
                i_byte = axi_pkg::beat_lower_byte(ar_queue[0].addr, size, len, burst, StrbWidth, r_cnt);
                i_byte <= axi_pkg::beat_upper_byte(ar_queue[0].addr, size, len, burst, StrbWidth, r_cnt);
                i_byte++) begin
              automatic addr_t byte_addr = (addr / StrbWidth) * StrbWidth + i_byte;
              if (!mem.exists(byte_addr)) begin
                if (WarnUninitialized) begin
                  $warning("Access to non-initialized byte at address 0x%016x by ID 0x%x.", byte_addr,
                      r_beat.id);
                end
                case (UninitializedData)
                  "random":
                    r_data[i_byte*8+:8] = $urandom;
                  "ones":
                    r_data[i_byte*8+:8] = '1;
                  "zeros":
                    r_data[i_byte*8+:8] = '0;
                  default: 
                    r_data[i_byte*8+:8] = 'x;
                endcase
              end else begin
                r_data[i_byte*8+:8] = mem[byte_addr];
              end
              r_beat.resp = axi_pkg::resp_precedence(rerr[byte_addr], r_beat.resp);
              if (ClearErrOnAccess & axi_req_i[i].r_ready) begin
                rerr[byte_addr] = axi_pkg::RESP_OKAY;
              end
            end
            r_beat.data = r_data;
            if (r_cnt == ar_queue[0].len) begin
              r_beat.last = 1'b1;
              mon_r[i].last = 1'b1;
            end
            axi_rsp_o[i].r = r_beat;
            axi_rsp_o[i].r_valid = 1'b1;
            mon_r[i].valid = 1'b1;
            mon_r[i].addr = addr;
            mon_r[i].data = r_beat.data;
            mon_r[i].id = r_beat.id;
            mon_r[i].user = ar_queue[0].user;
            mon_r[i].beat_count = r_cnt;
            #(AcqDelay - ApplDelay);
            while (!axi_req_i[i].r_ready) begin
              @(posedge clk_i);
              #(AcqDelay);
              mon_r[i] = '0;
            end
            if (r_beat.last) begin
              r_cnt = 0;
              void'(ar_queue.pop_front());
            end else begin
              r_cnt++;
            end
          end
        end
      join
    end

    // Assign the monitor output in the next clock cycle.  Rationale: We only know whether we are
    // writing until after `AcqDelay`.  This means we could only provide the monitoring output for
    // writes after `AcqDelay` in the same cycle, which is incompatible with ATI timing.  Thus, we
    // provide the monitoring output for writes (and for uniformity also for reads) in the next clock
    // cycle.
    initial begin
      mon_w_valid_o[i] = '0;
      mon_w_addr_o[i] = '0;
      mon_w_data_o[i] = '0;
      mon_w_id_o[i] = '0;
      mon_w_user_o[i] = '0;
      mon_w_beat_count_o[i] = '0;
      mon_w_last_o[i] = '0;
      mon_r_valid_o[i] = '0;
      mon_r_addr_o[i] = '0;
      mon_r_data_o[i] = '0;
      mon_r_id_o[i] = '0;
      mon_r_user_o[i] = '0;
      mon_r_beat_count_o[i] = '0;
      mon_r_last_o[i] = '0;
      wait (rst_ni);
      forever begin
        @(posedge clk_i);
        mon_w_valid_o[i] <= #(ApplDelay) mon_w[i].valid;
        mon_w_addr_o[i] <= #(ApplDelay) mon_w[i].addr;
        mon_w_data_o[i] <= #(ApplDelay) mon_w[i].data;
        mon_w_id_o[i] <= #(ApplDelay) mon_w[i].id;
        mon_w_user_o[i] <= #(ApplDelay) mon_w[i].user;
        mon_w_beat_count_o[i] <= #(ApplDelay) mon_w[i].beat_count;
        mon_w_last_o[i] <= #(ApplDelay) mon_w[i].last;
        mon_r_valid_o[i] <= #(ApplDelay) mon_r[i].valid;
        mon_r_addr_o[i] <= #(ApplDelay) mon_r[i].addr;
        mon_r_data_o[i] <= #(ApplDelay) mon_r[i].data;
        mon_r_id_o[i] <= #(ApplDelay) mon_r[i].id;
        mon_r_user_o[i] <= #(ApplDelay) mon_r[i].user;
        mon_r_beat_count_o[i] <= #(ApplDelay) mon_r[i].beat_count;
        mon_r_last_o[i] <= #(ApplDelay) mon_r[i].last;
      end
    end
  end

  // Parameter Assertions
  initial begin
    assert (AddrWidth != 0) else $fatal("AddrWidth must be non-zero!", 1);
    assert (DataWidth != 0) else $fatal("DataWidth must be non-zero!", 1);
    assert (IdWidth != 0) else $fatal("IdWidth must be non-zero!", 1);
    assert (UserWidth != 0) else $fatal("UserWidth must be non-zero!", 1);
  end

endmodule


`include "axi/assign.svh"

/// Interface variant of [`axi_sim_mem`](module.axi_sim_mem).
///
/// See the documentation of the main module for the definition of ports and parameters.
module axi_sim_mem_intf #(
  parameter int unsigned AXI_ADDR_WIDTH = 32'd0,
  parameter int unsigned AXI_DATA_WIDTH = 32'd0,
  parameter int unsigned AXI_ID_WIDTH = 32'd0,
  parameter int unsigned AXI_USER_WIDTH = 32'd0,
  parameter bit WARN_UNINITIALIZED = 1'b0,
  parameter UNINITIALIZED_DATA = "undefined",
  parameter bit ClearErrOnAccess = 1'b0,
  parameter time APPL_DELAY = 0ps,
  parameter time ACQ_DELAY = 0ps
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  AXI_BUS.Slave                     axi_slv,
  output logic                      mon_w_valid_o,
  output logic [AXI_ADDR_WIDTH-1:0] mon_w_addr_o,
  output logic [AXI_DATA_WIDTH-1:0] mon_w_data_o,
  output logic [AXI_ID_WIDTH-1:0]   mon_w_id_o,
  output logic [AXI_USER_WIDTH-1:0] mon_w_user_o,
  output axi_pkg::len_t             mon_w_beat_count_o,
  output logic                      mon_w_last_o,
  output logic                      mon_r_valid_o,
  output logic [AXI_ADDR_WIDTH-1:0] mon_r_addr_o,
  output logic [AXI_DATA_WIDTH-1:0] mon_r_data_o,
  output logic [AXI_ID_WIDTH-1:0]   mon_r_id_o,
  output logic [AXI_USER_WIDTH-1:0] mon_r_user_o,
  output axi_pkg::len_t             mon_r_beat_count_o,
  output logic                      mon_r_last_o
);
  
  typedef logic [AXI_ADDR_WIDTH-1:0]   axi_addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   axi_data_t;
  typedef logic [AXI_ID_WIDTH-1:0]     axi_id_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] axi_strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   axi_user_t;
  `AXI_TYPEDEF_ALL(axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

  axi_req_t  axi_req;
  axi_resp_t axi_rsp;

  `AXI_ASSIGN_TO_REQ(axi_req, axi_slv)
  `AXI_ASSIGN_FROM_RESP(axi_slv, axi_rsp)

  axi_sim_mem #(
    .AddrWidth          (AXI_ADDR_WIDTH),
    .DataWidth          (AXI_DATA_WIDTH),
    .IdWidth            (AXI_ID_WIDTH),
    .UserWidth          (AXI_USER_WIDTH),
    .axi_req_t          (axi_req_t),
    .axi_rsp_t          (axi_resp_t),
    .WarnUninitialized  (WARN_UNINITIALIZED),
    .UninitializedData  (UNINITIALIZED_DATA),
    .ClearErrOnAccess   (ClearErrOnAccess),
    .ApplDelay          (APPL_DELAY),
    .AcqDelay           (ACQ_DELAY)
  ) i_sim_mem (
    .clk_i,
    .rst_ni,
    .axi_req_i (axi_req),
    .axi_rsp_o (axi_rsp),
    .mon_w_valid_o,
    .mon_w_addr_o,
    .mon_w_data_o,
    .mon_w_id_o,
    .mon_w_user_o,
    .mon_w_beat_count_o,
    .mon_w_last_o,
    .mon_r_valid_o,
    .mon_r_addr_o,
    .mon_r_data_o,
    .mon_r_id_o,
    .mon_r_user_o,
    .mon_r_beat_count_o,
    .mon_r_last_o
  );

endmodule

/// Mutliport interface variant of [`axi_sim_mem`](module.axi_sim_mem).
///
/// See the documentation of the main module for the definition of ports and parameters.
module axi_sim_mem_multiport_intf #(
  parameter int unsigned AXI_ADDR_WIDTH = 32'd0,
  parameter int unsigned AXI_DATA_WIDTH = 32'd0,
  parameter int unsigned AXI_ID_WIDTH = 32'd0,
  parameter int unsigned AXI_USER_WIDTH = 32'd0,
  parameter int unsigned NUM_PORTS = 32'd1,
  parameter bit WARN_UNINITIALIZED = 1'b0,
  parameter UNINITIALIZED_DATA = "undefined",
  parameter bit ClearErrOnAccess = 1'b0,
  parameter time APPL_DELAY = 0ps,
  parameter time ACQ_DELAY = 0ps
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  AXI_BUS.Slave                     axi_slv[NUM_PORTS],
  output logic [NUM_PORTS-1:0]                     mon_w_valid_o,
  output logic [NUM_PORTS-1:0][AXI_ADDR_WIDTH-1:0] mon_w_addr_o,
  output logic [NUM_PORTS-1:0][AXI_DATA_WIDTH-1:0] mon_w_data_o,
  output logic [NUM_PORTS-1:0][AXI_ID_WIDTH-1:0]   mon_w_id_o,
  output logic [NUM_PORTS-1:0][AXI_USER_WIDTH-1:0] mon_w_user_o,
  output axi_pkg::len_t [NUM_PORTS-1:0]            mon_w_beat_count_o,
  output logic [NUM_PORTS-1:0]                     mon_w_last_o,
  output logic [NUM_PORTS-1:0]                     mon_r_valid_o,
  output logic [NUM_PORTS-1:0][AXI_ADDR_WIDTH-1:0] mon_r_addr_o,
  output logic [NUM_PORTS-1:0][AXI_DATA_WIDTH-1:0] mon_r_data_o,
  output logic [NUM_PORTS-1:0][AXI_ID_WIDTH-1:0]   mon_r_id_o,
  output logic [NUM_PORTS-1:0][AXI_USER_WIDTH-1:0] mon_r_user_o,
  output axi_pkg::len_t [NUM_PORTS-1:0]            mon_r_beat_count_o,
  output logic [NUM_PORTS-1:0]                     mon_r_last_o
);

  typedef logic [AXI_ADDR_WIDTH-1:0]   axi_addr_t;
  typedef logic [AXI_DATA_WIDTH-1:0]   axi_data_t;
  typedef logic [AXI_ID_WIDTH-1:0]     axi_id_t;
  typedef logic [AXI_DATA_WIDTH/8-1:0] axi_strb_t;
  typedef logic [AXI_USER_WIDTH-1:0]   axi_user_t;
  `AXI_TYPEDEF_ALL(axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

  axi_req_t  [NUM_PORTS-1:0] axi_req;
  axi_resp_t [NUM_PORTS-1:0] axi_rsp;

  for (genvar i = 0; i < NUM_PORTS; i++) begin
    `AXI_ASSIGN_TO_REQ(axi_req[i], axi_slv[i])
    `AXI_ASSIGN_FROM_RESP(axi_slv[i], axi_rsp[i])
  end

  axi_sim_mem #(
    .AddrWidth          (AXI_ADDR_WIDTH),
    .DataWidth          (AXI_DATA_WIDTH),
    .IdWidth            (AXI_ID_WIDTH),
    .UserWidth          (AXI_USER_WIDTH),
    .NumPorts           (NUM_PORTS),
    .axi_req_t          (axi_req_t),
    .axi_rsp_t          (axi_resp_t),
    .WarnUninitialized  (WARN_UNINITIALIZED),
    .UninitializedData  (UNINITIALIZED_DATA),
    .ClearErrOnAccess   (ClearErrOnAccess),
    .ApplDelay          (APPL_DELAY),
    .AcqDelay           (ACQ_DELAY)
  ) i_sim_mem (
    .clk_i,
    .rst_ni,
    .axi_req_i (axi_req),
    .axi_rsp_o (axi_rsp),
    .mon_w_valid_o,
    .mon_w_addr_o,
    .mon_w_data_o,
    .mon_w_id_o,
    .mon_w_user_o,
    .mon_w_beat_count_o,
    .mon_w_last_o,
    .mon_r_valid_o,
    .mon_r_addr_o,
    .mon_r_data_o,
    .mon_r_id_o,
    .mon_r_user_o,
    .mon_r_beat_count_o,
    .mon_r_last_o
  );

endmodule
