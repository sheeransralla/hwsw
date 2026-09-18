// ---------------------------------------------------------------------------
// tb_bwt_accel - directed testbench for the inverse-BWT accelerator
//
// Each test streams one block L into the accelerator and collects the bytes it
// streams out, then compares them with the expected text:
//   banana     L = "nnbaaa", origPtr = 3 -> "banana"  (example of report 1.5(j))
//   abab       L = "bbaa",   origPtr = 0 -> "abab"    (periodic input: T splits
//                                                      into cycles, which broke
//                                                      the original Python loop)
//   aaaa       L = "aaaa",   origPtr = 0 -> "aaaa"    (one repeated byte)
//   nban       L = "bnna",   origPtr = 2 -> "nban"    (a different origPtr)
//   mississippi                                       (a longer block)
//
// All test vectors were produced with the benchmark's own Python functions.
//   banana-bp  as the first test, but the sink accepts a byte only every other
//              cycle, which exercises the output backpressure path
//
//   iverilog -g2012 -o tb tb_bwt_accel.sv bwt_accel.sv && vvp tb
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_bwt_accel;

    localparam int LEN_W   = 20;
    localparam int MAX_LEN = 4096;          // small memories keep simulation fast

    logic             clk = 0, rst_n = 0;
    logic             start = 0;
    logic [LEN_W-1:0] block_len = 0;
    logic [23:0]      orig_ptr = 0;
    logic             busy, done;
    logic             s_valid = 0, s_ready;
    logic [7:0]       s_data = 0;
    logic             m_valid, m_ready = 0;
    logic [7:0]       m_data;

    bwt_accel #(.LEN_W(LEN_W), .MAX_LEN(MAX_LEN)) dut (.*);

    always #5 clk = ~clk;                   // 100 MHz

    int    errors = 0;
    string got    = "";
    bit    slow   = 0;

    // Sink: a transfer happens on a rising edge where m_valid and m_ready are
    // both high, which is when the design itself counts the byte as accepted.
    // m_ready is driven on the falling edge so it is stable across that edge.
    always @(posedge clk) begin
        if (m_valid && m_ready)
            got = {got, string'(m_data)};
    end

    always @(negedge clk) begin
        m_ready <= slow ? ~m_ready : 1'b1;
    end

    task automatic run_block(input string name,
                             input string l_block,
                             input int    ptr,
                             input string expected,
                             input bit    slow_sink);
        int n = l_block.len();
        int guard = 0;
        begin
            got   = "";
            slow  = slow_sink;

            @(negedge clk);
            block_len = n;
            orig_ptr  = ptr;
            start     = 1;
            @(negedge clk);
            start = 0;

            // stream L in (the accelerator buffers the whole block)
            for (int i = 0; i < n; i++) begin
                s_valid = 1;
                s_data  = l_block[i];
                @(negedge clk);
            end
            s_valid = 0;

            // wait for the block to finish
            while (busy && guard < 100000) begin
                @(negedge clk);
                guard++;
            end

            if (got == expected)
                $display("PASS  %-10s n=%0d origPtr=%0d -> \"%s\"%s",
                         name, n, ptr, got, slow_sink ? "   (with backpressure)" : "");
            else begin
                $display("FAIL  %-10s expected \"%s\", got \"%s\"", name, expected, got);
                errors++;
            end
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        run_block("banana",    "nnbaaa", 3, "banana", 0);
        run_block("abab",      "bbaa",   0, "abab",   0);
        run_block("aaaa",      "aaaa",   0, "aaaa",   0);
        run_block("nban",      "bnna",   2, "nban",   0);
        run_block("mississippi", "pssmipissii", 4, "mississippi", 0);
        run_block("banana-bp", "nnbaaa", 3, "banana", 1);

        if (errors == 0)
            $display("\nAll tests passed.");
        else
            $display("\n%0d test(s) failed.", errors);
        $finish;
    end

endmodule
