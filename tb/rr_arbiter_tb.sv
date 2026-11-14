
`timescale 1ns/1ps

// ============================================================
// ROUND-ROBIN ARBITER TESTBENCH
// ============================================================
// Verify:
// - Correct round-robin grant selection
// - Idle and single-request behavior
// - One-hot-or-zero grant outputs
// - No grants to channels without requests
// - Stable arbitration under backpressure
// - Fairness and starvation prevention
// - Dynamic requests and randomized stalls
// - Reset recovery and initial priority
//
// A separate reference model predicts the expected grant.
// No FIFOs or output regslice are instantiated in this test.
// ============================================================

module rr_arbiter_tb;

    // --------------------------------------------------------
    // TEST CONFIGURATION
    // --------------------------------------------------------

    parameter int unsigned NUM_CHANNELS = 4;
    localparam int unsigned PTR_W =
        (NUM_CHANNELS > 1) ? $clog2(NUM_CHANNELS) : 1;

    // Generate a 100 MHz clock (10 ns period).
    logic clk = 1'b0;
    always #5 clk = ~clk;

    // --------------------------------------------------------
    // DUT INTERFACE
    // --------------------------------------------------------
    // req_i: channels requesting access
    // grant_ready_i: downstream consumer readiness
    // grant_o: selected channel (one-hot)
    // grant_valid_o: indicates a valid grant
    // --------------------------------------------------------

    logic rst_n = 1'b0;
    logic [NUM_CHANNELS-1:0] req_i = '0;
    logic grant_ready_i = 1'b0;

    wire [NUM_CHANNELS-1:0] grant_o;
    wire grant_valid_o;

    // Instantiate the round-robin arbiter under test.
    rr_arbiter #(
        .NUM_CHANNELS(NUM_CHANNELS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_i(req_i),
        .grant_ready_i(grant_ready_i),
        .grant_o(grant_o),
        .grant_valid_o(grant_valid_o)
    );


    // --------------------------------------------------------
    // REFERENCE MODEL AND COVERAGE COUNTERS
    // --------------------------------------------------------

    // Independent model of the next channel with priority.
    // The model advances only after a completed transfer.
    int model_start = 0;

    // Count how many times each channel receives service.
    int unsigned service_count [NUM_CHANNELS];

    // Number of completed transfers during which a
    // requesting channel waits without being selected.
    int unsigned age [NUM_CHANNELS];

    // Overall coverage counters.
    int unsigned transfers = 0;
    int unsigned stalls = 0;
    int unsigned fairness_checks = 0;


    // ============================================================
    // TASK: CHECK ONE ARBITRATION CYCLE
    // ============================================================
    // 1. Apply requests and downstream READY.
    // 2. Calculate the expected grant independently.
    // 3. Compare DUT outputs against the reference model.
    // 4. Check one-hot and request/grant validity.
    // 5. Check fairness and detect starvation.
    // 6. Update model priority after a completed transfer.
    // ============================================================

    task automatic check_cycle(
        input logic [NUM_CHANNELS-1:0] requests,
        input logic sink_ready
    );
        int chosen;
        int candidate;
        logic [NUM_CHANNELS-1:0] expected_grant;

        // Apply inputs on the falling clock edge to avoid
        // changing them at the DUT's rising sampling edge.
        @(negedge clk);
        req_i = requests;
        grant_ready_i = sink_ready;

        // Allow combinational grant logic to settle.
        #1;


        // --------------------------------------------------------
        // REFERENCE MODEL: EXPECTED ROUND-ROBIN GRANT
        // --------------------------------------------------------
        // Search from model_start and select the first channel
        // with an active request, wrapping around if necessary.
        // --------------------------------------------------------

        chosen = -1;
        expected_grant = '0;

        for (int offset = 0; offset < NUM_CHANNELS; offset++) begin
            candidate = (model_start + offset) % NUM_CHANNELS;

            if (chosen == -1 && requests[candidate])
                chosen = candidate;
        end

        // Generate the expected one-hot grant.
        // If no channel requests service, grant remains zero.
        if (chosen >= 0)
            expected_grant[chosen] = 1'b1;


        // --------------------------------------------------------
        // CHECK 1: CORRECT GRANT SELECTION
        // --------------------------------------------------------
        // Verify that the DUT selects exactly the channel
        // predicted by the independent round-robin model.
        // Also verify that VALID reflects grant availability.
        // --------------------------------------------------------

        if (grant_o !== expected_grant ||
            grant_valid_o !== (chosen >= 0))
            $fatal(1,
                "Arbiter mismatch: req=%b start=%0d ready=%b expected=%b got=%b valid=%b",
                requests, model_start, sink_ready,
                expected_grant, grant_o, grant_valid_o);


        // --------------------------------------------------------
        // CHECK 2: ONE-HOT-OR-ZERO GRANT
        // --------------------------------------------------------
        // Verify that at most one channel receives a grant.
        // Zero grants are allowed when no requests are active.
        // --------------------------------------------------------

        if (!$onehot0(grant_o))
            $fatal(1, "Grant not one-hot-or-zero");


        // --------------------------------------------------------
        // CHECK 3: GRANT ONLY REQUESTING CHANNELS
        // --------------------------------------------------------
        // Verify that every granted channel has an active
        // request. A channel must never receive an unsolicited
        // grant.
        // --------------------------------------------------------

        if ((grant_o & ~requests) != '0)
            $fatal(1, "Granted channel that did not request service");


        // --------------------------------------------------------
        // COVERAGE: BACKPRESSURE
        // --------------------------------------------------------
        // Count cycles with a valid candidate but no downstream
        // readiness. These cycles must not complete a transfer.
        // --------------------------------------------------------

        if (chosen >= 0 && !sink_ready)
            stalls++;


        // --------------------------------------------------------
        // CHECK 4: FAIRNESS / STARVATION
        // --------------------------------------------------------
        // Count completed transfers during which each channel
        // remains requesting but does not receive service.
        //
        // Fairness is measured in completed transfers rather
        // than clock cycles, since downstream stalls can last
        // indefinitely without being caused by the arbiter.
        // --------------------------------------------------------

        if (chosen >= 0 && sink_ready) begin

            for (int ch = 0; ch < NUM_CHANNELS; ch++) begin

                // Reset age if the channel stops requesting
                // or receives service in the current transfer.
                if (!requests[ch] || ch == chosen) begin
                    age[ch] = 0;

                end else begin
                    age[ch]++;

                    // Check: a continuously requesting channel
                    // must not wait for NUM_CHANNELS completed
                    // transfers without receiving service.
                    if (age[ch] >= NUM_CHANNELS)
                        $fatal(1,
                            "STARVATION: channel %0d waited %0d transfers",
                            ch, age[ch]);

                    // Coverage: count fairness observations.
                    fairness_checks++;
                end
            end

        end else begin

            // With no completed transfer, waiting age does
            // not increase. Clear age for inactive requests.
            for (int ch = 0; ch < NUM_CHANNELS; ch++)
                if (!requests[ch])
                    age[ch] = 0;
        end


        // --------------------------------------------------------
        // REFERENCE MODEL STATE UPDATE
        // --------------------------------------------------------
        // A transfer completes at the rising clock edge when
        // both a valid grant and downstream READY are present.
        //
        // Only a completed transfer advances round-robin
        // priority to the channel after the selected winner.
        // --------------------------------------------------------

        @(posedge clk);

        if (chosen >= 0 && sink_ready) begin
            service_count[chosen]++;
            transfers++;
            model_start = (chosen + 1) % NUM_CHANNELS;
        end

        // Allow the DUT's sequential state updates to settle.
        #1;

    endtask


    // ============================================================
    // MAIN TEST SEQUENCE
    // ============================================================

    initial begin : run_test

        logic [NUM_CHANNELS-1:0] pattern;
        logic [NUM_CHANNELS-1:0] req_pattern;
        logic [NUM_CHANNELS-1:0] prev_req;
        logic [31:0] rng;

        bit prior_stall;
        bit ready_next;

        // Initialize per-channel coverage counters.
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            service_count[ch] = 0;
            age[ch] = 0;
        end

        // Enable optional waveform dumping with +trace.
        if ($test$plusargs("trace")) begin
            $dumpfile("rr_arbiter_tb.vcd");
            $dumpvars(0, rr_arbiter_tb);
        end

        // Hold reset for three cycles before testing.
        repeat (3) @(negedge clk);
        rst_n = 1'b1;


        // ========================================================
        // PHASE 1: IDLE AND SINGLE-CHANNEL REQUESTS
        // ========================================================
        // Verify:
        // - No requests produce no valid grant.
        // - Each channel can independently receive service.
        // - An inactive channel never receives a grant.
        // ========================================================

        // Check the idle state for five cycles.
        repeat (5)
            check_cycle('0, 1'b1);

        // Activate one channel at a time.
        // Each channel requests service for six cycles.
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            pattern = '0;
            pattern[ch] = 1'b1;

            repeat (6)
                check_cycle(pattern, 1'b1);
        end

        $display("PHASE 1: idle and single-channel cases - OK");


        // ========================================================
        // PHASE 2: SUSTAINED ROUND-ROBIN ARBITRATION
        // ========================================================
        // Verify:
        // - All channels receive service when requesting.
        // - Grants follow the exact cyclic round-robin order.
        // - Priority advances after each completed transfer.
        //
        // With four channels, the expected order is:
        // CH0 -> CH1 -> CH2 -> CH3 -> CH0 -> ...
        // ========================================================

        repeat (NUM_CHANNELS*16)
            check_cycle('1, 1'b1);

        $display("PHASE 2: sustained round-robin order - OK");


        // ========================================================
        // PHASE 3: STABLE GRANT UNDER BACKPRESSURE
        // ========================================================
        // Verify:
        // - A valid grant remains unchanged during stalls.
        // - Round-robin priority does not advance without
        //   a completed transfer.
        // - Arbitration resumes when READY becomes high.
        // ========================================================

        // Activate multiple requesters.
        pattern = '1;
        if (NUM_CHANNELS > 1)
            pattern[1] = 1'b0;

        // Stall downstream acceptance for eight cycles.
        repeat (8)
            check_cycle(pattern, 1'b0);

        // Release backpressure and complete the transfer.
        check_cycle(pattern, 1'b1);

        $display("PHASE 3: stable grant under backpressure - OK");


        // ========================================================
        // PHASE 4: DYNAMIC REQUEST PATTERNS
        // ========================================================
        // Verify:
        // - Correct grant selection when requests change.
        // - Round-robin priority is preserved across patterns.
        // - Continuously requesting channels are not starved.
        //
        // Downstream READY remains high throughout this phase.
        // ========================================================

        // Fixed LFSR seed makes the stimulus reproducible.
        rng = 32'hA19C_37E5;

        for (int i = 0; i < 250; i++) begin

            // Generate the next pseudo-random LFSR state.
            rng = {
                rng[30:0],
                rng[31] ^ rng[21] ^ rng[1] ^ rng[0]
            };

            // Build a request vector from the LFSR bits.
            req_pattern = '0;

            for (int ch = 0; ch < NUM_CHANNELS; ch++)
                req_pattern[ch] = rng[(ch+i)%32];

            // Check arbitration with downstream READY high.
            check_cycle(req_pattern, 1'b1);
        end

        $display("PHASE 4: dynamic requests and fairness bound - OK");


        // ========================================================
        // PHASE 5: RANDOM REQUESTS AND BACKPRESSURE
        // ========================================================
        // Verify:
        // - Correct arbitration with changing requests.
        // - Priority remains stable during stalled transfers.
        // - The ready/valid source protocol is respected.
        // - Fairness holds across completed transfers.
        //
        // A stalled request vector is held until accepted.
        // ========================================================

        prior_stall = 0;
        prev_req = '0;

        for (int i = 0; i < 500; i++) begin

            // Generate the next pseudo-random LFSR state.
            rng = {
                rng[30:0],
                rng[31] ^ rng[21] ^ rng[1] ^ rng[0]
            };

            req_pattern = '0;

            // Preserve requests after an unaccepted transfer.
            // Otherwise, generate a new request pattern.
            if (prior_stall) begin
                req_pattern = prev_req;

            end else begin
                for (int ch = 0; ch < NUM_CHANNELS; ch++)
                    req_pattern[ch] = rng[(ch+3*i)%32];
            end

            // Generate downstream readiness.
            // READY is low when bits [9:7] are all zero.
            ready_next = (rng[9:7] != 3'b000);

            // Check expected grant and fairness.
            check_cycle(req_pattern, ready_next);

            // Remember whether the current transfer stalled.
            prior_stall = (req_pattern != '0 && !ready_next);
            prev_req = req_pattern;
        end

        // Complete any request left stalled before moving
        // to the reset test, preserving request stability.
        if (prior_stall)
            check_cycle(prev_req, 1'b1);

        $display("PHASE 5: randomized requests, ready stalls, fairness - OK");


        // ========================================================
        // PHASE 6: RESET DURING A STALLED GRANT
        // ========================================================
        // Verify:
        // - Reset can interrupt an outstanding stalled grant.
        // - Arbitration priority returns to channel 0.
        // - The arbiter resumes correct operation after reset.
        // ========================================================

        // Create a stalled grant while all channels request.
        check_cycle('1, 1'b0);

        // Assert reset and clear active requests.
        @(negedge clk);

        req_i = '0;
        grant_ready_i = 1'b0;
        rst_n = 1'b0;

        // Reset the reference-model priority and fairness ages.
        model_start = 0;

        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            age[ch] = 0;

        // Keep reset active for three cycles.
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Check: after reset, channel 0 must win first
        // when all channels request service.
        check_cycle('1, 1'b1);

        $display("PHASE 6: reset restarts arbitration at channel 0 - OK");


        // ========================================================
        // FINAL COVERAGE CHECKS
        // ========================================================
        // Verify that the test generated enough useful activity.
        // Passing functional checks alone is insufficient if
        // the relevant scenarios were never exercised.
        // ========================================================

        // Check:
        // - At least 300 completed transfers.
        // - At least five backpressure cycles.
        // - At least one fairness observation.
        if (transfers < 300 ||
            stalls < 5 ||
            fairness_checks == 0)
            $fatal(1,
                "Coverage too small: transfers=%0d stalls=%0d fairness=%0d",
                transfers, stalls, fairness_checks);

        // Coverage check: every channel must have received
        // at least one completed transfer during the test.
        for (int ch = 0; ch < NUM_CHANNELS; ch++)
            if (service_count[ch] == 0)
                $fatal(1, "Channel %0d never serviced", ch);


        // All functional and coverage checks passed.
        $display(
            "PASS rr_arbiter_tb: transfers=%0d stalls=%0d fairness_checks=%0d",
            transfers, stalls, fairness_checks
        );

        $finish;
    end


    // ============================================================
    // GLOBAL TEST TIMEOUT
    // ============================================================
    // Prevent the simulation from running indefinitely
    // if arbitration or the test sequence becomes stalled.
    // ============================================================

    initial begin
        #30000;
        $fatal(1, "Global arbiter test timeout");
    end

endmodule
