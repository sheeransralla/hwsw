// ---------------------------------------------------------------------------
// fp64_units.sv - IEEE-754 binary64 arithmetic units
//
// These modules are BEHAVIOURAL SIMULATION MODELS, not synthesizable RTL:
// they compute with $bitstoreal/$realtobits/$sqrt and SystemVerilog's real
// type, and delay the result by LAT cycles. They stand for vendor binary64 IP
// cores (for example Xilinx Floating-Point Operator or DesignWare DW_fp_*),
// which present the same valid/latency interface; synthesizing the
// accelerator means replacing each model with a configured IP instance. The
// surrounding datapath, scene storage and control FSM are written in
// synthesizable style.
//
// binary64 is used because the accelerator must reproduce CPython's float
// arithmetic bit for bit: a narrower format would change intersection
// decisions and therefore the rendered image.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

// ---- multiplier -----------------------------------------------------------
module fp64_mul #(parameter int LAT = 3) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        out_valid,
    output logic [63:0] y
);
    logic [63:0] pipe_d [0:LAT-1];
    logic        pipe_v [0:LAT-1];
    integer      i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LAT; i = i + 1)
                pipe_v[i] <= 1'b0;
        end else begin
            pipe_d[0] <= $realtobits($bitstoreal(a) * $bitstoreal(b));
            pipe_v[0] <= in_valid;
            for (i = 1; i < LAT; i = i + 1) begin
                pipe_d[i] <= pipe_d[i-1];
                pipe_v[i] <= pipe_v[i-1];
            end
        end
    end

    assign y         = pipe_d[LAT-1];
    assign out_valid = pipe_v[LAT-1];
endmodule

// ---- adder / subtracter ---------------------------------------------------
module fp64_addsub #(parameter int LAT = 3) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic        sub,        // 1: a - b, 0: a + b
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        out_valid,
    output logic [63:0] y
);
    logic [63:0] pipe_d [0:LAT-1];
    logic        pipe_v [0:LAT-1];
    integer      i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LAT; i = i + 1)
                pipe_v[i] <= 1'b0;
        end else begin
            pipe_d[0] <= sub ? $realtobits($bitstoreal(a) - $bitstoreal(b))
                         : $realtobits($bitstoreal(a) + $bitstoreal(b));
            pipe_v[0] <= in_valid;
            for (i = 1; i < LAT; i = i + 1) begin
                pipe_d[i] <= pipe_d[i-1];
                pipe_v[i] <= pipe_v[i-1];
            end
        end
    end

    assign y         = pipe_d[LAT-1];
    assign out_valid = pipe_v[LAT-1];
endmodule

// ---- square root ----------------------------------------------------------
// Only entered when the discriminant is non-negative, which is the case for
// about 4% of sphere tests in the benchmark scene.
module fp64_sqrt #(parameter int LAT = 8) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [63:0] a,
    output logic        out_valid,
    output logic [63:0] y
);
    logic [63:0] pipe_d [0:LAT-1];
    logic        pipe_v [0:LAT-1];
    integer      i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LAT; i = i + 1)
                pipe_v[i] <= 1'b0;
        end else begin
            pipe_d[0] <= $realtobits($sqrt($bitstoreal(a)));
            pipe_v[0] <= in_valid;
            for (i = 1; i < LAT; i = i + 1) begin
                pipe_d[i] <= pipe_d[i-1];
                pipe_v[i] <= pipe_v[i-1];
            end
        end
    end

    assign y         = pipe_d[LAT-1];
    assign out_valid = pipe_v[LAT-1];
endmodule

// ---- divider --------------------------------------------------------------
// Used once per ray for the halfspace time 1 / -v.
module fp64_div #(parameter int LAT = 10) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        out_valid,
    output logic [63:0] y
);
    logic [63:0] pipe_d [0:LAT-1];
    logic        pipe_v [0:LAT-1];
    integer      i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LAT; i = i + 1)
                pipe_v[i] <= 1'b0;
        end else begin
            pipe_d[0] <= $realtobits($bitstoreal(a) / $bitstoreal(b));
            pipe_v[0] <= in_valid;
            for (i = 1; i < LAT; i = i + 1) begin
                pipe_d[i] <= pipe_d[i-1];
                pipe_v[i] <= pipe_v[i-1];
            end
        end
    end

    assign y         = pipe_d[LAT-1];
    assign out_valid = pipe_v[LAT-1];
endmodule

// ---- comparator (combinational, also a behavioural model) ----------------
module fp64_cmp (
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        lt,         // a < b
    output logic        eqz         // a == 0
);
    assign lt  = $bitstoreal(a) <  $bitstoreal(b);
    assign eqz = $bitstoreal(a) == 0.0;
endmodule
