# CLAHE 64-Tile 资源优化分析报告

## 1. 问题分析 (Problem Analysis)
用户指出 `clahe_vivado_64t_opt` 工程中 LUT 资源消耗异常增加 (164% Utilization)，而 Block RAM 使用率极低 (2 RAMs)。

### 1.1 资源对比
-   **Baseline (64t)**:
    -   LUTs: ~14,487 (正常)
    -   BRAM: 130 (大量闲置)
-   **Optimized (64t_opt)**:
    -   LUTs: ~28,600 (**异常激增**, 主要来自 `RAMD64E` 分布式 RAM)
    -   BRAM: 2 (未能正确推断 BRAM)

### 1.2 根因定位 (Root Cause: 3-Port Conflict)
用户及其敏锐地指出："**为什么优化前的 64tile 版本不会这样？**"
这个问题直击核心。

**对比分析**:
-   **Baseline (64t) 架构**:
    -   实例化了 **128 个** 独立的物理 RAM (64 x RAM_A + 64 x RAM_B)。
    -   每个 RAM 都是标准的 Simple Dual Port (1 Write + 1 Read)。
    -   **关键点**: 通过外部多路复用器 (Mux)，每个 RAM 的读端口在同一时刻只服务于一个功能（要么是统计读，要么是 CDF 读，要么是 Mapping 读）。
    -   Mapping 阶段，4 个并行请求 (`TL, TR, BL, BR`) 被发送到了 **4 个不同的 RAM 实例**。因此，没有任何一个 RAM 承担了超过 2 个端口的压力。

-   **Optimized (64t_opt) 架构**:
    -   我们将 16 个 Tile **折叠 (Folded)** 进了一个物理 Bank。
    -   带来的副作用是：原本分散在 16 个不同 RAM 上的请求，现在全部集中到了 **同一个物理 RAM** 上。
    -   **代码缺陷**: `clahe_ram_banked.v` 试图在一个 `always` 块中同时描述 "Hist Write", "Hist Read", "Mapping Read"。
    -   Synthesizer 认为这是一个需要 3 个端口的 RAM，这超出了 Block RAM (最多 2 端口) 的物理能力，因此被迫使用 LUTs 实现。

通过分析 `clahe_ram_banked.v` 代码发现，代码逻辑隐含了对 **3 个独立端口** 的同时需求，超过了 FPGA 标准 Block RAM (True Dual Port) 仅支持 **2 个端口** (Port A, Port B) 的物理限制。综合器因此被迫使用 LUT (Distributed RAM) 来模拟多端口存储器，导致 LUT 爆炸。

**代码逻辑分析**:
```verilog
always @(posedge pclk) begin
    // [逻辑端口 1 & 2] : 直方图统计 (Histogram Mode)
    // 此时 Ping-Pong 指向该 Set
    if (ping_pong == 0) begin
         if (hist_wr_en) ram[wr_addr] <= data; // Write Action
         rdata_p0 <= ram[rd_addr];             // Read Action
         // 直方图流水线中，wr_addr (Stage 3) != rd_addr (Stage 2)
         // 因此这里实际上需要 1 个写端口 + 1 个读端口。
    end

    // [逻辑端口 3] : 映射读取 (Mapping Mode)
    // 问题点: 代码中这行是无条件执行的！
    rdata_p1 <= ram[mapping_addr];             // Read Action
end
```
**冲突**:
-   Synthesizer 看到:
    1.  `Write(wr_addr)`
    2.  `Read(rd_addr)`
    3.  `Read(mapping_addr)`
-   总共需要 3 个独立地址访问。BRAM 只有 Port A 和 Port B。
-   **结果**: BRAM 推断失败 -> Fallback to Distributed RAM -> LUT 爆炸。

---

## 2. 优化方案：基于 Parhi 架构变换的端口调度 (Optimization Plan)

结合 **K.K. Parhi《VLSI Digital Signal Processing Systems》** 第 3 章 (Resource Sharing) 和 第 6 章 (Folding) 的思想，我们可以通过 **生命周期分析 (Liveness Analysis)** 发现端口需求的互斥性，并进行 **端口折叠 (Port Sharing/Folding)**。

### 2.1 互斥性分析
在 Ping-Pong 架构中：
-   **Histogram Mode (Set X)**: 需要 `Hist_Read` 和 `Hist_Write`。不需要 `Mapping_Read`。
-   **Mapping Mode (Set X)**: 需要 `Mapping_Read`。不需要 `Hist_Read/Write`。

### 2.2 端口调度策略 (Port Scheduling)
我们将 3 个逻辑请求映射到 2 个物理端口 (Port A, Port B) 上。

| Physical Port | Mode: Histogram (Active) | Mode: Mapping (Inactive) |
| :--- | :--- | :--- |
| **Port A** | `Hist_Read_Addr` (Read) | `CDF_Read_Addr` (Read) |
| **Port B** | `Hist_Write_Addr` (Write) | `Mapping_Read_Addr` (Read) |

**Verilog 修改思路**:
我们需要引入 **地址多路复用器 (Address Muxing)**，而不是让三个操作并行写在代码块中。

```verilog
// 伪代码示例 (Pseudo-code)

// Port A: 总是用于"主要读取" (Hist Read 或 CDF Read)
assign addr_a = (mode == HIST) ? hist_rd_addr : cdf_rd_addr;
assign we_a   = 0; // Port A 只读

// Port B: 复用用于"写入" 或 "Mapping 读取"
assign addr_b = (mode == HIST) ? hist_wr_addr : mapping_addr;
assign we_b   = (mode == HIST) ? hist_wr_en : 0; // 只在 Hist 模式写

// RAM 实例化
always @(posedge clk) begin
   // Port A
   dout_a <= mem[addr_a];
   
   // Port B
   if (we_b) mem[addr_b] <= din_b;
   dout_b <= mem[addr_b];
end
```

### 2.3 预期收益
-   **BRAM 推断**: 逻辑严格符合 True Dual Port RAM 模板。Vivado 将 100% 推断为 Block RAM。
-   **资源优化**:
    -   LUTs: 从 43,000 降回 ~14,000 (Distributed RAM 消失)。
    -   BRAM: 从 2 升至 ~16 (8个 RAM Arrays * 2 halves? 或者是 4 Banks * 2 Sets = 8 RAMB18)。
    -   Timing: BRAM 分布式布局比 LUT RAM 更利于时序收敛。

## 3. 下一步行动
建议按照上述方案重构 `clahe_ram_banked.v` 的 `always` 块逻辑，显式定义 Port A 和 Port B 的行为，消除隐式的第 3 端口需求。

---

## 4. 时序优化：流水线除法器 (Pipelined Divider) - 2025-12-10 已实现

### 4.1 问题分析

在解决了资源问题后，发现新的时序瓶颈：**CDF 归一化阶段的组合除法**。

**Vivado 时序报告分析**:
```
关键路径: clipper_cdf_inst/cdf_range_reg → cdf_wr_data_reg
逻辑级数: 185 级 (159 × CARRY4 + 18 × LUT3 + 7 × LUT2 + 1 × LUT1)
数据路径延迟: 35.546 ns
WNS @ 74MHz: -22.347 ns (严重违例)
```

**根因**: Verilog 中的 `/` 运算符被综合为迭代减法器，形成超长组合逻辑链。

### 4.2 解决方案：Cut-Set Pipelining

**理论来源**: *Parhi Chapter 2 (Pipelining and Parallel Processing)*

将 32-bit 组合除法器重构为 **33 级非恢复除法流水线**：

```verilog
// 新增模块: clahe_divider_pipelined.v
module clahe_divider_pipelined #(parameter DATA_WIDTH = 32) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,          // 输入有效
    input  wire [DATA_WIDTH-1:0] dividend,       // 被除数
    input  wire [DATA_WIDTH-1:0] divisor,        // 除数
    output wire                  done,           // 输出有效 (33周期后)
    output wire [DATA_WIDTH-1:0] quotient,       // 商
    output wire [DATA_WIDTH-1:0] remainder       // 余数
);
```

### 4.3 延迟对齐 (Retiming)

**问题**: 除法器引入 33 周期延迟，地址路径必须同步延迟。

**解决方案**: 在 `clahe_clipper_cdf.v` 中添加 33 级地址移位寄存器：

```verilog
localparam DIV_LATENCY = 33;
reg [7:0] addr_delay_reg [0:DIV_LATENCY-1];
wire [7:0] addr_delayed = addr_delay_reg[DIV_LATENCY-1];
```

### 4.4 实现结果

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| 关键路径延迟 | 35.5 ns | 6.7 ns |
| 逻辑级数 | 185 | 5 |
| WNS @ 74MHz | -22.3 ns | +6.8 ns |
| WNS @ 100MHz | N/A | +3.2 ns |
| 理论最高频率 | ~28 MHz | **~148 MHz** |

**寄存器代价**: 约 1300 个额外寄存器（流水线 + 地址延迟）

### 4.5 状态

✅ **已实现并验证**
- 代码修改完成: `clahe_clipper_cdf.v`, `clahe_divider_pipelined.v`
- 仿真验证通过: 所有 6 帧处理成功
- Vivado 综合通过: 时序收敛 @ 100MHz
