
module reset_sync (
    input  logic clk,
    input  logic arst_n,
    output logic srst_n
);

    // Two rising-edge stages for reset synchronization.
    (* async_reg = "true" *) logic [1:0] sync_q;

    // Additional falling-edge stage for reset release.
    logic release_q;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n)
            sync_q <= 2'b00;
        else
            sync_q <= {sync_q[0], 1'b1};
    end

    always_ff @(negedge clk or negedge arst_n) begin
        if (!arst_n)
            release_q <= 1'b0;
        else
            release_q <= sync_q[1];
    end

    assign srst_n = release_q;

endmodule
