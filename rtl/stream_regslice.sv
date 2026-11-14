
module stream_regslice #(
    parameter int unsigned DATA_WIDTH = 32
)(
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [DATA_WIDTH-1:0] in_data_i,
    input  logic                  in_valid_i,
    output logic                  in_ready_o,

    output logic [DATA_WIDTH-1:0] out_data_o,
    output logic                  out_valid_o,
    input  logic                  out_ready_i
);

    logic [DATA_WIDTH-1:0] data_q;
    logic                  valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_q <= 1'b0;
        end else if (in_ready_o) begin
            valid_q <= in_valid_i;

            if (in_valid_i)
                data_q <= in_data_i;
        end
    end

    assign in_ready_o  = rst_n && (!valid_q || out_ready_i);
    assign out_valid_o = rst_n && valid_q;
    assign out_data_o  = data_q;


endmodule
