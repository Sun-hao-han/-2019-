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
// Performs the 'sum' function in sum-of-absolute-differences. Supports multiple
// parallel output rows, where most of the required adder tree is shared.
// A single adder tree is used to form the output for the first row. Subsequent
// rows are generated by adding a new value and subtracting an old value.
// e.g. for a 5x5 window with 3 parallel output rows:
// out0 = in0 + in1 + in2 + in3 + in4
// out1 = out0 - in0 + in5
// out2 = out1 - in1 + in6

module dlsc_stereobm_pipe_adder #(
    parameter DATA          = 16,
    parameter SUM_BITS      = DATA+4,
    parameter SAD           = 15,
    parameter MULT_R        = 3,
    parameter META          = 4,
    // derived parameters; don't touch
    parameter SAD_R         = (SAD+MULT_R-1),
    parameter SUM_BITS_R    = (SUM_BITS*MULT_R)
) (
    input   wire                            clk,
    input   wire                            rst,
    
    input   wire                            in_valid,
    input   wire    [META-1:0]              in_meta,
    input   wire    [(DATA*SAD_R)-1:0]      in_data,
    
    output  wire                            out_valid,
    output  wire    [META-1:0]              out_meta,
    output  wire    [SUM_BITS_R-1:0]        out_data
);

/* verilator tracing_off */

genvar j;

//`include "dlsc_clog2.vh"

localparam LAT0 = `dlsc_clog2(SAD);     // latency through first stage
localparam LATN = LAT0 + MULT_R - 1;    // latency through last stage

// delay valid/meta
dlsc_pipedelay_valid #(
    .DATA       ( META ),
    .DELAY      ( LATN )
) dlsc_pipedelay_valid_inst (
    .clk        ( clk ),
    .rst        ( rst ),
    .in_valid   ( in_valid ),
    .in_data    ( in_meta ),
    .out_valid  ( out_valid ),
    .out_data   ( out_meta )
);

// outputs from each SAD stage
wire [SUM_BITS_R-1:0] sad;

// first SAD
dlsc_adder_tree #(
    .IN_BITS    ( DATA ),
    .OUT_BITS   ( SUM_BITS ),
    .INPUTS     ( SAD ),
    .META       ( 1 )
) dlsc_adder_tree_inst (
    .clk        ( clk ),
    .rst        ( rst ),
    .in_valid   ( 1'b1 ),
    .in_meta    ( 1'b0 ),
    .in_data    ( in_data[ 0 +: (DATA*SAD) ] ),
    .out_valid  (  ),
    .out_meta   (  ),
    .out_data   ( sad[ 0 +: SUM_BITS ] )
);

generate

    // generate other SADs
    for(j=0;j<(MULT_R-1);j=j+1) begin:GEN_SADS
        dlsc_stereobm_pipe_adder_slice #(
            .DATA       ( DATA ),
            .SUM_BITS   ( SUM_BITS ),
            .DELAY      ( LAT0+j )
        ) dlsc_stereobm_pipe_adder_slice_inst (
            .clk        ( clk ),
            .in_sub     ( in_data[ ((j+  0)*DATA) +: DATA ] ),      // subtract value falling outside window
            .in_add     ( in_data[ ((j+SAD)*DATA) +: DATA ] ),      // add value now within window
            .in_data    ( sad[ ((j+0)*SUM_BITS) +: SUM_BITS ] ),    // previous window
            .out_data   ( sad[ ((j+1)*SUM_BITS) +: SUM_BITS ] )     // resultant window (previous+add-sub)
        );
    end

    // generate delays for each output
    for(j=0;j<MULT_R;j=j+1) begin:GEN_DELAYS
        dlsc_pipedelay #(
            .DATA       ( SUM_BITS ),
            .DELAY      ( (MULT_R-1)-j )
        ) dlsc_pipedelay_valid_inst (
            .clk        ( clk ),
            .in_data    ( sad     [ (j*SUM_BITS) +: SUM_BITS ] ),
            .out_data   ( out_data[ (j*SUM_BITS) +: SUM_BITS ] )
        );
    end

endgenerate

/* verilator tracing_on */


//`ifdef DLSC_SIMULATION
//
//wire [DATA-1:0] inputs [SAD+MULT_R-2:0];
//wire [SUM_BITS-1:0] outputs [MULT_R-1:0];
//
//generate
//genvar g;
//for(g=0;g<SAD_R;g=g+1) begin:GEN_DBG_INPUTS
//    assign inputs[g] = in_data[(g*DATA)+DATA-1:(g*DATA)];
//end
//for(g=0;g<MULT_R;g=g+1) begin:GEN_DBG_OUTPUTS
//    assign outputs[g] = out_data[(g*SUM_BITS)+SUM_BITS-1:(g*SUM_BITS)];
//end
//endgenerate
//
//`endif


`ifdef DLSC_SIMULATION
`include "dlsc_sim_top.vh"
task report;
begin
//    dlsc_adder_tree_inst_com.report;
end
endtask
`include "dlsc_sim_bot.vh"
`endif


endmodule

