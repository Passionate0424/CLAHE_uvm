// ============================================================================
// Copyright (c) 2025 Passionate0424
// 
// GitHub: https://github.com/Passionate0424/CLAHE_verilog
// 
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// 
//     http://www.apache.org/licenses/LICENSE-2.0
// 
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
// ============================================================================

// ============================================================================
// CLAHE 对比度限制与CDF计算模块
//
// 功能描述:
//   - 在帧间隙期处理上一帧的直方图数据
//   - 对直方图进行对比度限制(Clip)操作，防止过度增强
//   - 重分配溢出的计数值到其他bins
//   - 计算累积分布函数(CDF)，用于像素映射
//   - 生成像素映射查找表，存储到CDF LUT RAM
//
// 处理流程（优化后）:
//   1. 读取并裁剪：从外部RAM读取直方图，同时判断并裁剪超限bins（READ_HIST_CLIP）
//   2. 重分配溢出：将溢出值均匀分配到所有bins（CLIP_REDIST，仅在有溢出时执行）
//   3. CDF计算：对处理后的直方图进行累积求和（CALC_CDF）
//   4. 归一化：将CDF值映射到0-255范围，生成查找表（WRITE_LUT）
//   5. 写入RAM：供后续像素映射使用
//
// 时序分析（使用32周期流水线除法器优化后）:
//   - 每tile处理时间：约1067个时钟周期
//     * READ_HIST_CLIP: 257周期（读取+裁剪合并）
//     * CLIP_REDIST:    257周期
//     * CALC_CDF:       257周期
//     * WRITE_LUT:      290周期（1初始化 + 256读取 + 32除法器延迟 + 1排空）
//     * 其他状态:       约6周期
//   - 总处理时间：64 × 1067 ≈ 68,288周期（使用流水线除法器）
//   - 在74MHz时钟下：约0.92ms完成所有处理
//   - 帧间隙时间充足：33ms@30fps，处理时间占比<3%
//
// 关键算法（标准CLAHE实现）:
//   - Clip阈值：clip_limit = (tile_pixels / 256) × clip_factor
//   - 溢出重分配：avg = excess/256, remainder = excess%256
//                 前remainder个bins加(avg+1)，其余bins加avg
//   - CDF归一化：cdf_norm = (cdf[i] - cdf_min) × 255 / (cdf_max - cdf_min)
//                使用32周期流水线除法器，高频友好
//
// 流水线优化（归一化阶段 - 使用流水线除法器）:
//   - 阶段1（1周期）：从CDF RAM读取 + 减法（cdf - cdf_min）
//   - 阶段2（1周期）：乘法（diff × 255）+ 送入除法器
//   - 阶段3（32周期）：流水线除法（mult / cdf_range）
//   - 阶段4（1周期）：饱和处理 + 写入外部RAM
//   - 地址对齐：使用32级移位寄存器延迟地址路径
//   - 时序裕度：可稳定运行在148.5MHz（6.7ns周期）
//
// 作者: Passionate.Z
// 日期: 2025-10-15
// ============================================================================

module clahe_clipper_cdf #(
        parameter TILE_NUM = 16,
        parameter BINS = 256,
        parameter TILE_PIXELS = 57600  // 320*180
    )(
        input  wire         pclk,
        input  wire         rst_n,

        // 控制信号
        input  wire         frame_hist_done,    // 直方图统计完成，触发处理
        input  wire [15:0]  clip_limit,         // 裁剪阈值
        input  wire         ping_pong_flag,     // 读取哪个hist RAM (与统计相反)

        // 直方图RAM读接口
        output reg  [$clog2(TILE_NUM)-1:0] hist_rd_tile_idx,   // 读tile索引
        output reg  [7:0]   hist_rd_bin_addr,   // 读bin地址 (0-255)
        input  wire [15:0]  hist_rd_data_a,     // RAM A数据
        input  wire [15:0]  hist_rd_data_b,     // RAM B数据

        // CDF LUT写入接口
        output reg  [$clog2(TILE_NUM)-1:0] cdf_wr_tile_idx,   // 写tile索引
        output reg  [7:0]   cdf_wr_bin_addr,   // 写bin地址
        output reg  [7:0]   cdf_wr_data,        // 映射后的灰度值
        output reg          cdf_wr_en,         // 写使能

        // 状态输出
        output reg          cdf_done,           // CDF计算完成，可开始映射
        output reg          processing          // 处理中标志
    );

    // ========================================================================
    // 状态机定义
    // ========================================================================
    // 状态机用于控制整个CDF计算流程
    localparam IDLE           = 4'd0;  // 空闲状态，等待触发
    localparam READ_HIST_CLIP = 4'd1;  // 读取直方图并同时进行裁剪（优化合并）
    localparam CLIP_REDIST    = 4'd3;  // 重分配溢出值到其他bins
    localparam CALC_CDF       = 4'd4;  // 计算累积分布函数
    localparam WRITE_LUT      = 4'd5;  // 写入CDF查找表到RAM
    localparam NEXT_TILE      = 4'd6;  // 处理下一个tile
    localparam DONE           = 4'd7;  // 所有tile处理完成
    localparam DONE_PULSE     = 4'd8;  // 完成脉冲状态，用于重置cdf_done

    reg  [3:0]  state, next_state;       // 当前状态和下一状态

    // ========================================================================
    // 内部寄存器和信号
    // ========================================================================
    localparam TILE_IDX_WIDTH = $clog2(TILE_NUM);

    reg  [TILE_IDX_WIDTH-1:0] tile_cnt;    // 当前处理的tile索引
    reg  [8:0]  bin_cnt;                   // 当前处理的bin索引(0-256)

    // frame_hist_done现在是单周期脉冲，无需边沿检测

    // ========================================================================
    // RAM优化：使用RAM替代大型寄存器数组
    // ========================================================================
    // hist_buf RAM: 存储直方图数据（256×16bit）
    wire        hist_buf_ena;
    wire        hist_buf_wea;
    wire [7:0]  hist_buf_addra;
    wire [15:0] hist_buf_dina;
    wire [15:0] hist_buf_douta;
    wire        hist_buf_enb;
    wire        hist_buf_web;
    wire [7:0]  hist_buf_addrb;
    wire [15:0] hist_buf_dinb;
    wire [15:0] hist_buf_doutb;

    // cdf RAM: 存储CDF数据（256×16bit）
    wire        cdf_ram_ena;
    wire        cdf_ram_wea;
    wire [7:0]  cdf_ram_addra;
    wire [15:0] cdf_ram_dina;
    wire [15:0] cdf_ram_douta;
    wire        cdf_ram_enb;
    wire        cdf_ram_web;
    wire [7:0]  cdf_ram_addrb;
    wire [15:0] cdf_ram_dinb;
    wire [15:0] cdf_ram_doutb;

    // RAM控制信号寄存器
    reg         hist_buf_ena_r;
    reg         hist_buf_wea_r;
    reg  [7:0]  hist_buf_addra_r;
    reg  [15:0] hist_buf_dina_r;
    reg         hist_buf_enb_r;
    reg         hist_buf_web_r;
    reg  [7:0]  hist_buf_addrb_r;
    reg  [15:0] hist_buf_dinb_r;

    reg         cdf_ram_ena_r;
    reg         cdf_ram_wea_r;
    reg  [7:0]  cdf_ram_addra_r;
    reg  [15:0] cdf_ram_dina_r;
    reg         cdf_ram_enb_r;
    reg         cdf_ram_web_r;
    reg  [7:0]  cdf_ram_addrb_r;
    reg  [15:0] cdf_ram_dinb_r;

    // 连接寄存器到RAM
    assign hist_buf_ena = hist_buf_ena_r;
    assign hist_buf_wea = hist_buf_wea_r;
    assign hist_buf_addra = hist_buf_addra_r;
    assign hist_buf_dina = hist_buf_dina_r;
    assign hist_buf_enb = hist_buf_enb_r;
    assign hist_buf_web = hist_buf_web_r;
    assign hist_buf_addrb = hist_buf_addrb_r;
    assign hist_buf_dinb = hist_buf_dinb_r;

    assign cdf_ram_ena = cdf_ram_ena_r;
    assign cdf_ram_wea = cdf_ram_wea_r;
    assign cdf_ram_addra = cdf_ram_addra_r;
    assign cdf_ram_dina = cdf_ram_dina_r;
    assign cdf_ram_enb = cdf_ram_enb_r;
    assign cdf_ram_web = cdf_ram_web_r;
    assign cdf_ram_addrb = cdf_ram_addrb_r;
    assign cdf_ram_dinb = cdf_ram_dinb_r;

    // Clip相关信号 - 标准CLAHE实现
    reg  [16:0] excess_total;          // 总溢出量 (最大57600+裕度)
    wire [8:0]  excess_per_bin;        // 每个bin分配的溢出量（整数部分）
    wire [7:0]  excess_remainder;      // 余数部分（需要分配给前N个bins）

    // CDF相关信号 - 标准CLAHE实现（带流水线优化）
    // 57600像素累加，用16位安全（最大65535 > 57600）
    reg  [15:0] cdf_min;               // CDF最小值
    reg         cdf_min_found;         // cdf_min是否已找到（用于查找第一个非零CDF）
    reg  [15:0] cdf_max;               // CDF最大值
    reg  [15:0] cdf_range;             // CDF范围
    reg  [15:0] cdf_temp;              // 临时累加值

    // 归一化流水线寄存器（3级流水：读取→乘法→除法）
    reg  [15:0] norm_stage1_diff;      // 阶段1：cdf - cdf_min
    reg  [31:0] norm_stage2_mult;      // 阶段2：diff * 255
    reg  [7:0]  norm_stage1_addr;      // 阶段1的地址（用于延迟对齐）
    reg  [7:0]  norm_stage2_addr;      // 阶段2的地址（用于延迟对齐）

    // RAM读取数据缓存（用于处理RAM的1周期延迟）
    reg  [15:0] hist_buf_data_reg;     // hist_buf读取数据缓存
    reg  [15:0] cdf_ram_data_reg;      // cdf_ram读取数据缓存

    // 乒乓RAM数据选择
    // CDF读取当前帧统计的RAM（与统计写入同一组）
    // ping_pong_flag=0：统计写RAM_A，CDF读RAM_A
    // ping_pong_flag=1：统计写RAM_B，CDF读RAM_B
    wire [15:0] hist_rd_data;           // 根据ping_pong_flag选择读取的RAM数据
    assign hist_rd_data = ping_pong_flag ? hist_rd_data_b : hist_rd_data_a;

    // 标准CLAHE：将溢出量平均分配到所有256个bins
    assign excess_per_bin = excess_total[16:8];      // 整数部分：除以256（等效于右移8位）
    assign excess_remainder = excess_total[7:0];     // 余数部分：模256（等效于取低8位）

    // ========================================================================
    // 流水线除法器信号
    // ========================================================================
    localparam DIV_LATENCY = 33;       // 除法器流水线延迟（Stage0锁存+32处理阶段）

    wire        div_start;              // 除法器启动信号
    wire        div_done;               // 除法器完成信号
    wire [31:0] div_quotient;           // 除法器商输出
    wire [31:0] div_remainder;          // 除法器余数输出

    // 地址延迟移位寄存器（补偿32周期除法器延迟）
    // 从Stage2（乘法结果送入除法器）到div_done需要32周期
    reg [7:0] addr_delay_reg [0:DIV_LATENCY-1];
    wire [7:0] addr_delayed;
    assign addr_delayed = addr_delay_reg[DIV_LATENCY-1];  // 输出端

    // 地址延迟移位寄存器逻辑
    integer di;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            for (di = 0; di < DIV_LATENCY; di = di + 1)
                addr_delay_reg[di] <= 8'd0;
        end
        else begin
            addr_delay_reg[0] <= norm_stage2_addr;  // 输入端：乘法阶段的地址
            for (di = 1; di < DIV_LATENCY; di = di + 1)
                addr_delay_reg[di] <= addr_delay_reg[di-1];
        end
    end

    // 除法器启动：当乘法阶段有有效数据时启动
    // bin_cnt >= 2 时 Stage2 有有效的乘法结果
    // bin_cnt <= 257 确保只启动256次（对应bin 0-255）
    assign div_start = (state == WRITE_LUT) && (bin_cnt >= 9'd2) && (bin_cnt <= 9'd257);

    // 饱和处理：使用除法器输出（但需处理cdf_range为0的情况）
    wire [7:0]  norm_saturated;
    // 当cdf_range为0时，返回128（标准CLAHE：所有像素映射到中间灰度）
    assign norm_saturated = (cdf_range == 16'd0) ? 8'd128 :
           (div_quotient > 32'd255) ? 8'd255 : div_quotient[7:0];

    // ========================================================================
    // RAM实例化：hist_buf和cdf使用真双端口RAM
    // ========================================================================
    // hist_buf RAM实例：用于存储直方图数据
    clahe_true_dual_port_ram #(
                                 .DATA_WIDTH(16),
                                 .ADDR_WIDTH(8),
                                 .DEPTH(256)
                             ) hist_buf_ram_inst (
                                 .clk(pclk),
                                 // 端口A
                                 .ena(hist_buf_ena),
                                 .wea(hist_buf_wea),
                                 .addra(hist_buf_addra),
                                 .dina(hist_buf_dina),
                                 .douta(hist_buf_douta),
                                 // 端口B
                                 .enb(hist_buf_enb),
                                 .web(hist_buf_web),
                                 .addrb(hist_buf_addrb),
                                 .dinb(hist_buf_dinb),
                                 .doutb(hist_buf_doutb)
                             );

    // cdf RAM实例：用于存储CDF数据
    clahe_true_dual_port_ram #(
                                 .DATA_WIDTH(16),
                                 .ADDR_WIDTH(8),
                                 .DEPTH(256)
                             ) cdf_ram_inst (
                                 .clk(pclk),
                                 // 端口A
                                 .ena(cdf_ram_ena),
                                 .wea(cdf_ram_wea),
                                 .addra(cdf_ram_addra),
                                 .dina(cdf_ram_dina),
                                 .douta(cdf_ram_douta),
                                 // 端口B
                                 .enb(cdf_ram_enb),
                                 .web(cdf_ram_web),
                                 .addrb(cdf_ram_addrb),
                                 .dinb(cdf_ram_dinb),
                                 .doutb(cdf_ram_doutb)
                             );

    // ========================================================================
    // 流水线除法器实例化
    // ========================================================================
    // 32周期流水线除法器，用于CDF归一化
    // 被除数：norm_stage2_mult (diff * 255)
    // 除数：cdf_range (cdf_max - cdf_min)
    clahe_divider_pipelined #(
                                .DATA_WIDTH(32)
                            ) u_divider (
                                .clk      (pclk),
                                .rst_n    (rst_n),
                                .start    (div_start),
                                .dividend (norm_stage2_mult),
                                .divisor  ({16'd0, cdf_range}),
                                .done     (div_done),
                                .quotient (div_quotient),
                                .remainder(div_remainder)
                            );

    integer i;

    // ========================================================================
    // 状态机 - 时序逻辑
    // ========================================================================
    // 功能：状态机的时序部分，在每个时钟上升沿更新状态
    // 复位：系统复位时回到IDLE状态
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;  // 复位时回到空闲状态
        end
        else begin
            state <= next_state;  // 更新到下一状态
        end
    end

    // ========================================================================
    // 状态机 - 组合逻辑
    // ========================================================================
    // 功能：状态机的组合逻辑部分，根据当前状态和条件决定下一状态
    // 状态转换：IDLE → READ_HIST_CLIP → CLIP_REDIST → CALC_CDF → WRITE_LUT → NEXT_TILE → DONE
    always @(*) begin
        next_state = state;  // 默认保持当前状态

        case (state)
            IDLE: begin
                // 空闲状态：等待直方图统计完成脉冲
                if (frame_hist_done) begin
                    next_state = READ_HIST_CLIP;  // 开始读取直方图数据并裁剪
                end
            end

            READ_HIST_CLIP: begin
                // 读取直方图并裁剪状态：逐个读取256个bins并同时进行裁剪判断
                // 修复：由于RAM有1周期延迟，需要257个周期（0-256）
                if (bin_cnt == 9'd256) begin
                    // 修复：同时检查当前寄存器值和当前正在处理的bin是否溢出
                    if (excess_total > 0 || (hist_rd_data > clip_limit)) begin
                        next_state = CLIP_REDIST;  // 有溢出，需要重分配
                    end
                    else begin
                        next_state = CALC_CDF;     // 无溢出，直接计算CDF
                    end
                end
            end

            CLIP_REDIST: begin
                // Clip重分配状态：将溢出值重分配到其他bins
                // 需要257个周期完成(0-256)，在bin_cnt==256时所有数据处理完毕
                if (bin_cnt == 256) begin
                    next_state = CALC_CDF;  // 重分配完成，开始计算CDF
                end
            end

            CALC_CDF: begin
                // CDF计算状态：计算累积分布函数
                // 需要257个周期完成(0-256)，在bin_cnt==256时所有数据处理完毕
                if (bin_cnt == 256) begin
                    next_state = WRITE_LUT;  // CDF计算完成，开始写入查找表
                end
            end

            WRITE_LUT: begin
                // 写入查找表状态：将CDF结果写入RAM
                // 流水线优化：需要291个周期（1初始化 + 256读取 + 33除法器延迟 + 1排空）
                // bin_cnt=290时最后一个除法结果写入完成
                if (bin_cnt == 290) begin
                    next_state = NEXT_TILE;  // 写入完成，处理下一个tile
                end
            end

            NEXT_TILE: begin
                // 下一个tile状态：检查是否还有tile需要处理
                if (tile_cnt == TILE_NUM - 1) begin
                    next_state = DONE;           // 所有tile处理完成
                end
                else begin
                    next_state = READ_HIST_CLIP;  // 还有tile，继续处理
                end
            end

            DONE: begin
                // 完成状态：所有处理完成，进入脉冲状态
                next_state = DONE_PULSE;
            end

            DONE_PULSE: begin
                // 脉冲状态：重置cdf_done信号，然后回到空闲状态
                next_state = IDLE;
            end

            default:
                next_state = IDLE;  // 异常情况，回到空闲状态
        endcase
    end

    // ========================================================================
    // 处理逻辑
    // ========================================================================
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            tile_cnt <= {TILE_IDX_WIDTH{1'b0}};
            bin_cnt <= 9'd0;
            excess_total <= 17'd0;
            cdf_min <= 16'd0;
            cdf_min_found <= 1'b0;
            cdf_max <= 16'd0;
            cdf_range <= 16'd0;
            cdf_temp <= 16'd0;

            // 归一化流水线寄存器
            norm_stage1_diff <= 16'd0;
            norm_stage2_mult <= 32'd0;
            norm_stage1_addr <= 8'd0;
            norm_stage2_addr <= 8'd0;

            hist_rd_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
            hist_rd_bin_addr <= 8'd0;
            cdf_wr_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
            cdf_wr_bin_addr <= 8'd0;
            cdf_wr_data <= 8'd0;
            cdf_wr_en <= 1'b0;
            processing <= 1'b0;
            cdf_done <= 1'b0;

            // RAM控制信号初始化
            hist_buf_ena_r <= 1'b0;
            hist_buf_wea_r <= 1'b0;
            hist_buf_addra_r <= 8'd0;
            hist_buf_dina_r <= 16'd0;
            hist_buf_enb_r <= 1'b0;
            hist_buf_web_r <= 1'b0;
            hist_buf_addrb_r <= 8'd0;
            hist_buf_dinb_r <= 16'd0;

            cdf_ram_ena_r <= 1'b0;
            cdf_ram_wea_r <= 1'b0;
            cdf_ram_addra_r <= 8'd0;
            cdf_ram_dina_r <= 16'd0;
            cdf_ram_enb_r <= 1'b0;
            cdf_ram_web_r <= 1'b0;
            cdf_ram_addrb_r <= 8'd0;
            cdf_ram_dinb_r <= 16'd0;

            hist_buf_data_reg <= 16'd0;
            cdf_ram_data_reg <= 16'd0;
        end
        else begin
            case (state)
                // ============================================================
                // IDLE: 等待触发
                // ============================================================
                IDLE: begin
                    // 保持所有RAM信号稳定，避免X态
                    hist_rd_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    hist_rd_bin_addr <= 8'd0;
                    cdf_wr_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    cdf_wr_bin_addr <= 8'd0;
                    cdf_wr_en <= 1'b0;

                    // 禁用内部RAM
                    hist_buf_ena_r <= 1'b0;
                    hist_buf_wea_r <= 1'b0;
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    if (frame_hist_done) begin
                        tile_cnt <= {TILE_IDX_WIDTH{1'b0}};
                        bin_cnt <= 9'd0;
                        processing <= 1'b1;
                        excess_total <= 17'd0; // Reset excess_total for safety
                    end
                end

                // ============================================================
                // READ_HIST_CLIP: 读取当前tile的256个bins并同时进行裁剪
                // 优化：合并原READ_HIST和CLIP_SCAN，节省257个周期
                // ============================================================
                READ_HIST_CLIP: begin
                    hist_rd_tile_idx <= tile_cnt;    // 选择当前tile对应的RAM
                    cdf_wr_tile_idx <= tile_cnt;     // 保持CDF写信号稳定
                    cdf_wr_bin_addr <= 8'd0;
                    cdf_wr_en <= 1'b0;

                    // 禁用cdf RAM
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    // 周期0: 初始化excess_total并发出第一个地址
                    if (bin_cnt == 0) begin
                        excess_total <= 17'd0;
                        hist_rd_bin_addr <= 8'd0;
                        hist_buf_ena_r <= 1'b0;
                        hist_buf_wea_r <= 1'b0;
                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    // 周期1-255: 读取并处理数据
                    else if (bin_cnt < 9'd256) begin
                        // 继续发出下一个地址（周期1-255发出地址1-255）
                        hist_rd_bin_addr <= bin_cnt[7:0];

                        // 处理上一周期读取的数据（周期1开始有效数据）
                        if (bin_cnt > 0) begin
                            // 判断是否需要裁剪
                            if (hist_rd_data > clip_limit) begin
                                // 超过阈值：计算溢出量，写入裁剪后的值
                                excess_total <= excess_total + ({1'd0, hist_rd_data} - {1'd0, clip_limit});
                                hist_buf_ena_r <= 1'b1;
                                hist_buf_wea_r <= 1'b1;
                                hist_buf_addra_r <= bin_cnt[7:0] - 1;
                                hist_buf_dina_r <= clip_limit;  // 裁剪到阈值
                            end
                            else begin
                                // 未超阈值：写入原始值
                                hist_buf_ena_r <= 1'b1;
                                hist_buf_wea_r <= 1'b1;
                                hist_buf_addra_r <= bin_cnt[7:0] - 1;
                                hist_buf_dina_r <= hist_rd_data;  // 保持原值
                            end
                        end

                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    // 周期256: 处理最后一个bin（bin 255）并重置计数器
                    else if (bin_cnt == 9'd256) begin
                        // 处理bin 255的数据
                        if (hist_rd_data > clip_limit) begin
                            // 超过阈值：计算溢出量，写入裁剪后的值
                            excess_total <= excess_total + ({1'd0, hist_rd_data} - {1'd0, clip_limit});
                            hist_buf_ena_r <= 1'b1;
                            hist_buf_wea_r <= 1'b1;
                            hist_buf_addra_r <= 8'd255;
                            hist_buf_dina_r <= clip_limit;  // 裁剪到阈值
                        end
                        else begin
                            // 未超阈值：写入原始值
                            hist_buf_ena_r <= 1'b1;
                            hist_buf_wea_r <= 1'b1;
                            hist_buf_addra_r <= 8'd255;
                            hist_buf_dina_r <= hist_rd_data;  // 保持原值
                        end

                        // 立即重置计数器，准备进入下一状态
                        bin_cnt <= 9'd0;
                    end
                    else begin
                        // 安全分支：不应该到达这里
                        hist_buf_ena_r <= 1'b0;
                        hist_buf_wea_r <= 1'b0;
                        bin_cnt <= 9'd0;
                    end
                end

                // ============================================================
                // CLIP_REDIST: 重分配溢出量到所有bins（标准CLAHE）
                // 标准算法：每个bin加上平均值，前remainder个bin额外加1
                // ============================================================
                CLIP_REDIST: begin
                    // 保持外部RAM信号稳定，避免X态
                    hist_rd_tile_idx <= tile_cnt;
                    hist_rd_bin_addr <= 8'd0;
                    cdf_wr_tile_idx <= tile_cnt;
                    cdf_wr_bin_addr <= 8'd0;
                    cdf_wr_en <= 1'b0;

                    // 禁用cdf RAM
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    // 标准CLAHE：所有bins都接收溢出值
                    // 使用端口A读取，端口B写回
                    // 周期0-255: 发出读地址0-255
                    // 周期1-256: 接收并处理数据0-255，写回到端口B
                    if (bin_cnt < 9'd256) begin
                        hist_buf_ena_r <= 1'b1;
                        hist_buf_wea_r <= 1'b0;
                        hist_buf_addra_r <= bin_cnt[7:0];
                    end
                    else begin
                        hist_buf_ena_r <= 1'b0;
                        hist_buf_wea_r <= 1'b0;
                    end

                    // 从周期1开始处理读取的数据并写回，周期256处理最后一个数据
                    if (bin_cnt > 0 && bin_cnt <= 9'd256) begin
                        hist_buf_enb_r <= 1'b1;
                        hist_buf_web_r <= 1'b1;
                        hist_buf_addrb_r <= bin_cnt[7:0] - 1;

                        // 标准CLAHE余数分配：前remainder个bins额外加1
                        if ((bin_cnt[7:0] - 1) < excess_remainder) begin
                            // 前remainder个bins：加上 avg_increment + 1
                            hist_buf_dinb_r <= hist_buf_douta + {7'd0, excess_per_bin} + 16'd1;
                        end
                        else begin
                            // 剩余bins：只加上 avg_increment
                            hist_buf_dinb_r <= hist_buf_douta + {7'd0, excess_per_bin};
                        end
                    end
                    else begin
                        hist_buf_enb_r <= 1'b0;
                        hist_buf_web_r <= 1'b0;
                    end

                    if (bin_cnt < 9'd256) begin
                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    else begin
                        bin_cnt <= 9'd0;
                    end
                end

                // ============================================================
                // CALC_CDF: 计算累积分布函数
                // ============================================================
                CALC_CDF: begin
                    // 保持外部RAM信号稳定，避免X态
                    hist_rd_tile_idx <= tile_cnt;
                    hist_rd_bin_addr <= 8'd0;
                    cdf_wr_tile_idx <= tile_cnt;
                    cdf_wr_bin_addr <= 8'd0;
                    cdf_wr_en <= 1'b0;

                    // 禁用hist_buf RAM（不再需要）
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;

                    // 周期0: 发出读地址0
                    // 周期1-255: 接收bin 0-254数据，写入cdf[0-254]，发出读地址1-255
                    // 周期256: 接收bin 255数据，写入cdf[255]
                    if (bin_cnt == 0) begin
                        // 初始化：第一个周期发出读地址0
                        hist_buf_ena_r <= 1'b1;
                        hist_buf_wea_r <= 1'b0;
                        hist_buf_addra_r <= 8'd0;

                        cdf_temp <= 16'd0;
                        cdf_min <= 16'd0;
                        cdf_min_found <= 1'b0;  // 重置cdf_min查找标志
                        cdf_max <= 16'd0;

                        // 禁用cdf RAM写入
                        cdf_ram_ena_r <= 1'b0;
                        cdf_ram_wea_r <= 1'b0;

                        bin_cnt <= 9'd1;
                    end
                    else if (bin_cnt <= 9'd255) begin
                        // 周期1-255: 发出下一个读地址，同时处理上一周期的数据
                        hist_buf_ena_r <= 1'b1;
                        hist_buf_wea_r <= 1'b0;
                        hist_buf_addra_r <= bin_cnt[7:0];

                        // 处理上一周期读取的数据
                        cdf_temp <= cdf_temp + hist_buf_douta;

                        // 写入CDF到RAM
                        cdf_ram_ena_r <= 1'b1;
                        cdf_ram_wea_r <= 1'b1;
                        cdf_ram_addra_r <= bin_cnt[7:0] - 1;
                        cdf_ram_dina_r <= cdf_temp + hist_buf_douta;

                        // 标准CLAHE：查找第一个非零CDF值作为cdf_min
                        if (!cdf_min_found && (cdf_temp + hist_buf_douta) > 16'd0) begin
                            cdf_min <= cdf_temp + hist_buf_douta;
                            cdf_min_found <= 1'b1;
                        end

                        // 更新cdf_max（始终跟踪最大值）
                        if ((cdf_temp + hist_buf_douta) > cdf_max) begin
                            cdf_max <= cdf_temp + hist_buf_douta;
                        end

                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    else begin
                        // 周期256: 处理bin 255的数据
                        hist_buf_ena_r <= 1'b0;
                        hist_buf_wea_r <= 1'b0;

                        cdf_temp <= cdf_temp + hist_buf_douta;

                        // 写入最后一个CDF值
                        cdf_ram_ena_r <= 1'b1;
                        cdf_ram_wea_r <= 1'b1;
                        cdf_ram_addra_r <= 8'd255;
                        cdf_ram_dina_r <= cdf_temp + hist_buf_douta;

                        // 标准CLAHE：查找第一个非零CDF值作为cdf_min
                        if (!cdf_min_found && (cdf_temp + hist_buf_douta) > 16'd0) begin
                            cdf_min <= cdf_temp + hist_buf_douta;
                            cdf_min_found <= 1'b1;
                        end

                        // 更新cdf_max（最后一个值）
                        if ((cdf_temp + hist_buf_douta) > cdf_max) begin
                            cdf_max <= cdf_temp + hist_buf_douta;
                        end

                        bin_cnt <= 9'd0;
                    end
                end

                // ============================================================
                // WRITE_LUT: 归一化并写入CDF查找表（32级流水线除法器优化）
                // 标准公式：normalized_cdf = (cdf - cdf_min) * 255 / (cdf_max - cdf_min)
                // 流水线：读取RAM → 减法 → 乘法 → 32周期除法 → 写入
                // ============================================================
                WRITE_LUT: begin
                    // 保持外部hist RAM读信号稳定，避免X态
                    hist_rd_tile_idx <= tile_cnt;
                    hist_rd_bin_addr <= 8'd0;

                    // 禁用hist_buf RAM
                    hist_buf_ena_r <= 1'b0;
                    hist_buf_wea_r <= 1'b0;
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;

                    // 周期0: 初始化，计算cdf_range，发出读地址0
                    if (bin_cnt == 0) begin
                        cdf_range <= cdf_max - cdf_min;

                        // 发出第一个CDF读地址
                        cdf_ram_ena_r <= 1'b1;
                        cdf_ram_wea_r <= 1'b0;
                        cdf_ram_addra_r <= 8'd0;

                        // 初始化流水线
                        norm_stage1_diff <= 16'd0;
                        norm_stage2_mult <= 32'd0;
                        norm_stage1_addr <= 8'd0;
                        norm_stage2_addr <= 8'd0;

                        cdf_wr_tile_idx <= tile_cnt;
                        cdf_wr_en <= 1'b0;
                        bin_cnt <= 9'd1;
                    end
                    // 周期1-256: 持续读取CDF数据，减法和乘法流水线处理
                    else if (bin_cnt <= 9'd256) begin
                        // 继续发出CDF读地址（周期1-255发出地址1-255）
                        if (bin_cnt < 9'd256) begin
                            cdf_ram_ena_r <= 1'b1;
                            cdf_ram_wea_r <= 1'b0;
                            cdf_ram_addra_r <= bin_cnt[7:0];
                        end
                        else begin
                            // 周期256：停止读取
                            cdf_ram_ena_r <= 1'b0;
                            cdf_ram_wea_r <= 1'b0;
                        end

                        // === 流水线阶段1：减法（处理上一周期读取的数据）===
                        norm_stage1_diff <= cdf_ram_douta - cdf_min;
                        norm_stage1_addr <= bin_cnt[7:0] - 1;

                        // === 流水线阶段2：乘法 ===
                        norm_stage2_mult <= norm_stage1_diff * 32'd255;
                        norm_stage2_addr <= norm_stage1_addr;

                        // 注意：div_start由组合逻辑控制，在bin_cnt >= 2 && bin_cnt <= 257时自动启动

                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    // 周期257: 最后一个乘法结果送入除法器
                    else if (bin_cnt == 9'd257) begin
                        cdf_ram_ena_r <= 1'b0;
                        cdf_ram_wea_r <= 1'b0;

                        // 最后一个乘法结果（bin 255）
                        norm_stage2_mult <= norm_stage1_diff * 32'd255;
                        norm_stage2_addr <= norm_stage1_addr;

                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    // 周期258-290: 等待除法器流水线排空（33周期延迟）
                    else if (bin_cnt <= 9'd290) begin
                        cdf_ram_ena_r <= 1'b0;
                        cdf_ram_wea_r <= 1'b0;

                        bin_cnt <= bin_cnt + 9'd1;
                    end
                    else begin
                        // 完成，准备退出
                        cdf_wr_en <= 1'b0;
                        bin_cnt <= 9'd0;
                    end

                    // === 除法器输出处理（独立于bin_cnt阶段）===
                    // 使用div_done信号控制写入，地址使用延迟移位寄存器
                    if (div_done) begin
                        cdf_wr_tile_idx <= tile_cnt;
                        cdf_wr_bin_addr <= addr_delayed;
                        cdf_wr_en <= 1'b1;
                        cdf_wr_data <= norm_saturated;
                    end
                    else if (bin_cnt > 9'd0) begin
                        // 非div_done周期，关闭写使能（除了初始化周期）
                        cdf_wr_en <= 1'b0;
                    end
                end

                // ============================================================
                // NEXT_TILE: 移动到下一个tile
                // ============================================================
                NEXT_TILE: begin
                    cdf_wr_en <= 1'b0;
                    cdf_wr_bin_addr <= 8'd0;
                    bin_cnt <= 9'd0;  // 重置bin计数器，为下一个tile准备

                    // 禁用内部RAM
                    hist_buf_ena_r <= 1'b0;
                    hist_buf_wea_r <= 1'b0;
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    if (tile_cnt < TILE_NUM - 1) begin
                        tile_cnt <= tile_cnt + 1'b1;
                        // 预先设置下一个tile的RAM信号
                        hist_rd_tile_idx <= tile_cnt + 1'b1;
                        hist_rd_bin_addr <= 8'd0;
                        cdf_wr_tile_idx <= tile_cnt + 1'b1;
                    end
                    else begin
                        // 保持信号稳定
                        hist_rd_tile_idx <= tile_cnt;
                        hist_rd_bin_addr <= 8'd0;
                        cdf_wr_tile_idx <= tile_cnt;
                    end
                end

                // ============================================================
                // DONE: 所有tile处理完成
                // ============================================================
                DONE: begin
                    processing <= 1'b0;
                    cdf_done <= 1'b1;  // 单周期脉冲
                    cdf_wr_en <= 1'b0;

                    // 禁用内部RAM
                    hist_buf_ena_r <= 1'b0;
                    hist_buf_wea_r <= 1'b0;
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    // 保持所有外部RAM信号稳定
                    // 保持所有外部RAM信号稳定
                    // Parameterization fixed
                    hist_rd_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    hist_rd_bin_addr <= 8'd0;
                    cdf_wr_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    cdf_wr_bin_addr <= 8'd0;
                end

                // ============================================================
                // DONE_PULSE: 完成脉冲状态，重置cdf_done信号
                // ============================================================
                DONE_PULSE: begin
                    cdf_done <= 1'b0;  // 重置cdf_done信号
                    cdf_wr_en <= 1'b0;

                    // 禁用内部RAM
                    hist_buf_ena_r <= 1'b0;
                    hist_buf_wea_r <= 1'b0;
                    hist_buf_enb_r <= 1'b0;
                    hist_buf_web_r <= 1'b0;
                    cdf_ram_ena_r <= 1'b0;
                    cdf_ram_wea_r <= 1'b0;
                    cdf_ram_enb_r <= 1'b0;
                    cdf_ram_web_r <= 1'b0;

                    // 保持所有外部RAM信号稳定
                    hist_rd_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    hist_rd_bin_addr <= 8'd0;
                    cdf_wr_tile_idx <= {TILE_IDX_WIDTH{1'b0}};
                    cdf_wr_bin_addr <= 8'd0;
                end

            endcase
        end
    end

endmodule



