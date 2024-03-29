// 
// Copyright (c) 2011, Daniel Strother < http://danstrother.com/ >
// All rights reserved.
// 
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//   - Redistributions of source code must retain the above copyright notice,
//     this list of conditions and the following disclaimer.
//   - Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
//   - The name of the author may not be used to endorse or promote products
//     derived from this software without specific prior written permission.
// 
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
// WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
// EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
// TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

// Module Description:
// Final stage in the dlsc_stereobm_core pipeline. Combines calculated disparity
// data (from the pipeline) with corresponding image data (from the frontend).
// (well, it did.. but now the FIFOs for that are located at a higher level;
// e.g. dlsc_stereobm_buffered).
// For pixels that fall outside the valid window (and thus won't have a
// a disparity assigned by the pipeline), creates null disparity values.

module dlsc_stereobm_backend #(
    parameter IMG_WIDTH     = 320,
    parameter IMG_HEIGHT    = 21,
    parameter DISP_BITS     = 6,
    parameter DISPARITIES   = (2**DISP_BITS),
    parameter MULT_R        = 3,
    parameter SAD           = 9,
    parameter DATA          = 9,
    parameter SAD_BITS      = 16,
    // derived parameters; don't touch
    parameter DISP_BITS_R   = (DISP_BITS*MULT_R),
    parameter SAD_BITS_R    = (SAD_BITS*MULT_R),
    parameter DATA_R        = (DATA*MULT_R)
) (
    input   wire                        clk,
    input   wire                        rst,

    // input from frontend
    input   wire                        back_valid,         // asserts one cycle before back_left/right are valid
    input   wire    [DATA_R-1:0]        back_left,
    input   wire    [DATA_R-1:0]        back_right,

    // input from disparity block
    input   wire                        in_valid,
    input   wire    [MULT_R-1:0]        in_filtered,
    input   wire    [DISP_BITS_R-1:0]   in_disp,
    input   wire    [ SAD_BITS_R-1:0]   in_sad,
    
    // output
    output  wire                        out_disp_valid,
    output  wire    [DISP_BITS_R-1:0]   out_disp_data,
    output  wire    [MULT_R-1:0]        out_disp_masked,
    output  wire    [MULT_R-1:0]        out_disp_filtered,
    output  wire                        out_img_valid,
    output  wire    [DATA_R-1:0]        out_img_left,
    output  wire    [DATA_R-1:0]        out_img_right
);

//`include "dlsc_synthesis.v"
//`include "dlsc_clog2.v"
`ifdef USE_CLOG2

    `define dlsc_clog2(x) $clog2(x)

`else

    `define dlsc_clog2(x) dlsc_clog2_func(x)

    function integer dlsc_clog2_func;
        input integer val;
        integer i;
    begin
        i = val - 1;
        for(dlsc_clog2_func=0;i>0;dlsc_clog2_func=dlsc_clog2_func+1)
            i = i >> 1;
    end
    endfunction

`endif

`ifndef DLSC_SYNTHESIS_INCLUDED

`ifdef SYNTHESIS

//`ifdef XILINX
    `define DLSC_SYNTHESIS_DEFINED

    `define DLSC_BRAM               (* ram_style = "block", RDADDR_COLLISION_HWCONFIG = "performance" *)
    `define DLSC_LUTRAM             (* ram_style = "distributed" *)
    `define DLSC_SHREG              (* shreg_extract = "yes" *)
    `define DLSC_NO_SHREG           (* shreg_extract = "no" *)
    `define DLSC_KEEP_REG           (* equivalent_register_removal = "no" *)
    `define DLSC_PIPE_REG           (* equivalent_register_removal = "no", shreg_extract="no" *)
    // TODO: macro argument not respected by XST; hard-coded to 16 for now
    `define DLSC_FANOUT_REG(maxfan) (* equivalent_register_removal = "no", shreg_extract="no", register_duplication = "yes", max_fanout = "16" *)

`endif // XILINX

`ifdef ALTERA
    // TODO
`endif // ALTERA

`endif // SYNTHESIS

`ifndef DLSC_SYNTHESIS_DEFINED
    `define DLSC_SYNTHESIS_DEFINED

    `define DLSC_BRAM
    `define DLSC_LUTRAM
    `define DLSC_SHREG
    `define DLSC_NO_SHREG
    `define DLSC_KEEP_REG
    `define DLSC_PIPE_REG
    `define DLSC_FANOUT_REG(maxfan)

`endif // DLSC_SYNTHESIS_DEFINED

//`endif // DLSC_SYNTHESIS_INCLUDED
//localparam FIFO_DEPTH = 96; // must be deep enough to account for worst-case pipeline latency (and then some)
//
//localparam FIFO_DEPTH_BITS = `dlsc_clog2(FIFO_DEPTH);

localparam IMG_HEIGHT_R = (IMG_HEIGHT/MULT_R);
localparam COL_BITS     = `dlsc_clog2(IMG_WIDTH);
localparam ROW_BITS     = `dlsc_clog2(IMG_HEIGHT_R);


// ** control **

// first SAD/2 rows are masked
// last SAD/2 rows are masked
// first DISPARITIES+(SAD/2)-1 columns are masked
// last SAD/2 columns are masked
reg [MULT_R-1:0] disp_maskn;
reg              disp_maskn_any;
reg [MULT_R-1:0] disp_maskn_row;

reg     c0_ready;
wire    c0_valid    = c0_ready && ( !disp_maskn_any || in_valid );

reg [COL_BITS-1:0] col;
reg [ROW_BITS-1:0] row;

reg frame_first;    // asserts for first pixel of frame
reg frame_last;     // asserts for last pixel of frame
reg row_first;      // asserts for first pixel of row
reg row_last;       // asserts for last pixel of row

/* verilator lint_off WIDTH */
integer j;
always @(posedge clk) begin
    if(rst) begin
        disp_maskn      <= {MULT_R{1'b0}};
        disp_maskn_any  <= 1'b0;
        for(j=0;j<MULT_R;j=j+1) begin
            disp_maskn_row[j] <= !( ((SAD/2)-1) >= j );
        end
        col             <= 0;
        row             <= 0;
        frame_first     <= 1'b1;
        frame_last      <= 1'b0;
        row_first       <= 1'b1;
        row_last        <= 1'b0;
    end else if(c0_valid) begin
        frame_first     <= 1'b0;
        frame_last      <= 1'b0;
        row_first       <= 1'b0;
        row_last        <= 1'b0;
            
        if(col == (DISPARITIES+(SAD/2)-2)) begin
            // first DISPARITIES+(SAD/2)-1 columns are masked
            disp_maskn      <= disp_maskn_row;
            disp_maskn_any  <= |disp_maskn_row;
        end

        if(col == (IMG_WIDTH-(SAD/2)-1)) begin
            // last SAD/2 columns are masked
            disp_maskn      <= {MULT_R{1'b0}};
            disp_maskn_any  <= 1'b0;
        end

        if(col == (IMG_WIDTH-2)) begin
            row_last        <= 1'b1;
            if(row == (IMG_HEIGHT_R-1)) begin
                frame_last      <= 1'b1;
            end
        end

        if(!row_last) begin
            col             <= col + 1;
        end else begin
            col             <= 0;
            row_first       <= 1'b1;

            for(j=0;j<MULT_R;j=j+1) begin
                if(         ((SAD/2)-1) >= j &&
                    row == (((SAD/2)-1-j)/MULT_R) )
                begin
                    // first SAD/2 rows are masked
                    disp_maskn_row[j] <= 1'b1;
                end
                if( row == ((IMG_HEIGHT-(SAD/2)-1-j)/MULT_R) ) begin
                    // last SAD/2 rows are masked
                    disp_maskn_row[j] <= 1'b0;
                end
            end

            if(!frame_last) begin
                row             <= row + 1;
            end else begin
                row             <= 0;
                frame_first     <= 1'b1;
                for(j=0;j<MULT_R;j=j+1) begin
                    disp_maskn_row[j] <= !( ((SAD/2)-1) >= j );
                end
            end
        end
    end
end
/* verilator lint_on WIDTH */


// register buffer inputs
reg                   c1_disp_valid;
reg [DISP_BITS_R-1:0] c1_disp_data;
reg [MULT_R-1:0]      c1_disp_masked;
reg [MULT_R-1:0]      c1_disp_filtered;

always @(posedge clk) begin
    if(rst) begin
        c1_disp_valid      <= 1'b0;
    end else begin
        c1_disp_valid      <= c0_valid;
    end
end

integer i;
always @(posedge clk) begin
    for(i=0;i<MULT_R;i=i+1) begin
        // zero out masked disparity values
        c1_disp_data[(i*DISP_BITS)+:DISP_BITS] <= in_disp[(i*DISP_BITS)+:DISP_BITS] & {DISP_BITS{disp_maskn[i]}};
    end
    c1_disp_filtered   <= in_filtered & disp_maskn;
    c1_disp_masked     <= ~disp_maskn;
end

// re-register back_valid (align to data)
`DLSC_KEEP_REG reg c0_back_valid;
always @(posedge clk) begin
    if(rst) begin
        c0_back_valid   <= 1'b0;
    end else begin
        c0_back_valid   <= back_valid;
    end
end


// ** assign outputs **

assign out_disp_valid       = c1_disp_valid;
assign out_disp_data        = c1_disp_data;
assign out_disp_masked      = c1_disp_masked;
assign out_disp_filtered    = c1_disp_filtered;

assign out_img_valid        = c0_back_valid;
assign out_img_left         = back_left;
assign out_img_right        = back_right;


//// ** output buffering **
//
//// buffer for image data (from frontend)
//dlsc_fifo_shiftreg #(
//    .DATA           ( 2*DATA_R ),
//    .DEPTH          ( FIFO_DEPTH )
//) dlsc_fifo_shiftreg_inst_img (
//    .clk            ( clk ),
//    .rst            ( rst ),
//    .empty          (  ),
//    .full           (  ),
//    .almost_empty   (  ),
//    .almost_full    (  ),
//    .push_en        ( c0_back_valid ),
//    .push_data      ( {
//        back_left,
//        back_right
//        } ),
//    .pop_en         ( out_ready && out_valid ),
//    .pop_data       ( {
//        out_left,
//        out_right
//        } )
//);
//
//// buffer for disparity data (from pipeline or locally generated)
//wire fifo_disp_empty;
//assign out_valid = !fifo_disp_empty;
//dlsc_fifo_shiftreg #(
//    .DATA           ( DISP_BITS_R + (2*MULT_R) ),
//    .DEPTH          ( FIFO_DEPTH ),
//    .ALMOST_FULL    ( FIFO_DEPTH-8 )
//) dlsc_fifo_shiftreg_inst_disp (
//    .clk            ( clk ),
//    .rst            ( rst ),
//    .empty          ( fifo_disp_empty ),
//    .full           (  ),
//    .almost_empty   (  ),
//    .almost_full    ( back_busy ),
//    .push_en        ( c1_disp_valid ),
//    .push_data      ( {
//        c1_disp_data,
//        c1_disp_masked,
//        c1_disp_filtered
//        } ),
//    .pop_en         ( out_ready && out_valid ),
//    .pop_data       ( {
//        out_disp,
//        out_masked,
//        out_filtered
//        } )
//);


// track FIFO fill level differences
// (when disparity FIFO has fewer entries than image FIFO,
// the control logic must source more disparity values)
reg [7:0] disp_fifo_deficit; // must be large enough to account for maximum pipeline latency (on the order of 50-100 cycles)

always @(posedge clk) begin
    if(rst) begin
        c0_ready            <= 1'b0;
        disp_fifo_deficit   <= 0;
    end else begin
        if(c0_valid && !c0_back_valid) begin
            if(disp_fifo_deficit == 1) c0_ready <= 1'b0;
            disp_fifo_deficit   <= disp_fifo_deficit - 1;
        end
        if(!c0_valid && c0_back_valid) begin
            if(disp_fifo_deficit == 0) c0_ready <= 1'b1;
            disp_fifo_deficit   <= disp_fifo_deficit + 1;
        end
    end
end


`ifdef DLSC_SIMULATION
`include "dlsc_sim_top.vh"
always @(posedge clk) begin
    if(in_valid && !disp_maskn_any ) begin
        `dlsc_error("lost in_disp (masking)");
    end
    if(in_valid && !c0_ready) begin
        `dlsc_error("lost in_disp (missing back pixels)");
    end
    if(c0_ready != (disp_fifo_deficit != 0)) begin
        `dlsc_error("c0_ready must assert only when disp_fifo_deficit > 0");
    end
    if(c0_valid && !c0_back_valid && disp_fifo_deficit == 0) begin
        `dlsc_error("disp_fifo_deficit underflow");
    end
    if(!c0_valid && c0_back_valid && (&disp_fifo_deficit)) begin
        `dlsc_error("disp_fifo_deficit overflow");
    end
end

//integer out_valid_cnt;
//integer out_ready_cnt;
//always @(posedge clk) begin
//    if(rst) begin
//        out_valid_cnt   <= 0;
//        out_ready_cnt   <= 0;
//    end else if(out_valid) begin
//        out_valid_cnt    <= out_valid_cnt + 1;
//        if(out_ready) begin
//            out_ready_cnt    <= out_ready_cnt + 1;
//        end
//    end
//end

task report;
begin
//    `dlsc_info("output efficiency: %0d%% (%0d/%0d)",((out_ready_cnt*100)/out_valid_cnt),out_ready_cnt,out_valid_cnt);
//    dlsc_fifo_shiftreg_inst_img.report;
//    dlsc_fifo_shiftreg_inst_disp.report;
end
endtask
`include "dlsc_sim_bot.vh"
`endif


endmodule

