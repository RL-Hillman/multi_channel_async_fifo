
module multi_channel_top #(
    parameter int unsigned NUM_CHANNELS = 4,
    parameter int unsigned DATA_WIDTH   = 32,
    parameter int unsigned FIFO_DEPTH   = 16
)(
    // Common asynchronous, active-low reset.
    input  logic                                   global_rst_n,

    // Independent input streams, each with its own write clock.
    input  logic [NUM_CHANNELS-1:0]                wr_clk_i,
    input  logic [NUM_CHANNELS-1:0][DATA_WIDTH-1:0] wr_data_i,
    input  logic [NUM_CHANNELS-1:0]                wr_valid_i,
    output logic [NUM_CHANNELS-1:0]                wr_ready_o,

    // Shared read/output clock domain.
    input  logic                                   rd_clk,
    output logic [DATA_WIDTH-1:0]                  out_data_o,
    output logic [NUM_CHANNELS-1:0]                out_grant_o,
    output logic                                   out_valid_o,
    input  logic                                   out_ready_i
);

    // 1) Reset released synchronously in each independent clock domain.
    logic [NUM_CHANNELS-1:0] wr_rst_n;
    logic                    rd_rst_n;

    reset_sync u_read_reset_sync (
        .clk    (rd_clk),
        .arst_n (global_rst_n),
        .srst_n (rd_rst_n)
    );

    // 2) FIFO outputs are all in the shared rd_clk domain.
    logic [NUM_CHANNELS-1:0][DATA_WIDTH-1:0] fifo_rd_data;
    logic [NUM_CHANNELS-1:0]                 fifo_rd_valid;
    logic [NUM_CHANNELS-1:0]                 fifo_rd_ready;

    for (genvar ch = 0; ch < NUM_CHANNELS; ch++) begin : gen_channels
        reset_sync u_write_reset_sync (
            .clk    (wr_clk_i[ch]),
            .arst_n (global_rst_n),
            .srst_n (wr_rst_n[ch])
        );

        async_fifo #(
            .DATA_WIDTH (DATA_WIDTH),
            .DEPTH      (FIFO_DEPTH)
        ) u_async_fifo (
            .wr_clk     (wr_clk_i[ch]),
            .wr_rst_n   (wr_rst_n[ch]),
            .wr_data_i  (wr_data_i[ch]),
            .wr_valid_i (wr_valid_i[ch]),
            .wr_ready_o (wr_ready_o[ch]),

            .rd_clk     (rd_clk),
            .rd_rst_n   (rd_rst_n),
            .rd_data_o  (fifo_rd_data[ch]),
            .rd_valid_o (fifo_rd_valid[ch]),
            .rd_ready_i (fifo_rd_ready[ch])
        );
    end

    // 3) Select a channel that has a valid word to transfer.
    logic [NUM_CHANNELS-1:0] grant;
    logic                    grant_valid;
    logic                    regslice_in_ready;

    rr_arbiter #(
        .NUM_CHANNELS (NUM_CHANNELS)
    ) u_rr_arbiter (
        .clk           (rd_clk),
        .rst_n         (rd_rst_n),
        .req_i         (fifo_rd_valid),
        .grant_ready_i (regslice_in_ready),
        .grant_o       (grant),
        .grant_valid_o (grant_valid)
    );

    // 4) The grant is one-hot; route only the selected word.
    logic [DATA_WIDTH-1:0] mux_data;

    always_comb begin
        mux_data = '0;
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            if (grant[ch])
                mux_data = fifo_rd_data[ch];
        end
    end

    // Only the selected FIFO can advance, and only when the regslice is ready to accept its data.
    for (genvar ch = 0; ch < NUM_CHANNELS; ch++) begin : gen_read_ready
        assign fifo_rd_ready[ch] = grant[ch] && regslice_in_ready;
    end

    // 5) Register data and its channel grant together.
    stream_regslice #(
        .DATA_WIDTH (DATA_WIDTH + NUM_CHANNELS)
    ) u_output_regslice (
        .clk         (rd_clk),
        .rst_n       (rd_rst_n),
        .in_data_i   ({grant, mux_data}),
        .in_valid_i  (grant_valid),
        .in_ready_o  (regslice_in_ready),
        .out_data_o  ({out_grant_o, out_data_o}),
        .out_valid_o (out_valid_o),
        .out_ready_i (out_ready_i)
    );

endmodule
