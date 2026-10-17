// SPDX-License-Identifier: GPL-3.0-or-later
// Light pen on the CRT 240p digital raster and the split analog raster:
// latency/spot offsets and edge windows, X smoothing, crosshair ownership,
// spike rejection, first pulse per frame, frame-sampled button with a settle
// frame, raw-release cutoff, brightness floor (including late lines) and
// border/main-screen rejection.
`timescale 1ns/1ps
module tb_nds_lightpen;
    reg clk_video=0; always #5 clk_video=~clk_video;
    reg reset=1, session_reset=0, crt_select=1, split_select=0, analog_screen_select=1;
    reg [1:0] layout_select=3, gap_select=1;
    reg screen_order_select=0, fps_select=0, touch_pressed=1;
    reg [7:0] touch_x=128, touch_y=96;
    reg lightpen_sensor=0, lightpen_button=0;
    reg [1:0] lightpen_level=0;
    reg touch_other=0;
    wire [17:0] lightpen_state;
    wire [1:0] layout_active, gap_active, pf_frame_bank;
    wire crt_active,split_active,screen_order_active,fps_active,pf_tgl,pf_scr,pf_bank,pf_external;
    wire [7:0] pf_line;
    reg published_frame_toggle=0, external_screen_toggle=0;
    reg [1:0] published_frame_bank=0, external_screen_bank=1;
    reg external_screen_select=1, external_enable=1, effective_3d_frame_toggle=0;
    wire external_screen_adopted_toggle,external_quiescent;
    wire [8:0] lb_raddr;
    // Dark green everywhere: 6-bit G=5 expands to 8-bit 0x14.
    wire [35:0] lb_q = {18'h00140,18'h00140};
    reg lb_valid=1;
    wire ce_pixel,de,hsync,vsync,analog_ce,analog_de,analog_hs,analog_vs;
    wire [7:0] red,green,blue,analog_r,analog_g,analog_b;
    nds_nitro_video_scanout dut(.analog_screen_active(), .pf_slot(), .pf_ticket(),
        .split_frame_toggle(), .pf_completed(4'b0), .lb_acquire(), .lb_hold(),
        .lb_selected_slot(4'b0), .*);

    task automatic frames(input integer n);
        repeat(n) begin @(posedge clk_video); while(!dut.lp_tick) @(posedge clk_video); @(negedge clk_video); end
    endtask
    task automatic digital_dot(input integer x, input integer y, output [23:0] rgb);
        while(!(dut.hcount==x && dut.vcount==y && dut.pixel_divider==dut.pixel_divider_limit))
            @(negedge clk_video);
        @(negedge clk_video); rgb={red,green,blue};
    endtask
    task automatic analog_dot(input integer x, input integer y, output [23:0] rgb);
        while(!(dut.analog_hcount==x && dut.analog_vcount==y && dut.analog_divider==9))
            @(negedge clk_video);
        @(negedge clk_video); rgb={analog_r,analog_g,analog_b};
    endtask
    // Drive the sensor for `width` clocks from the start of a raster dot.
    task automatic pulse(input bit analog, input integer x, input integer y, input integer width=40);
        if(analog) while(!(dut.analog_hcount==x && dut.analog_vcount==y && dut.analog_divider==0)) @(negedge clk_video);
        else while(!(dut.hcount==x && dut.vcount==y && dut.pixel_divider==0)) @(negedge clk_video);
        lightpen_sensor=1; repeat(width) @(negedge clk_video); lightpen_sensor=0;
        repeat(4) @(negedge clk_video);
    endtask
    task automatic expect_state(input [17:0] want, input string what);
        if(lightpen_state!==want) $fatal(1,"%s: state %h, wanted %h",what,lightpen_state,want);
    endtask
    task automatic expect_rgb(input [23:0] got, input [23:0] want, input string what);
        if(got!==want) $fatal(1,"%s: %h, wanted %h",what,got,want);
    endtask
    reg [23:0] rgb;
    initial begin
        repeat(8) @(negedge clk_video); reset=0;
        published_frame_toggle=1;
        wait(crt_active && layout_active==3); frames(2);
        // ---- CRT 240p digital raster, touch panel at 32..287 x 24..215.
        // A pulse starting at panel dot (X,Y) qualifies one dot later and is
        // corrected by -11 dots and +6 rows: it reports (X-10, Y+6).
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'h001400,"unlit pixel");
        digital_dot(32+128,24+96,rgb); expect_rgb(rgb,24'hff0000,"crosshair");
        pulse(0,32+100,24+50); expect_state({2'b00,8'd0,8'd0},"no capture without button");
        // Press: sampled at the next frame end, then one lit frame of settle.
        frames(1); lightpen_button=1;   // press at the top of a frame
        pulse(0,32+100,24+50);           // button not sampled yet
        frames(1);
        pulse(0,32+110,24+60);           // first lit frame: settle
        if(lightpen_state[16]) $fatal(1,"captured during press settle");
        frames(1);
        expect_state({2'b10,8'd0,8'd0},"armed, no pulse yet");
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'hbababa,"High floor");
        digital_dot(32+128,24+96,rgb); expect_rgb(rgb,24'hbababa,"crosshair hidden");
        digital_dot(10,10,rgb); expect_rgb(rgb,0,"border unlifted");
        // One frame: border pulse, spike, real pulse, then a later pulse.
        frames(1);
        pulse(0,10,24+20); expect_state({2'b10,8'd0,8'd0},"border pulse ignored");
        pulse(0,32+30,24+30,12); expect_state({2'b10,8'd0,8'd0},"short spike ignored");
        pulse(0,32+100,24+50); expect_state({2'b11,8'd56,8'd90},"first pulse, offsets applied");
        pulse(0,32+10,24+60); expect_state({2'b11,8'd56,8'd90},"second pulse in frame ignored");
        // Smoothing: small moves are halved toward the new X, +-1 is ignored,
        // a move beyond 8 dots jumps.
        frames(1); pulse(0,32+104,24+50); expect_state({2'b11,8'd56,8'd92},"+4 moves 2");
        frames(1); pulse(0,32+105,24+50); expect_state({2'b11,8'd56,8'd93},"+3 moves 1");
        frames(1); pulse(0,32+104,24+50); expect_state({2'b11,8'd56,8'd93},"+1 ignored");
        frames(1); pulse(0,32+100,24+50); expect_state({2'b11,8'd56,8'd92},"-3 moves -1");
        frames(1); pulse(0,32+150,24+60); expect_state({2'b11,8'd66,8'd140},"large move jumps");
        // Edges: the window runs 11 dots past the right edge; the bottom
        // clamps; pulses left of the window and the top rows behave.
        frames(1); pulse(0,32+265,24+191); expect_state({2'b11,8'd191,8'd255},"right edge reachable");
        frames(1); pulse(0,32+5,24+100); expect_state({2'b11,8'd191,8'd255},"left of window ignored");
        frames(1); pulse(0,32+150,24+0); expect_state({2'b11,8'd6,8'd140},"top row");
        // No pulse in a frame: the pen stays down at its last position.
        frames(2); expect_state({2'b11,8'd6,8'd140},"held without pulses");
        // Late/invalid lines are lifted too.
        lb_valid=0;
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'hbababa,"late line lifted");
        digital_dot(10,10,rgb); expect_rgb(rgb,0,"late border unlifted");
        lb_valid=1;
        // Levels.
        lightpen_level=1; frames(1);
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'h001400,"Off");
        lightpen_level=2; digital_dot(32+11,24+10,rgb); expect_rgb(rgb,24'h696969,"Low");
        lightpen_level=3; digital_dot(32+12,24+10,rgb); expect_rgb(rgb,24'h929292,"Medium");
        lightpen_level=0;
        // Raw release stops captures at once; the frame end lifts the pen.
        frames(1); lightpen_button=0;
        pulse(0,32+40,24+40); expect_state({2'b11,8'd6,8'd140},"no capture after raw release");
        frames(1); expect_state({2'b00,8'd6,8'd140},"release lifts pen");
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'h001400,"floor off after release");
        // The crosshair stays hidden until the mouse or stick is used.
        digital_dot(32+128,24+96,rgb); expect_rgb(rgb,24'h001400,"crosshair hidden after release");
        @(negedge clk_video); touch_other=1; @(negedge clk_video); touch_other=0;
        digital_dot(32+128,24+96,rgb); expect_rgb(rgb,24'hff0000,"crosshair back after other input");
        // Main panel (Left Only, screen 0) is not the touchscreen.
        lightpen_button=1; layout_select=2; wait(layout_active==2); frames(3);
        digital_dot(32+10,24+10,rgb); expect_rgb(rgb,24'h001400,"main panel lifted");
        pulse(0,32+60,24+80); expect_state({2'b10,8'd6,8'd140},"main panel ignored");
        // ---- Split: analog CRT shows Touch, digital stays untouched.
        split_select=1; layout_select=0; crt_select=0;
        wait(split_active); frames(3);
        analog_dot(32+10,24+10,rgb); expect_rgb(rgb,24'hbababa,"analog floor");
        digital_dot(10,10,rgb); expect_rgb(rgb,24'h001400,"HDMI raster lifted");
        frames(1);
        pulse(1,32+200,24+150,8); expect_state({2'b10,8'd6,8'd140},"analog spike ignored");
        pulse(1,32+200,24+150); expect_state({2'b11,8'd156,8'd190},"analog capture");
        frames(1); pulse(1,32+265,24+20); expect_state({2'b11,8'd26,8'd255},"analog right edge");
        lb_valid=0; frames(1);
        analog_dot(32+10,24+10,rgb); expect_rgb(rgb,24'hbababa,"analog late line lifted");
        digital_dot(10,10,rgb); expect_rgb(rgb,0,"HDMI late line stays black");
        lb_valid=1;
        analog_screen_select=0; frames(2);
        analog_dot(32+10,24+10,rgb); expect_rgb(rgb,24'h001400,"analog main lifted");
        pulse(1,32+5,24+5); expect_state({2'b11,8'd26,8'd255},"analog main ignored");
        $display("PASS: offsets and edge windows, X smoothing, crosshair ownership, spike filter, first pulse per frame, press settle, raw release, floor levels and late lines, border/main rejection, split analog");
        $finish;
    end
    initial begin #600000000; $fatal(1,"light pen test timeout"); end
endmodule
