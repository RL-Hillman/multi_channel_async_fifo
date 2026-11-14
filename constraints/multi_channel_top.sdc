# Clock definitions - 100 MHz

create_clock -name rd_clk \
    -period 10.000 [get_ports rd_clk]

create_clock -name wr_clk_0 \
    -period 10.000 [get_ports {wr_clk_i[0]}]

create_clock -name wr_clk_1 \
    -period 10.000 [get_ports {wr_clk_i[1]}]

create_clock -name wr_clk_2 \
    -period 10.000 [get_ports {wr_clk_i[2]}]

create_clock -name wr_clk_3 \
    -period 10.000 [get_ports {wr_clk_i[3]}]
# Independent asynchronous clock domains
set_clock_groups -asynchronous \
    -group [get_clocks rd_clk] \
    -group [get_clocks wr_clk_0] \
    -group [get_clocks wr_clk_1] \
    -group [get_clocks wr_clk_2] \
    -group [get_clocks wr_clk_3]
