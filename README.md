# PowerTuner

Windows 电源策略管理器 —— 把 `powercfg` 里被系统界面藏起来的电源策略，做成一个能点的图形界面。

Windows 的「设置 → 电源」只暴露十几项，而系统里实际登记着 **190 多条**电源策略。PowerTuner 直接解析 `powercfg /query` 的全量输出动态生成界面，系统里存在什么策略，它就能显示和修改什么，不需要针对每条策略硬编码。

## 当前状态

> **开发中**：正在从 PowerShell 原型迁移到 C# + WPF。
> 数据层（`powercfg` 调用、全量解析、写入、格式化）已完成并通过真实系统验证；
> 界面层目前完成方案切换、分类导航、搜索与卡片渲染，**编辑控件与写入流程正在迁移**。
>
> 功能完整的可用版本在 [`legacy/`](legacy/)（PowerShell + WPF 实现）。

## 技术栈

- **C# + WPF**，目标框架 `net48`（Windows 10/11 自带 .NET Framework 4.8，用户无需安装运行时）
- 构建：`dotnet build`（CI 使用 windows-latest，产物为单文件 exe，约 200 KB）
- 无第三方依赖

## 目标功能

- **双列编辑**：每条策略可分别设置「接通电源」与「使用电池」的值
- **动态建模**：不硬编码策略列表，跟随系统实际输出
- **一键解锁隐藏项**：以管理员身份显示 Windows 默认隐藏的性能 / 散热 / 待机策略（只改可见性，不改数值）
- **快速方案**：常插电工作站、长任务不睡眠、差旅省电、恢复默认节奏，应用前列出逐条改动
- **分类 + 搜索**：11 个分类，按名称 / 别名 / 子组检索
- **方案管理**：切换电源方案、新建副本
- **备份迁移**：导出 / 导入 `.pow` 方案备份
- **诊断工具**：电池健康报告、能源效率诊断
- **安全写入**：改动先进入待应用队列，显式点击才逐条调用 `powercfg /setacvalueindex`

## 构建

需要 [.NET SDK 8](https://dotnet.microsoft.com/download) 或更高版本（SDK 提供编译 XAML 所需的 MSBuild 目标）。

```
dotnet build src/PowerTuner/PowerTuner.csproj -c Release -o dist
```

或双击 `Build.cmd`。

## 目录结构

```
src/PowerTuner/
  PowerTuner.csproj        工程定义（net48 · UseWPF）
  App.xaml(.cs)            应用入口、全局异常记录
  MainWindow.xaml(.cs)     主窗口与视图逻辑
  Theme.xaml               控件样式
  app.manifest             Per-Monitor V2 DPI 感知
  Services/PowerCfg.cs     powercfg 封装：解析 / 写入 / 格式化
  assets/app.ico           应用图标
legacy/                    PowerShell + WPF 的完整实现（可运行）
tools/                     图标生成与校验脚本
.github/workflows/         CI：构建 + tag 时发布 release
```

## 实现说明

### 为什么解析 `powercfg` 而不是调 Windows API

`powercfg /query` 的输出包含每个策略的 GUID、友好名称、取值范围、枚举项与 AC/DC 当前值，信息完整且与系统语言无关（中英文标签都做了匹配）。用它建模，工具就能自动适配不同机器和不同 Windows 版本，不必维护一张策略清单。

### 隐藏策略是怎么被「藏」起来的

Windows 在注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\<子组>\<策略>` 下用 `Attributes` 标记可见性。把它设为 `2`（或执行 `powercfg /attributes <子组> <策略> -ATTRIB_HIDE`）后，策略会重新出现在 `powercfg /query` 中。解锁只影响可见性，不改任何数值。

### 为什么有些策略解锁了也不生效

部分策略由固件或驱动固定，即使可见也不会出现在 `powercfg /query` 中。工具会把这类项目记录到 `unhide.stuck.txt`，避免反复提示。

## 已知限制

- 仅 Windows，依赖 .NET Framework 4.8（Win10 1903+ / Win11 自带）
- exe 未做代码签名，可能出现 SmartScreen 提示；部分开启 Smart App Control 的机器会拦截未签名程序（是否拦截按二进制逐个体判定，与策略严格程度有关）
- 策略能否生效取决于硬件与固件，建议逐项修改、逐项验证

## 许可证

[MIT](LICENSE)
