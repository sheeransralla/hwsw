// ---------------------------------------------------------------------------
// ray_scene_isect - ray/scene intersection accelerator for the raytrace
// benchmark
//
// Replaces the object scan inside Scene.rayColour() and
// Scene._lightIsVisible(): the host submits one ray, the accelerator tests it
// against the whole scene (seven spheres and one halfspace held locally) and
// returns the selected hit. Accelerating the search rather than a single
// intersection test is what makes the interface affordable: the benchmark
// performs 204,958 intersection tests per image but casts only 25,999 rays.
//
// Two modes, one per caller in the benchmark:
//   MODE_NEAREST  scan every object and keep the smallest t with t > -EPSILON,
//                 keeping the earlier object on a tie, as firstIntersection()
//                 does.
//   MODE_ANYHIT   stop at the first object with t > EPSILON and report it, as
//                 _lightIsVisible() does.
//
// The arithmetic is IEEE-754 binary64 in the same evaluation order as the
// Python code, so results are bit-identical:
//     cp   = centre - origin
//     v    = (cp.x*d.x + cp.y*d.y) + cp.z*d.z
//     c2   = (cp.x*cp.x + cp.y*cp.y) + cp.z*cp.z
//     disc = r*r - (c2 - v*v)
//     t    = v - sqrt(disc)                          (sphere)
//     t    = 1 / -((d.x*n.x + d.y*n.y) + d.z*n.z)    (halfspace)
//
// Objects are tested one at a time through shared arithmetic units: three
// multipliers, one adder/subtracter, one square root and one divider. The
// square root is entered only when the discriminant is non-negative, which is
// the case for about 4% of sphere tests in this scene, so most objects leave
// the datapath early. The units are pipelined IP cores with parameterized
// latency (see fp64_units.sv).
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module ray_scene_isect #(
    parameter int NSPHERES = 7,
    parameter int MUL_LAT  = 3,
    parameter int ADD_LAT  = 3,
    parameter int SQRT_LAT = 8,
    parameter int DIV_LAT  = 10
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- scene load -------------------------------------------------------
    input  logic        sph_we,
    input  logic [2:0]  sph_idx,
    input  logic [63:0] sph_cx,
    input  logic [63:0] sph_cy,
    input  logic [63:0] sph_cz,
    input  logic [63:0] sph_r,
    input  logic        hs_we,
    input  logic [63:0] hs_nx,
    input  logic [63:0] hs_ny,
    input  logic [63:0] hs_nz,
    input  logic        cfg_we,
    input  logic [63:0] cfg_epsilon,

    // ---- ray request ------------------------------------------------------
    input  logic        req_valid,
    output logic        req_ready,
    input  logic        req_mode,          // 0 = nearest, 1 = any-hit
    input  logic [63:0] req_ox,
    input  logic [63:0] req_oy,
    input  logic [63:0] req_oz,
    input  logic [63:0] req_dx,
    input  logic [63:0] req_dy,
    input  logic [63:0] req_dz,

    // ---- result -----------------------------------------------------------
    output logic        res_valid,
    input  logic        res_ready,
    output logic        res_hit,
    output logic [3:0]  res_obj,           // 0..6 spheres, 7 halfspace, 15 none
    output logic [63:0] res_t
);

    localparam logic MODE_ANYHIT = 1'b1;
    localparam int   HS_ID       = NSPHERES;      // object index of the floor

    // -----------------------------------------------------------------------
    // scene storage
    // -----------------------------------------------------------------------
    logic [63:0] cx [0:NSPHERES-1];
    logic [63:0] cy [0:NSPHERES-1];
    logic [63:0] cz [0:NSPHERES-1];
    logic [63:0] rad[0:NSPHERES-1];
    logic [63:0] nx, ny, nz, epsilon, neg_epsilon;

    always_ff @(posedge clk) begin
        if (sph_we) begin
            cx[sph_idx]  <= sph_cx;
            cy[sph_idx]  <= sph_cy;
            cz[sph_idx]  <= sph_cz;
            rad[sph_idx] <= sph_r;
        end
        if (hs_we) begin
            nx <= hs_nx;
            ny <= hs_ny;
            nz <= hs_nz;
        end
        if (cfg_we) begin
            epsilon     <= cfg_epsilon;
            neg_epsilon <= {~cfg_epsilon[63], cfg_epsilon[62:0]};
        end
    end

    // -----------------------------------------------------------------------
    // shared arithmetic units
    // -----------------------------------------------------------------------
    logic        mul_v [0:2], mul_ov [0:2];
    logic [63:0] mul_a [0:2], mul_b [0:2], mul_y [0:2];
    logic        add_v, add_sub, add_ov;
    logic [63:0] add_a, add_b, add_y;
    logic        sqrt_v, sqrt_ov;
    logic [63:0] sqrt_a, sqrt_y;
    logic        div_v, div_ov;
    logic [63:0] div_a, div_b, div_y;

    genvar g;
    generate
        for (g = 0; g < 3; g = g + 1) begin : g_mul
            fp64_mul #(.LAT(MUL_LAT)) u_mul (
                .clk(clk), .rst_n(rst_n), .in_valid(mul_v[g]), .a(mul_a[g]), .b(mul_b[g]),
                .out_valid(mul_ov[g]), .y(mul_y[g]));
        end
    endgenerate

    fp64_addsub #(.LAT(ADD_LAT)) u_add (
        .clk(clk), .rst_n(rst_n), .in_valid(add_v), .sub(add_sub), .a(add_a), .b(add_b),
        .out_valid(add_ov), .y(add_y));
    fp64_sqrt #(.LAT(SQRT_LAT)) u_sqrt (
        .clk(clk), .rst_n(rst_n), .in_valid(sqrt_v), .a(sqrt_a),
        .out_valid(sqrt_ov), .y(sqrt_y));
    fp64_div #(.LAT(DIV_LAT)) u_div (
        .clk(clk), .rst_n(rst_n), .in_valid(div_v), .a(div_a), .b(div_b),
        .out_valid(div_ov), .y(div_y));

    // -----------------------------------------------------------------------
    // control
    // -----------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE,
        S_SUB_X, S_SUB_Y, S_SUB_Z,          // cp = centre - origin
        S_V_MUL, S_V_ADD1, S_V_ADD2,        // v  = dot(cp, d)
        S_C_MUL, S_C_ADD1, S_C_ADD2,        // c2 = dot(cp, cp)
        S_SQUARE, S_INNER, S_DISC, S_DISC_T,
        S_SQRT, S_TIME, S_TIME_W,
        S_HS_MUL, S_HS_ADD1, S_HS_ADD2, S_HS_TEST, S_HS_DIV, S_HS_DIV_W,
        S_ACCEPT, S_DONE
    } state_e;

    state_e      state;
    logic [3:0]  obj;
    logic        mode;
    logic [63:0] ox, oy, oz, dx, dy, dz;
    logic [63:0] cpx, cpy, cpz, m2;
    logic [63:0] v, c2, vv, r2, disc, tcand;
    logic        cand_valid;

    logic [63:0] best_t;
    logic [3:0]  best_obj;
    logic        best_valid;

    logic cand_gt_negeps, cand_gt_eps, cand_lt_best, v_is_zero, disc_negative;
    fp64_cmp u_cmp_negeps (.a(neg_epsilon), .b(tcand),  .lt(cand_gt_negeps), .eqz());
    fp64_cmp u_cmp_eps    (.a(epsilon),     .b(tcand),  .lt(cand_gt_eps),    .eqz());
    fp64_cmp u_cmp_best   (.a(tcand),       .b(best_t), .lt(cand_lt_best),   .eqz());
    fp64_cmp u_cmp_vzero  (.a(v),           .b(64'd0),  .lt(),               .eqz(v_is_zero));
    fp64_cmp u_cmp_disc   (.a(disc),        .b(64'd0),  .lt(disc_negative),  .eqz());

    assign req_ready = (state == S_IDLE) && !res_valid;

    // next object to test, and the state that starts it
    function automatic state_e start_of(input logic [3:0] next_obj);
        return (next_obj == HS_ID[3:0]) ? S_HS_MUL : S_SUB_X;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            res_valid <= 1'b0;
            res_hit   <= 1'b0;
            res_obj   <= 4'd15;
            res_t     <= 64'd0;
            mul_v[0]  <= 1'b0; mul_v[1] <= 1'b0; mul_v[2] <= 1'b0;
            add_v     <= 1'b0; sqrt_v   <= 1'b0; div_v    <= 1'b0;
        end else begin
            if (res_valid && res_ready) res_valid <= 1'b0;   // handshake
            mul_v[0]  <= 1'b0; mul_v[1] <= 1'b0; mul_v[2] <= 1'b0;
            add_v     <= 1'b0; sqrt_v   <= 1'b0; div_v    <= 1'b0;

            case (state)

            S_IDLE: if (req_valid) begin
                ox <= req_ox; oy <= req_oy; oz <= req_oz;
                dx <= req_dx; dy <= req_dy; dz <= req_dz;
                mode       <= req_mode;
                obj        <= 4'd0;
                best_valid <= 1'b0;
                best_obj   <= 4'd15;
                cand_valid <= 1'b0;
                add_a <= cx[0]; add_b <= req_ox; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_SUB_X;
            end

            // ---- cp = centre - origin, one component per pass -------------
            S_SUB_X: if (add_ov) begin
                cpx   <= add_y;
                add_a <= cy[obj[2:0]]; add_b <= oy; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_SUB_Y;
            end
            S_SUB_Y: if (add_ov) begin
                cpy   <= add_y;
                add_a <= cz[obj[2:0]]; add_b <= oz; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_SUB_Z;
            end
            S_SUB_Z: if (add_ov) begin
                cpz   <= add_y;
                state <= S_V_MUL;
            end

            // ---- v = (cpx*dx + cpy*dy) + cpz*dz ---------------------------
            S_V_MUL: begin
                mul_a[0] <= cpx; mul_b[0] <= dx; mul_v[0] <= 1'b1;
                mul_a[1] <= cpy; mul_b[1] <= dy; mul_v[1] <= 1'b1;
                mul_a[2] <= cpz; mul_b[2] <= dz; mul_v[2] <= 1'b1;
                state    <= S_V_ADD1;
            end
            S_V_ADD1: if (mul_ov[0]) begin
                m2    <= mul_y[2];
                add_a <= mul_y[0]; add_b <= mul_y[1]; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_V_ADD2;
            end
            S_V_ADD2: if (add_ov) begin
                add_a <= add_y; add_b <= m2; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_C_MUL;
            end

            // ---- c2 = (cpx*cpx + cpy*cpy) + cpz*cpz -----------------------
            S_C_MUL: if (add_ov) begin
                v        <= add_y;                 // v from the previous stage
                mul_a[0] <= cpx; mul_b[0] <= cpx; mul_v[0] <= 1'b1;
                mul_a[1] <= cpy; mul_b[1] <= cpy; mul_v[1] <= 1'b1;
                mul_a[2] <= cpz; mul_b[2] <= cpz; mul_v[2] <= 1'b1;
                state    <= S_C_ADD1;
            end
            S_C_ADD1: if (mul_ov[0]) begin
                m2    <= mul_y[2];
                add_a <= mul_y[0]; add_b <= mul_y[1]; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_C_ADD2;
            end
            S_C_ADD2: if (add_ov) begin
                add_a <= add_y; add_b <= m2; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_SQUARE;
            end

            // ---- r*r and v*v ----------------------------------------------
            S_SQUARE: if (add_ov) begin
                c2       <= add_y;
                mul_a[0] <= rad[obj[2:0]]; mul_b[0] <= rad[obj[2:0]]; mul_v[0] <= 1'b1;
                mul_a[1] <= v;             mul_b[1] <= v;             mul_v[1] <= 1'b1;
                state    <= S_INNER;
            end

            // ---- disc = r*r - (c2 - v*v) ----------------------------------
            S_INNER: if (mul_ov[0]) begin
                r2    <= mul_y[0];
                vv    <= mul_y[1];
                add_a <= c2; add_b <= mul_y[1]; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_DISC;
            end
            S_DISC: if (add_ov) begin
                add_a <= r2; add_b <= add_y; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_DISC_T;
            end
            S_DISC_T: if (add_ov) begin
                disc  <= add_y;
                state <= S_SQRT;
            end

            // ---- miss: skip the square root; hit: t = v - sqrt(disc) ------
            S_SQRT: begin                                  // issue once
                if (disc_negative) begin
                    cand_valid <= 1'b0;
                    state      <= S_ACCEPT;
                end else begin
                    sqrt_a <= disc; sqrt_v <= 1'b1;
                    state  <= S_TIME;
                end
            end
            S_TIME: if (sqrt_ov) begin
                add_a <= v; add_b <= sqrt_y; add_sub <= 1'b1; add_v <= 1'b1;
                state <= S_TIME_W;
            end
            S_TIME_W: if (add_ov) begin        // wait for t before deciding
                tcand      <= add_y;
                cand_valid <= 1'b1;
                state      <= S_ACCEPT;
            end

            // ---- halfspace: t = 1 / -dot(d, n) ----------------------------
            S_HS_MUL: begin
                mul_a[0] <= dx; mul_b[0] <= nx; mul_v[0] <= 1'b1;
                mul_a[1] <= dy; mul_b[1] <= ny; mul_v[1] <= 1'b1;
                mul_a[2] <= dz; mul_b[2] <= nz; mul_v[2] <= 1'b1;
                state    <= S_HS_ADD1;
            end
            S_HS_ADD1: if (mul_ov[0]) begin
                m2    <= mul_y[2];
                add_a <= mul_y[0]; add_b <= mul_y[1]; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_HS_ADD2;
            end
            S_HS_ADD2: if (add_ov) begin
                add_a <= add_y; add_b <= m2; add_sub <= 1'b0; add_v <= 1'b1;
                state <= S_HS_TEST;
            end
            S_HS_TEST: if (add_ov) begin
                v     <= add_y;
                state <= S_HS_DIV;
            end
            S_HS_DIV: begin                                // issue once
                if (v_is_zero) begin                       // parallel ray
                    cand_valid <= 1'b0;
                    state      <= S_ACCEPT;
                end else begin
                    div_a <= 64'h3FF0000000000000;         // 1.0
                    div_b <= {~v[63], v[62:0]};            // -v
                    div_v <= 1'b1;
                    state <= S_HS_DIV_W;
                end
            end
            S_HS_DIV_W: if (div_ov) begin
                tcand      <= div_y;
                cand_valid <= 1'b1;
                state      <= S_ACCEPT;
            end

            // ---- keep or discard the candidate, then advance --------------
            S_ACCEPT: begin
                begin
                    if (mode == MODE_ANYHIT) begin
                        if (cand_valid && cand_gt_eps) begin
                            res_hit   <= 1'b1;
                            res_obj   <= obj;
                            res_t     <= tcand;
                            res_valid <= 1'b1;
                            state     <= S_IDLE;
                        end else if (obj == HS_ID[3:0]) begin
                            res_hit   <= 1'b0;
                            res_obj   <= 4'd15;
                            res_t     <= 64'd0;
                            res_valid <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            obj        <= obj + 4'd1;
                            cand_valid <= 1'b0;
                            if (obj + 4'd1 != HS_ID[3:0]) begin
                                add_a   <= cx[obj[2:0] + 3'd1];
                                add_b   <= ox;
                                add_sub <= 1'b1;
                                add_v   <= 1'b1;
                            end
                            state <= start_of(obj + 4'd1);
                        end
                    end else begin
                        if (cand_valid && cand_gt_negeps &&
                            (!best_valid || cand_lt_best)) begin
                            best_t     <= tcand;
                            best_obj   <= obj;
                            best_valid <= 1'b1;
                        end
                        if (obj == HS_ID[3:0]) begin
                            state <= S_DONE;
                        end else begin
                            obj        <= obj + 4'd1;
                            cand_valid <= 1'b0;
                            if (obj + 4'd1 != HS_ID[3:0]) begin
                                add_a   <= cx[obj[2:0] + 3'd1];
                                add_b   <= ox;
                                add_sub <= 1'b1;
                                add_v   <= 1'b1;
                            end
                            state <= start_of(obj + 4'd1);
                        end
                    end
                end
            end

            S_DONE: begin
                res_hit   <= best_valid;
                res_obj   <= best_valid ? best_obj : 4'd15;
                res_t     <= best_valid ? best_t : 64'd0;
                res_valid <= 1'b1;
                state     <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
