// `timescale 1ns / 1ps
// `default_nettype none


// module obi_master_decoupled #(
//     parameter int ADDR_WIDTH = 32,
//     parameter int DATA_WIDTH = 32,
//     parameter int BE_WIDTH   = 4
// )(
//     //--------------------------------------------------------------------------
//     // System Signals
//     //--------------------------------------------------------------------------
//     input  logic                    clk,
//     input  logic                    rst_n, // Active low reset

//     //--------------------------------------------------------------------------
//     // Interface to Systolic Array (Accelerator Side)
//     //--------------------------------------------------------------------------
//     // Command Interface (Pushing memory requests)
//     input  logic                    acc_cmd_push_i,  // Array says: "I need a read/write"
//     input  logic [ADDR_WIDTH-1:0]   acc_cmd_addr_i,  // Target memory address
//     input  logic [DATA_WIDTH-1:0]   acc_cmd_wdata_i, // Write data (ignored if Read)
//     input  logic                    acc_cmd_we_i,    // 1 = Write, 0 = Read
//     input  logic [BE_WIDTH-1:0]     acc_cmd_be_i,    // Byte enables
//     output logic                    acc_cmd_full_o,  // Master says: "Stop pushing, FIFO full"

//     // Response Interface (Popping returned read data)
//     input  logic                    acc_resp_pop_i,  // Array says: "I'm consuming this read data"
//     output logic [DATA_WIDTH-1:0]   acc_resp_rdata_o,// Returned data from memory
//     output logic                    acc_resp_empty_o,// Master says: "No data available yet"

//     //--------------------------------------------------------------------------
//     // Open Bus Interface (OBI Physical Bus Side)
//     //--------------------------------------------------------------------------
//     // Request Phase
//     output logic                    obi_req_o,
//     input  logic                    obi_gnt_i,
//     output logic [ADDR_WIDTH-1:0]   obi_addr_o,
//     output logic                    obi_we_o,
//     output logic [BE_WIDTH-1:0]     obi_be_o,
//     output logic [DATA_WIDTH-1:0]   obi_wdata_o,
    
//     // Response Phase
//     input  logic                    obi_rvalid_i,
//     input  logic [DATA_WIDTH-1:0]   obi_rdata_i
// );

// localparam FIFO_DEPTH = 8; //must be greater or equal to 2 //Set at least to 3 to avoid stalls compared to the master branch
// localparam int unsigned FIFO_ADDR_DEPTH = $clog2(FIFO_DEPTH);
// logic [FIFO_ADDR_DEPTH:0] cmd_fifo_cnt;
// logic [FIFO_ADDR_DEPTH:0] next_cmd_fifo_cnt;
// logic cmd_pop_signal;
// logic next_cmd_fifo_empty;
// logic wire_to_obi_addr_o, wire_to_obi_wdata_o, wire_to_obi_we_o, wire_to_obi_be_o;

// // 1. THE COMMAND FIFO (Stores requests from Systolic Array to OBI Bus)
// FIFO #(
//     .FALL_THROUGH ( 1'b0 ), // Standard mode is usually fine for commands
//     .DATA_WIDTH   ( 32 + 32 + 1 + 4 ), // Packed width: [addr, wdata, we, be]
//     .DEPTH        ( FIFO_DEPTH )                // Tweak based on your system latency
// ) cmd_fifo_u (
//     .clk_i              ( clk ),
//     .rst_ni             ( rst_n ),
//     .flush_i            ( 1'b0 ), // Tie off or hook to master flush
//     .flush_but_first_i  ( 1'b0 ),
//     .testmode_i         ( 1'b0 ),
    
//     // Interface to Systolic Array (Push side)
//     .full_o             ( acc_cmd_full_o ), 
//     .push_i             ( acc_cmd_push_i ),
//     .data_i             ( {acc_cmd_addr_i, acc_cmd_wdata_i, acc_cmd_we_i, acc_cmd_be_i} ),
    
//     // Interface to OBI Master Logic (Pop side)
//     .empty_o            ( cmd_fifo_empty ), // Internal wire to your OBI FSM
//     .pop_i              ( cmd_pop_signal ), // Pop when OBI bus grants request
//     .data_o             ( {wire_to_obi_addr_o, wire_to_obi_wdata_o, wire_to_obi_we_o, wire_to_obi_be_o} ),
//     .cnt_o              (cmd_fifo_cnt), 
//     .next_cycle_cnt_o   (next_cmd_fifo_cnt)  
// );

// // 2. THE RESPONSE FIFO (Stores incoming read data until Array consumes it)
// FIFO #(
//     .FALL_THROUGH ( 1'b1 ), // ON: Crucial for streaming data with zero latency penalty
//     .DATA_WIDTH   ( 32 ),   // Stores rdata
//     .DEPTH        ( FIFO_DEPTH )     // Deep enough to cushion memory bus delays
// ) resp_fifo_u (
//     .clk_i              ( clk ),
//     .rst_ni             ( rst_n ),
//     .flush_i            ( 1'b0 ),
//     .flush_but_first_i  ( 1'b0 ),
//     .testmode_i         ( 1'b0 ),
    
//     // Interface to OBI Bus Phase (Push side)
//     .full_o             ( resp_fifo_full ), // If full, your master must stall OBI requests!
//     .push_i             ( obi_rvalid_i ),   // Capture data immediately when valid
//     .data_i             ( obi_rdata_i ),
    
//     // Interface to Systolic Array (Pop side)
//     .empty_o            ( acc_resp_empty_o ),
//     .pop_i              ( acc_resp_pop_i ),
//     .data_o             ( acc_resp_rdata_o ),
//     .cnt_o              ()
//     .next_cycle_cnt_o   ()
// );

//     logic outstanding_req;
//     typedef enum logic [1:0] {
//     IDLE        = 2'b00,
//     TRANSACTION_BUSY = 2'b01,
//     RESP_BUSY     = 2'b10,
//     BOTH_BUSY  = 2'b11,
//     } Master_state_t;

//     Master_state_t curr_state, next_state;
//     assign next_cmd_fifo_empty = (next_cmd_fifo_cnt=='0); // ONLY TRUE WHEN OPERATED IN STANDARD MODE.
//     // CMD FIFO always to be operated in standard mode.

//     always_ff @(posedge clk or negedge low_rst ) begin 
//         if (!low_rst) curr_state <= IDLE; 
//         else curr_state<=next_state;


//     end

//     assign cmd_pop_signal = obi_req_o && obi_gnt_i && !cmd_fifo_empty;
    

//     always_comb begin 
//         case (curr_state) 
//             IDLE : begin
//                 obi_req_o = '0;
//                 obi_addr_o= '0; 
//                 obi_we_o = '0;  
//                 obi_be_o = '0;
//                 obi_wdata_o = '0;
//                 next_state = next_cmd_fifo_empty? IDLE: TRANSACTION_BUSY;
//             end

//             TRANSACTION_BUSY : begin
//                 obi_req_o = '1; 
//                 obi_addr_o= wire_to_obi_addr_o; // INCOMING
//                 obi_we_o = wire_to_obi_we_o;
//                 obi_be_o = wire_to_obi_be_o;
//                 obi_wdata_o = wire_to_obi_wdata_o; // INCOMING

//                 if (next_cmd_fifo_empty) next_state=IDLE;
//                 else next_state = TRANSACTION_BUSY;
//             end


//         endcase
//     end



// endmodule


// //check oustanding reqs

`timescale 1ns / 1ps
`default_nettype none

module obi_master_decoupled #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int BE_WIDTH   = 4
)(
    input  logic                    clk,
    input  logic                    rst_n, // Active low reset

    // Interface to Systolic Array (Accelerator Side)
    input  logic                    acc_cmd_push_i,
    input  logic [ADDR_WIDTH-1:0]   acc_cmd_addr_i,
    input  logic [DATA_WIDTH-1:0]   acc_cmd_wdata_i,
    input  logic                    acc_cmd_we_i,
    input  logic [BE_WIDTH-1:0]     acc_cmd_be_i,
    output logic                    acc_cmd_full_o,

    input  logic                    acc_resp_pop_i,
    output logic [DATA_WIDTH-1:0]   acc_resp_rdata_o,
    output logic                    acc_resp_empty_o,

    // Open Bus Interface (OBI Physical Bus Side)
    output logic                    obi_req_o,
    input  logic                    obi_gnt_i,
    output logic [ADDR_WIDTH-1:0]   obi_addr_o,
    output logic                    obi_we_o,
    output logic [BE_WIDTH-1:0]     obi_be_o,
    output logic [DATA_WIDTH-1:0]   obi_wdata_o,
    
    input  logic                    obi_rvalid_i,
    input  logic [DATA_WIDTH-1:0]   obi_rdata_i
);

    localparam FIFO_DEPTH = 8;
    
    // Internal Signals
    logic cmd_fifo_empty;
    logic resp_fifo_full;
    logic cmd_pop_signal;
    
    // Correctly dimensioned wires for unpacking
    logic [ADDR_WIDTH-1:0] wire_to_obi_addr;
    logic [DATA_WIDTH-1:0] wire_to_obi_wdata;
    logic                  wire_to_obi_we;
    logic [BE_WIDTH-1:0]   wire_to_obi_be;

    // 1. THE COMMAND FIFO
    FIFO #(
        .FALL_THROUGH ( 1'b0 ), // Standard mode
        .DATA_WIDTH   ( ADDR_WIDTH + DATA_WIDTH + 1 + BE_WIDTH ), 
        .DEPTH        ( FIFO_DEPTH )
    ) cmd_fifo_u (
        .clk_i              ( clk ),
        .rst_ni             ( rst_n ),
        .flush_i            ( 1'b0 ),
        .flush_but_first_i  ( 1'b0 ),
        .testmode_i         ( 1'b0 ),
        
        .full_o             ( acc_cmd_full_o ), 
        .push_i             ( acc_cmd_push_i ),
        .data_i             ( {acc_cmd_addr_i, acc_cmd_wdata_i, acc_cmd_we_i, acc_cmd_be_i} ),
        
        .empty_o            ( cmd_fifo_empty ),
        .pop_i              ( cmd_pop_signal ), 
        .data_o             ( {obi_addr, obi_wdata, obi_we, obi_be} ),    // Drive the physical bus directly from the standard FIFO read-head outputs

        .cnt_o              ()
    );

    // 2. THE RESPONSE FIFO
    FIFO #(
        .FALL_THROUGH ( 1'b1 ), // Fall-through for zero-latency response data
        .DATA_WIDTH   ( DATA_WIDTH ),
        .DEPTH        ( FIFO_DEPTH )
    ) resp_fifo_u (
        .clk_i              ( clk ),
        .rst_ni             ( rst_n ),
        .flush_i            ( 1'b0 ),
        .flush_but_first_i  ( 1'b0 ),
        .testmode_i         ( 1'b0 ),
        
        .full_o             ( resp_fifo_full ),
        .push_i             ( obi_rvalid_i ),
        .data_i             ( obi_rdata_i ),
        
        .empty_o            ( acc_resp_empty_o ),
        .pop_i              ( acc_resp_pop_i ),
        .data_o             ( acc_resp_rdata_o ),
        .cnt_o              ()
    );

    //--------------------------------------------------------------------------
    // OBI Control Logic
    //--------------------------------------------------------------------------
    
    // We only make a request if we have a command ready AND our response buffer 
    // can handle the eventual data phase incoming back.
    assign obi_req_o = !cmd_fifo_empty && !resp_fifo_full;
    
    // Pop from FIFO ONLY when the handshake actually occurs on the bus pins
    assign cmd_pop_signal = obi_req_o && obi_gnt_i;

endmodule