
module rr_arbiter #(
    parameter int unsigned NUM_CHANNELS = 4
)(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [NUM_CHANNELS-1:0] req_i,
    input  logic                    grant_ready_i,

    output logic [NUM_CHANNELS-1:0] grant_o,
    output logic                    grant_valid_o
);

    localparam int unsigned PTR_W =
        (NUM_CHANNELS > 1) ? $clog2(NUM_CHANNELS) : 1;

    logic [PTR_W-1:0] start_q;
    logic [PTR_W-1:0] grant_idx;
    logic             fire;


    // Sequential state update
    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            start_q <= '0;

        end else if (grant_valid_o) begin

            if (fire) begin
                // Successful transfer - move to next channel
                if (grant_idx == PTR_W'(NUM_CHANNELS - 1))
                    start_q <= '0;
                else
                    start_q <= grant_idx + 1'b1;

            end else begin
                // Stall - keep priority on selected channel
                start_q <= grant_idx;
            end
        end
    end



    // Combinational grant logic
    always_comb begin

        logic [PTR_W-1:0] index;

        // Default values
        grant_o       = '0;
        grant_valid_o = 1'b0;
        grant_idx     = '0;
        index         = '0;

        if (rst_n) begin

            for (int i = 0; i < NUM_CHANNELS; i++) begin

                index = PTR_W'((int'(start_q) + i) % NUM_CHANNELS);

                if (req_i[index] && !grant_valid_o) begin
                    grant_idx     = index;
                    grant_valid_o = 1'b1;
                end
            end

            if (grant_valid_o)
                grant_o[grant_idx] = 1'b1;

        end
    end


    assign fire = grant_valid_o && grant_ready_i;

endmodule
