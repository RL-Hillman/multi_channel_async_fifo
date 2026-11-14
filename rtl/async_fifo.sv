
module async_fifo #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned DEPTH      = 16
)(
    // Write clock domain
    input  logic                  wr_clk,
    input  logic                  wr_rst_n,
    input  logic [DATA_WIDTH-1:0] wr_data_i,
    input  logic                  wr_valid_i,
    output logic                  wr_ready_o,

    // Read clock domain
    input  logic                  rd_clk,
    input  logic                  rd_rst_n,
    output logic [DATA_WIDTH-1:0] rd_data_o,
    output logic                  rd_valid_o,
    input  logic                  rd_ready_i
);

    // This implementation supports power-of-two depths of at least 2.
    localparam int unsigned ADDR_W = $clog2(DEPTH);
    localparam int unsigned PTR_W  = ADDR_W + 1;
    localparam logic [PTR_W-1:0] FULL_MASK =
        {2'b11, {(PTR_W-2){1'b0}}};

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH < 1 || DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "async_fifo: DATA_WIDTH >= 1 and power-of-two DEPTH >= 2 required");
    end
`endif

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Local pointers: binary for addressing, Gray for clock crossing.

    logic [PTR_W-1:0] wbin_q, wgray_q;
    logic [PTR_W-1:0] rbin_q, rgray_q;
    logic [PTR_W-1:0] wbin_next, wgray_next;
    logic [PTR_W-1:0] rbin_next, rgray_next;

    // Synchronize Gray-coded READ pointer into the WRITE domain.
    (* async_reg = "true" *) logic [PTR_W-1:0] rgray_wr_sync1;
    (* async_reg = "true" *) logic [PTR_W-1:0] rgray_wr_sync2;

    // Synchronize Gray-coded WRITE pointer into the READ domain.
    (* async_reg = "true" *) logic [PTR_W-1:0] wgray_rd_sync1;
    (* async_reg = "true" *) logic [PTR_W-1:0] wgray_rd_sync2;

    logic wr_full_q, rd_empty_q;
    logic wr_full_next, rd_empty_next;
    logic wr_fire, rd_fire;

    // Ready/Valid handshakes in their respective clock domains.
    assign wr_ready_o = wr_rst_n && !wr_full_q;
    assign rd_valid_o = rd_rst_n && !rd_empty_q;
    assign wr_fire  = wr_valid_i && wr_ready_o;
    assign rd_fire  = rd_valid_o && rd_ready_i;

    // Binary pointers include an extra wrap bit.
    assign wbin_next  = wbin_q + PTR_W'(wr_fire);
    assign rbin_next  = rbin_q + PTR_W'(rd_fire);
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;
    assign rgray_next = (rbin_next >> 1) ^ rbin_next;

    // FULL in write domain; EMPTY in read domain.
    assign wr_full_next  = (wgray_next == (rgray_wr_sync2 ^ FULL_MASK));
    assign rd_empty_next = (rgray_next == wgray_rd_sync2);

    // Write data only after a successful write-domain handshake.
    always_ff @(posedge wr_clk) begin
        if (wr_fire)
            mem[wbin_q[ADDR_W-1:0]] <= wr_data_i;
    end

    // First-word-fall-through style read: the current head is visible.
    // rd_data is meaningful only when rd_valid is asserted.
    assign rd_data_o = mem[rbin_q[ADDR_W-1:0]];

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wbin_q     <= '0;
            wgray_q    <= '0;
            wr_full_q  <= 1'b0;
        end else begin
            wbin_q     <= wbin_next;
            wgray_q    <= wgray_next;
            wr_full_q  <= wr_full_next;
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rbin_q     <= '0;
            rgray_q    <= '0;
            rd_empty_q <= 1'b1;
        end else begin
            rbin_q     <= rbin_next;
            rgray_q    <= rgray_next;
            rd_empty_q <= rd_empty_next;
        end
    end

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rgray_wr_sync1 <= '0;
            rgray_wr_sync2 <= '0;
        end else begin
            rgray_wr_sync1 <= rgray_q;
            rgray_wr_sync2 <= rgray_wr_sync1;
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wgray_rd_sync1 <= '0;
            wgray_rd_sync2 <= '0;
        end else begin
            wgray_rd_sync1 <= wgray_q;
            wgray_rd_sync2 <= wgray_rd_sync1;
        end
    end

endmodule
