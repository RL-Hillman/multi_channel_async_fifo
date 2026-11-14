# Clock scenario: slow_writes

create_clock -name rd_clk \
    -period 10.000 [get_ports rd_clk]

create_clock -name wr_clk_0 \
    -period 12.500 [get_ports {wr_clk_i[0]}]

create_clock -name wr_clk_1 \
    -period 14.286 [get_ports {wr_clk_i[1]}]

create_clock -name wr_clk_2 \
    -period 16.667 [get_ports {wr_clk_i[2]}]

create_clock -name wr_clk_3 \
    -period 20.000 [get_ports {wr_clk_i[3]}]
# Independent asynchronous clock domains
set_clock_groups -asynchronous \
    -group [get_clocks rd_clk] \
    -group [get_clocks wr_clk_0] \
    -group [get_clocks wr_clk_1] \
    -group [get_clocks wr_clk_2] \
    -group [get_clocks wr_clk_3]
