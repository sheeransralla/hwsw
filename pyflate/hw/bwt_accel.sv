// ---------------------------------------------------------------------------
// bwt_accel - inverse Burrows-Wheeler transform accelerator for bzip2 blocks
//
// Replaces bwt_transform() + bwt_reverse() of the pyflate benchmark. The host
// streams in the block L (the last column of the sorted rotation matrix) with
// its length and origPtr, and streams out the reconstructed block.
//
// Phases:
//   LOAD    store L in on-chip memory and count the byte values
//   PREFIX  turn the 256 counts into the starting offset of each byte value
//   BUILD   T[base[L[i]]++] = i   for i = 0 .. n-1        (the LF mapping)
//   WALK    pos = T[pos]; emit L[pos]                     n times from origPtr
//
// Cost: n (LOAD) + 256 (PREFIX) + n (BUILD) + n (WALK) = 3n + 256 cycles for a
// block of n bytes. The input is streamed in during LOAD and the output is
// streamed out during WALK, so those transfers are already included, provided
// the host sustains one byte per cycle.
//
// Memory model: this RTL reads L and T asynchronously, so a dependent hop of
// the walk (address = data of the previous read) completes in one cycle. That
// holds for LUT-based distributed RAM, which is not practical at the 900 kB a
// level-9 block needs. FPGA block RAM and ASIC SRAM register the address, so
// their reads are synchronous whatever happens to the output register: the
// walk then needs two cycles per byte and the block costs about 4n + 256
// cycles. The asynchronous form is kept here because it expresses the datapath
// directly; the report uses the synchronous figure for the estimate and
// discusses the trade-off.
//
// The design demonstrates the datapath and control; it is not tape-out ready.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module bwt_accel #(
    parameter int LEN_W   = 20,            // block-length / index width
    parameter int MAX_LEN = (1 << LEN_W)   // 1 MiB covers a level-9 block (900 kB)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    // ---- control / status registers (memory-mapped by the host) ----------
    input  logic                 start,      // pulse: begin a new block
    input  logic [LEN_W-1:0]     block_len,  // n, number of bytes in L
    input  logic [23:0]          orig_ptr,   // origPtr from the bzip2 block header
    output logic                 busy,
    output logic                 done,       // pulse when the block is finished

    // ---- input stream: the block L ---------------------------------------
    input  logic                 s_valid,
    input  logic [7:0]           s_data,
    output logic                 s_ready,

    // ---- output stream: the reconstructed block --------------------------
    output logic                 m_valid,
    output logic [7:0]           m_data,
    input  logic                 m_ready
);

    // -----------------------------------------------------------------------
    // storage
    // -----------------------------------------------------------------------
    logic [7:0]       l_mem [0:MAX_LEN-1];   // the block L
    logic [LEN_W-1:0] t_mem [0:MAX_LEN-1];   // the BWT reversal mapping T
    logic [LEN_W-1:0] hist  [0:255];         // byte counts, then running offsets

    logic [LEN_W-1:0] l_addr, t_addr;
    logic [7:0]       l_dout;
    logic [LEN_W-1:0] t_dout;

    assign l_dout = l_mem[l_addr];           // asynchronous reads: see header
    assign t_dout = t_mem[t_addr];

    // -----------------------------------------------------------------------
    // control
    // -----------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE, S_LOAD, S_PREFIX, S_BUILD, S_WALK, S_DONE
    } state_e;

    state_e           state;

    logic [LEN_W-1:0] n;            // block length, latched at start
    logic [LEN_W-1:0] idx;          // byte counter for LOAD and BUILD
    logic [7:0]       pfx_idx;      // 0..255 during PREFIX
    logic [LEN_W-1:0] running;      // running sum during PREFIX
    logic [LEN_W-1:0] cur;          // current position during WALK
    logic [LEN_W-1:0] emitted;      // bytes accepted by the consumer
    logic             out_v;        // the output register holds a valid byte
    logic [7:0]       out_d;

    assign s_ready = (state == S_LOAD);
    assign m_valid = out_v;
    assign m_data  = out_d;
    assign busy    = (state != S_IDLE);

    // The walk advances when the output register is free or is being drained.
    logic walk_en;
    assign walk_en = !out_v || m_ready;

    // Addresses are combinational, so each phase drives what it needs.
    always_comb begin
        l_addr = '0;
        t_addr = '0;
        case (state)
            S_BUILD: l_addr = idx;          // read L[i] to place its position
            S_WALK: begin
                t_addr = cur;               // T[cur] gives the next position
                l_addr = t_dout;            // and L there is the output byte
            end
            default: ;
        endcase
    end

    integer k;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            done    <= 1'b0;
            n       <= '0;
            idx     <= '0;
            pfx_idx <= '0;
            running <= '0;
            cur     <= '0;
            emitted <= '0;
            out_v   <= 1'b0;
            out_d   <= '0;
        end else begin
            done <= 1'b0;

            case (state)

                // -------- IDLE: latch the job, clear the histogram --------
                S_IDLE: begin
                    if (start && block_len != 0) begin
                        n       <= block_len;
                        idx     <= '0;
                        emitted <= '0;
                        out_v   <= 1'b0;
                        for (k = 0; k < 256; k = k + 1)
                            hist[k] <= '0;
                        state <= S_LOAD;
                    end
                end

                // -------- LOAD: store L, count byte values ----------------
                S_LOAD: begin
                    if (s_valid) begin
                        l_mem[idx]   <= s_data;
                        hist[s_data] <= hist[s_data] + 1'b1;
                        if (idx == n - 1) begin
                            idx     <= '0;
                            pfx_idx <= '0;
                            running <= '0;
                            state   <= S_PREFIX;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end
                end

                // -------- PREFIX: counts -> starting offsets --------------
                // hist[i] becomes the number of bytes with a smaller value,
                // which is where value i starts in the first column F.
                S_PREFIX: begin
                    hist[pfx_idx] <= running;
                    running       <= running + hist[pfx_idx];
                    pfx_idx       <= pfx_idx + 1'b1;
                    if (pfx_idx == 8'hFF) begin
                        idx   <= '0;
                        state <= S_BUILD;
                    end
                end

                // -------- BUILD: T[base[L[i]]++] = i ---------------------
                S_BUILD: begin
                    t_mem[hist[l_dout]] <= idx;
                    hist[l_dout]        <= hist[l_dout] + 1'b1;
                    if (idx == n - 1) begin
                        cur     <= orig_ptr[LEN_W-1:0];
                        emitted <= '0;
                        out_v   <= 1'b0;
                        state   <= S_WALK;
                    end else begin
                        idx <= idx + 1'b1;
                    end
                end

                // -------- WALK: pos = T[pos]; emit L[pos] ----------------
                S_WALK: begin
                    if (walk_en) begin
                        if (emitted + {{(LEN_W-1){1'b0}}, out_v} < n) begin
                            cur   <= t_dout;     // hop to the next position
                            out_d <= l_dout;     // L[T[cur]] is the next byte
                            out_v <= 1'b1;
                        end else begin
                            out_v <= 1'b0;
                        end
                        if (out_v && m_ready) begin
                            if (emitted == n - 1) begin
                                out_v <= 1'b0;
                                state <= S_DONE;
                            end
                            emitted <= emitted + 1'b1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
