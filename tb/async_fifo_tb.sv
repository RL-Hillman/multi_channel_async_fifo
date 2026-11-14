
`timescale 1ns/1ps

// ============================================================
// ASYNCHRONOUS FIFO TESTBENCH
// ============================================================
// Verify:
// - FIFO data integrity and ordering
// - FULL and EMPTY behavior
// - Ready/Valid handshakes and backpressure
// - Binary and Gray-code pointer updates
// - Read/write pointer wraparound
// - Concurrent traffic with different clock ratios
// - Reset while data is buffered and clean restart
//
// Run with +CLOCK_MODE=0/1/2 to test different clock ratios.
// ============================================================

module async_fifo_tb;

    // Test configuration: word width, FIFO depth, pointer widths,
    // number of random-traffic words, and scoreboard capacity.
    localparam int unsigned DATA_WIDTH   = 8;
    localparam int unsigned DEPTH        = 8;
    localparam int unsigned ADDR_W       = $clog2(DEPTH);
    localparam int unsigned PTR_W        = ADDR_W + 1;
    localparam int unsigned RANDOM_WORDS = 180;
    localparam int unsigned MAX_WORDS    = 512;

    // Clock configuration. Half-periods are specified in ns.
    int clock_mode = 0;
    int wr_half = 5;
    int rd_half = 7;

    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;

    // Select the clock ratio and generate the write clock.
    initial begin
        if (!$value$plusargs("CLOCK_MODE=%d", clock_mode))
            clock_mode = 0;

        case (clock_mode)
            0: begin wr_half = 5;  rd_half = 7;  end // Similar speeds
            1: begin wr_half = 2;  rd_half = 17; end // Fast writer, slow reader
            2: begin wr_half = 19; rd_half = 2;  end // Slow writer, fast reader
            default: $fatal(1, "CLOCK_MODE must be 0, 1, or 2");
        endcase

        forever #(wr_half) wr_clk = ~wr_clk;
    end

    // Generate the independent read clock.
    initial begin
        #0.5; // Avoid simultaneous rising edges in the testbench.
        forever #(rd_half) rd_clk = ~rd_clk;
    end

    // ------------------------------------------------------------
    // DUT INTERFACE
    // Initialize both resets active and both handshakes idle.
    // ------------------------------------------------------------

    logic wr_rst_n = 1'b0;
    logic rd_rst_n = 1'b0;

    logic [DATA_WIDTH-1:0] wr_data_i = '0;
    logic wr_valid_i = 1'b0;
    wire  wr_ready_o;

    wire [DATA_WIDTH-1:0] rd_data_o;
    wire  rd_valid_o;
    logic rd_ready_i = 1'b0;

    // Instantiate the asynchronous FIFO under test.
    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .wr_clk    (wr_clk),
        .wr_rst_n  (wr_rst_n),
        .wr_data_i (wr_data_i),
        .wr_valid_i(wr_valid_i),
        .wr_ready_o(wr_ready_o),
        .rd_clk    (rd_clk),
        .rd_rst_n  (rd_rst_n),
        .rd_data_o (rd_data_o),
        .rd_valid_o(rd_valid_o),
        .rd_ready_i(rd_ready_i)
    );

    // ------------------------------------------------------------
    // SCOREBOARD AND COVERAGE COUNTERS
    // ------------------------------------------------------------

    // Store every accepted write for later comparison with
    // the FIFO output. This verifies data integrity and ordering.
    logic [DATA_WIDTH-1:0] expected [0:MAX_WORDS-1];

    // Count accepted write and read transactions.
    int unsigned write_count = 0;
    int unsigned read_count = 0;

    // Track pointer address wraparound.
    int unsigned write_wraps = 0;
    int unsigned read_wraps = 0;

    // Coverage flags: confirm that blocked writes and reads
    // without valid data actually occur during the test.
    bit saw_full = 0;
    bit saw_empty = 0;


    // ============================================================
    // WRITE MONITOR
    // ============================================================
    // Monitor accepted writes and verify:
    // 1. Only accepted data enters the scoreboard.
    // 2. The binary write pointer advances correctly.
    // 3. Each Gray-code transition changes exactly one bit.
    // 4. Address wraparound and backpressure are exercised.
    // ============================================================

    always @(posedge wr_clk or negedge wr_rst_n) begin : monitor_write
        logic [PTR_W-1:0] old_bin, old_gray;
        bit fire;

        // Reset the scoreboard write index.
        if (!wr_rst_n) begin
            write_count = 0;
        end else begin

            // Save pointer values before the DUT updates them.
            old_bin = dut.wbin_q;
            old_gray = dut.wgray_q;

            // A write is accepted only when VALID and READY are high.
            fire = wr_valid_i && wr_ready_o;

            // Coverage: detect a write attempt blocked by READY=0.
            if (wr_valid_i && !wr_ready_o)
                saw_full = 1;

            if (fire) begin

                // Check: prevent writing outside scoreboard bounds.
                if (write_count >= MAX_WORDS)
                    $fatal(1, "Increase MAX_WORDS");

                // Record the accepted word for future read comparison.
                expected[write_count] = wr_data_i;
                write_count++;

                // Coverage: count transitions from the last
                // FIFO memory address back to address zero.
                if (old_bin[ADDR_W-1:0] == ADDR_W'(DEPTH-1))
                    write_wraps++;
            end

            // Wait 1 ps for nonblocking assignments (NBA)
            // to update the DUT registers.
            #0.001;

            // Check: the binary write pointer increments by exactly
            // one on an accepted write and remains unchanged otherwise.
            if (dut.wbin_q !== (old_bin + PTR_W'(fire)))
                $fatal(1, "Write pointer mismatch");

            // Check: every accepted write causes exactly one bit
            // to change in the Gray-coded write pointer.
            if (fire && !$onehot(dut.wgray_q ^ old_gray))
                $fatal(1, "Write Gray pointer changed by != 1 bit");
        end
    end


    // ============================================================
    // READ MONITOR
    // ============================================================
    // Monitor accepted reads and verify:
    // 1. No unexpected reads or underflow.
    // 2. Every output word matches the expected FIFO order.
    // 3. The binary read pointer advances correctly.
    // 4. Each Gray-code transition changes exactly one bit.
    // ============================================================

    always @(posedge rd_clk or negedge rd_rst_n) begin : monitor_read
        logic [PTR_W-1:0] old_bin, old_gray;
        bit fire;

        // Reset the scoreboard read index.
        if (!rd_rst_n) begin
            read_count = 0;
        end else begin

            // Save pointer values before the DUT updates them.
            old_bin = dut.rbin_q;
            old_gray = dut.rgray_q;

            // A read is accepted only when VALID and READY are high.
            fire = rd_valid_o && rd_ready_i;

            // Coverage: detect a read request while no valid
            // output word is available.
            if (rd_ready_i && !rd_valid_o)
                saw_empty = 1;

            if (fire) begin

                // Check: reject reads that exceed the number
                // of previously accepted writes.
                if (read_count >= write_count)
                    $fatal(1,
                        "Underflow / unexpected read: read=%0d write=%0d",
                        read_count, write_count);

                // Check: the output word must match the next
                // expected word, preserving FIFO ordering.
                if (rd_data_o !== expected[read_count])
                    $fatal(1,
                        "Data mismatch at %0d: expected %h got %h",
                        read_count, expected[read_count], rd_data_o);

                read_count++;

                // Coverage: count read-pointer address wraparound.
                if (old_bin[ADDR_W-1:0] == ADDR_W'(DEPTH-1))
                    read_wraps++;
            end

            // Wait for the DUT's NBA pointer updates.
            #0.001;

            // Check: the binary read pointer increments once
            // per accepted read and otherwise remains unchanged.
            if (dut.rbin_q !== (old_bin + PTR_W'(fire)))
                $fatal(1, "Read pointer mismatch");

            // Check: exactly one Gray-code bit changes
            // after an accepted read.
            if (fire && !$onehot(dut.rgray_q ^ old_gray))
                $fatal(1, "Read Gray pointer changed by != 1 bit");
        end
    end


    // ============================================================
    // TASK: SEND ONE WORD
    // ============================================================
    // Drive a word on the falling write-clock edge.
    // Keep VALID asserted until the FIFO accepts the word.
    // ============================================================

    task automatic send_word(input logic [DATA_WIDTH-1:0] value);

        @(negedge wr_clk);
        wr_data_i = value;
        wr_valid_i = 1'b1;

        // Wait for a write-clock edge with READY asserted.
        do @(posedge wr_clk);
        while (wr_ready_o !== 1'b1);

        @(negedge wr_clk);
        wr_valid_i = 1'b0;
    endtask


    // ============================================================
    // TASK: WAIT FOR EXPECTED READ COUNT
    // ============================================================
    // Wait until the requested number of reads is completed.
    // Use a timeout to detect stalled or deadlocked FIFO behavior.
    // ============================================================

    task automatic wait_reads(
        input int unsigned target,
        input int max_rd_cycles
    );
        bit done;
        done = 0;

        for (int n = 0; n < max_rd_cycles && !done; n++) begin
            @(negedge rd_clk);
            if (read_count == target)
                done = 1;
        end

        // Check: fail if the expected number of reads
        // was not reached within the allowed clock cycles.
        if (!done)
            $fatal(1,
                "Read timeout: expected %0d received %0d written %0d",
                target, read_count, write_count);
    endtask


    // ============================================================
    // MAIN TEST SEQUENCE
    // ============================================================

    initial begin : run_test
        logic [31:0] rng;
        bit producer_done;
        int unsigned goal;
        int unsigned random_cycles;

        // Enable optional waveform dumping with +trace.
        if ($test$plusargs("trace")) begin
            $dumpfile("async_fifo_tb.vcd");
            $dumpvars(0, async_fifo_tb);
        end

        $display(
            "FIFO CLOCK_MODE=%0d (write period=%0d ns, read period=%0d ns)",
            clock_mode, 2*wr_half, 2*rd_half
        );

        // Hold both domains in reset for several clock cycles,
        // then release reset to begin testing.
        repeat (5) @(negedge wr_clk);
        @(negedge rd_clk);
        wr_rst_n = 1'b1;
        rd_rst_n = 1'b1;


        // ========================================================
        // PHASE 1: EMPTY FIFO / UNDERFLOW PREVENTION
        // ========================================================
        // Verify that requesting reads from an empty FIFO
        // does not produce valid data or unexpected transfers.
        // ========================================================

        @(negedge rd_clk);
        rd_ready_i = 1'b1;

        repeat (15) begin
            @(negedge rd_clk);

            // Check: output VALID must remain low
            // while the FIFO contains no data.
            if (rd_valid_o !== 1'b0)
                $fatal(1, "Nonempty output on empty FIFO");
        end

        rd_ready_i = 1'b0;

        // Coverage check: verify that the read monitor observed
        // at least one read request without valid data.
        if (!saw_empty)
            $fatal(1, "EMPTY case not exercised");

        $display("PHASE 1: EMPTY and underflow prevention - OK");


        // ========================================================
        // PHASE 2: FULL FIFO / BACKPRESSURE / ORDERED DRAIN
        // ========================================================
        // Fill the FIFO completely, attempt an additional write,
        // then enable reading and verify correct recovery.
        // ========================================================

        // Fill all DEPTH entries while the consumer is blocked.
        for (int i = 0; i < DEPTH; i++)
            send_word(DATA_WIDTH'(32'h10 + i));

        @(negedge wr_clk);

        // Check: after DEPTH accepted writes, the FIFO
        // must assert FULL and deassert write READY.
        if (wr_ready_o !== 1'b0 || dut.wr_full_q !== 1'b1)
            $fatal(1, "FULL not asserted after DEPTH writes");


        // Attempt one additional write while the FIFO is full.
        // The producer must wait until the consumer frees space.
        fork
            begin
                send_word(8'hEE);
            end

            begin
                repeat (5) @(negedge wr_clk);

                // Check: write READY must stay low
                // until at least one word has been read.
                if (wr_ready_o !== 1'b0)
                    $fatal(1, "FULL released without a read");

                @(negedge rd_clk);
                rd_ready_i = 1'b1;
            end
        join

        // Check: all DEPTH original words plus the extra
        // stalled word must eventually be read.
        // The read monitor checks their ordering and values.
        wait_reads(DEPTH+1, 300);

        @(negedge rd_clk);

        // Check: after draining all words, output VALID
        // must be low and write/read counts must match.
        if (rd_valid_o !== 1'b0 || write_count != read_count)
            $fatal(1, "FIFO not empty after full drain");

        rd_ready_i = 1'b0;

        // Coverage check: confirm that a write attempt
        // was actually blocked during this test.
        if (!saw_full)
            $fatal(1, "FULL/backpressure not exercised");

        $display(
            "PHASE 2: FULL, blocked write, delayed release, ordered drain - OK"
        );


        // ========================================================
        // PHASE 3: CONCURRENT TRAFFIC / WRAPAROUND
        // ========================================================
        // Send many words while applying varying read backpressure.
        // Verify data ordering, pointer wraparound, and completion.
        // ========================================================

        producer_done = 0;
        rng = 32'h6D29_14AC;
        goal = write_count + RANDOM_WORDS;
        random_cycles = 0;

        fork
            begin : producer

                // Generate RANDOM_WORDS with varying idle gaps
                // between successive write transactions.
                for (int i = 0; i < RANDOM_WORDS; i++) begin
                    repeat (i % 4) @(negedge wr_clk);
                    send_word(DATA_WIDTH'(32'h80 + i));
                end

                producer_done = 1;
            end

            begin : consumer

                // Apply deterministic pseudo-random backpressure
                // by changing read READY using an LFSR.
                while ((read_count < goal || !producer_done) &&
                       random_cycles < 10000) begin

                    @(negedge rd_clk);

                    rng = {
                        rng[30:0],
                        rng[31] ^ rng[21] ^ rng[1] ^ rng[0]
                    };

                    rd_ready_i = rng[0] | rng[3];
                    random_cycles++;
                end

                // Check: all intended words must be read,
                // and the producer must finish before timeout.
                if (read_count != goal || !producer_done)
                    $fatal(1,
                        "Random traffic stalled: reads=%0d goal=%0d writes=%0d",
                        read_count, goal, write_count);

                @(negedge rd_clk);
                rd_ready_i = 1'b0;
            end
        join

        // Check: all accepted writes must be consumed.
        // Coverage: both read and write pointers must
        // complete at least two address wraparounds.
        if (write_count != read_count ||
            write_wraps < 2 ||
            read_wraps < 2)
            $fatal(1, "Wrap/scoreboard coverage failure");

        $display(
            "PHASE 3: simultaneous random traffic, wraps, data integrity - OK"
        );


        // ========================================================
        // PHASE 4: RESET WITH BUFFERED DATA / CLEAN RESTART
        // ========================================================
        // Reset both clock domains while the FIFO contains data.
        // Verify stale words are discarded and normal operation
        // resumes correctly after reset release.
        // ========================================================

        // Write several words without consuming them.
        for (int i = 0; i < DEPTH/2; i++)
            send_word(DATA_WIDTH'(32'hC0 + i));

        repeat (5) @(negedge rd_clk);

        // Check: output VALID must indicate buffered data
        // before reset is asserted.
        if (!rd_valid_o)
            $fatal(1, "Expected buffered data before reset");

        // Assert reset in both clock domains.
        @(negedge wr_clk);
        wr_rst_n = 1'b0;
        rd_rst_n = 1'b0;

        #0.001;

        // Check: reset must block write acceptance
        // and prevent valid read data from being presented.
        if (wr_ready_o || rd_valid_o)
            $fatal(1, "Reset did not block FIFO interfaces");

        // Hold reset for multiple clock cycles, then release.
        repeat (4) @(negedge wr_clk);
        @(negedge rd_clk);
        wr_rst_n = 1'b1;
        rd_rst_n = 1'b1;

        repeat (8) @(negedge rd_clk);

        // Check: data stored before reset must not
        // reappear as valid output data.
        if (rd_valid_o)
            $fatal(1, "Stale word after reset");

        // Verify that the FIFO accepts new data after reset.
        send_word(8'hA9);

        @(negedge rd_clk);
        rd_ready_i = 1'b1;

        // Check: the new word must be read successfully.
        wait_reads(1, 200);

        @(negedge rd_clk);

        // Check: exactly one new word was written and read,
        // and the FIFO must return to the empty state.
        if (rd_valid_o || write_count != 1 || read_count != 1)
            $fatal(1, "Restart after reset failed");

        rd_ready_i = 1'b0;

        $display(
            "PHASE 4: reset with buffered data and restart - OK"
        );


        // All directed and concurrent tests completed successfully.
        $display(
            "PASS async_fifo_tb mode=%0d: FULL, EMPTY, Gray, wrap, clocks, reset",
            clock_mode
        );

        $finish;
    end


    // ============================================================
    // GLOBAL TEST TIMEOUT
    // ============================================================
    // Prevent the simulation from hanging indefinitely
    // if a test phase encounters a deadlock or stalls.
    // ============================================================

    initial begin
        #300000;
        $fatal(1, "Global FIFO test timeout");
    end

endmodule
