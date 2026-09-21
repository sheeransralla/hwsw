// ---------------------------------------------------------------------------
// tb_ray_scene_isect - checks the accelerator against the Python benchmark
//
// scene.hex and rays.hex are produced by gen_vectors.py, which captures the
// benchmark's own scene and 300 of the rays it casts (primary, reflection and
// shadow), together with the result the Python code computed for each. The
// testbench requires a bit-identical match of hit, object id and t: any
// difference in the floating-point result would change a pixel.
//
//   python3 gen_vectors.py ../raytrace/bm_raytrace
//   iverilog -g2012 -o tb tb_ray_scene_isect.sv ray_scene_isect.sv fp64_units.sv
//   vvp tb
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_ray_scene_isect;

    localparam int NSPHERES = 7;
    localparam int MAXR     = 400;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                       // 100 MHz

    logic        sph_we = 0, hs_we = 0;
    logic [2:0]  sph_idx = 0;
    logic [63:0] sph_cx = 0, sph_cy = 0, sph_cz = 0, sph_r = 0;
    logic [63:0] hs_nx = 0, hs_ny = 0, hs_nz = 0, cfg_epsilon = 0;
    logic        cfg_we = 0;

    logic        req_valid = 0, req_ready, req_mode = 0;
    logic [63:0] req_ox = 0, req_oy = 0, req_oz = 0;
    logic [63:0] req_dx = 0, req_dy = 0, req_dz = 0;

    logic        res_valid, res_hit;
    logic        res_ready = 1;          // the wrapper always accepts results
    logic [3:0]  res_obj;
    logic [63:0] res_t;

    ray_scene_isect #(.NSPHERES(NSPHERES)) dut (.*);

    // ---- vectors ----------------------------------------------------------
    logic [63:0] scx[0:NSPHERES-1], scy[0:NSPHERES-1];
    logic [63:0] scz[0:NSPHERES-1], srad[0:NSPHERES-1];
    logic [63:0] hnx, hny, hnz, heps;

    integer      r_mode [0:MAXR-1], r_hit [0:MAXR-1], r_obj [0:MAXR-1];
    logic [63:0] r_ox[0:MAXR-1], r_oy[0:MAXR-1], r_oz[0:MAXR-1];
    logic [63:0] r_dx[0:MAXR-1], r_dy[0:MAXR-1], r_dz[0:MAXR-1], r_t[0:MAXR-1];
    integer      nrays = 0;

    integer fd, code, i;
    integer errors = 0, checked = 0, nearest_n = 0, shadow_n = 0;
    integer cycles, total_cycles = 0, worst_cycles = 0;

    initial begin
        fd = $fopen("scene.hex", "r");
        if (fd == 0) begin
            $display("cannot open scene.hex - run gen_vectors.py first");
            $finish;
        end
        for (i = 0; i < NSPHERES; i = i + 1)
            code = $fscanf(fd, "%h %h %h %h\n", scx[i], scy[i], scz[i], srad[i]);
        code = $fscanf(fd, "%h %h %h %h\n", hnx, hny, hnz, heps);
        $fclose(fd);

        fd = $fopen("rays.hex", "r");
        if (fd == 0) begin
            $display("cannot open rays.hex - run gen_vectors.py first");
            $finish;
        end
        while (!$feof(fd) && nrays < MAXR) begin
            code = $fscanf(fd, "%d %h %h %h %h %h %h %d %d %h\n",
                           r_mode[nrays], r_ox[nrays], r_oy[nrays], r_oz[nrays],
                           r_dx[nrays], r_dy[nrays], r_dz[nrays],
                           r_hit[nrays], r_obj[nrays], r_t[nrays]);
            if (code == 10) nrays = nrays + 1;
        end
        $fclose(fd);
        $display("loaded %0d rays", nrays);
    end

    // ---- stimulus ---------------------------------------------------------
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // load the scene
        for (i = 0; i < NSPHERES; i = i + 1) begin
            sph_we = 1; sph_idx = i[2:0];
            sph_cx = scx[i]; sph_cy = scy[i]; sph_cz = scz[i]; sph_r = srad[i];
            @(negedge clk);
        end
        sph_we = 0;
        hs_we = 1; cfg_we = 1;
        hs_nx = hnx; hs_ny = hny; hs_nz = hnz; cfg_epsilon = heps;
        @(negedge clk);
        hs_we = 0; cfg_we = 0;
        @(negedge clk);

        // one ray at a time
        for (i = 0; i < nrays; i = i + 1) begin
            while (!req_ready) @(negedge clk);
            req_mode = r_mode[i][0];
            req_ox = r_ox[i]; req_oy = r_oy[i]; req_oz = r_oz[i];
            req_dx = r_dx[i]; req_dy = r_dy[i]; req_dz = r_dz[i];
            req_valid = 1;
            @(negedge clk);
            req_valid = 0;

            cycles = 0;
            while (!res_valid && cycles < 5000) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            checked = checked + 1;
            total_cycles = total_cycles + cycles;
            if (cycles > worst_cycles) worst_cycles = cycles;
            if (r_mode[i] == 0) nearest_n = nearest_n + 1;
            else                shadow_n  = shadow_n  + 1;

            if (res_hit !== r_hit[i][0] ||
                (r_hit[i] && (res_obj !== r_obj[i][3:0] || res_t !== r_t[i]))) begin
                errors = errors + 1;
                if (errors <= 8)
                    $display("MISMATCH ray %0d (mode %0d): expected hit=%0d obj=%0d t=%h, got hit=%0d obj=%0d t=%h",
                             i, r_mode[i], r_hit[i], r_obj[i], r_t[i],
                             res_hit, res_obj, res_t);
            end
            @(negedge clk);
        end

        $display("\nchecked %0d rays (%0d nearest, %0d any-hit)",
                 checked, nearest_n, shadow_n);
        $display("cycles per ray: %0d average, %0d worst",
                 total_cycles / checked, worst_cycles);
        if (errors == 0)
            $display("All results match the Python reference bit for bit.");
        else
            $display("%0d mismatch(es).", errors);
        $finish;
    end

endmodule
