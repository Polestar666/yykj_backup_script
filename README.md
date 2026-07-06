# RecycleDeleteBackup

`RecycleDeleteBackup` 是一个 Windows PowerShell 工具。

它只在一种情况下备份文件：

当文件或文件夹被删除到 Windows 回收站后，自动复制一份到本地备份目录。

它不做全盘实时同步，也不会在每次保存文件时复制，更适合用来防误删。
## 安装

### Windows 系统直接安装

```powershell
irm https://raw.githubusercontent.com/Polestar666/yykj_backup_script/main/install.ps1 | iex
## 功能特点

- 只监听回收站，不做整盘实时备份
- 仅处理“进入回收站”的删除动作
- 支持文件和文件夹
- 默认监听所有盘
- 默认最大备份大小为 `500MB`
- 自动排除备份目录自身，避免递归套娃
- 支持开机自启动
- 所有功能合并在一个脚本里

## 仓库结构

核心源码文件：

```text
RecycleDeleteBackup.ps1
README.md
.gitignore
```

运行后会自动生成这些运行时目录：

```text
.runtime\
backup\
```

其中：

- `.runtime`：保存配置、状态、会话文件
- `backup`：保存实际备份内容

这些目录已经写进 `.gitignore`，不需要提交到仓库。

## 运行要求

- Windows
- PowerShell 5.1 或更高版本
- 删除动作必须经过 Windows 回收站

## 快速开始

先进入脚本目录：

```powershell
cd D:\background
```

启动监控：

```powershell
.\RecycleDeleteBackup.ps1 start
```

查看状态：

```powershell
.\RecycleDeleteBackup.ps1 status
```

停止监控：

```powershell
.\RecycleDeleteBackup.ps1 stop
```

## 常用命令

### 启动默认监控

监听所有盘，最大备份大小 `500MB`：

```powershell
.\RecycleDeleteBackup.ps1 start
```

### 只监听指定盘

例如只监听 `D` 和 `E`：

```powershell
.\RecycleDeleteBackup.ps1 start -DriveLetter D,E
```

### 自定义备份目录

```powershell
.\RecycleDeleteBackup.ps1 start -BackupRoot "D:\background\backup"
```

### 修改大小限制

例如改成 `300MB`：

```powershell
.\RecycleDeleteBackup.ps1 start -MaxFileSizeMB 300
```

### 设置开机自启动

```powershell
.\RecycleDeleteBackup.ps1 install-autostart
```

这个命令会把当前配置写入：

`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

### 取消开机自启动

```powershell
.\RecycleDeleteBackup.ps1 uninstall-autostart
```

## 备份目录结构

默认备份目录：

```text
.\backup\deleted
```

示例：

```text
backup
+-- deleted
    +-- 2026-07-06
        +-- D_drive
            +-- project
                +-- 153025-report.docx
```

含义：

- `2026-07-06`：删除日期
- `D_drive`：来源盘符
- `project`：原始相对目录
- `153025-report.docx`：删除时间加原始文件名

## 工作原理

1. 脚本启动后，先读取当前回收站内容作为基线。
2. 只有启动之后新进入回收站的项目才会被处理。
3. 如果项目大小小于等于限制值，就复制到备份目录。
4. 每个处理结果都会写入 `backup\deleted\manifest.jsonl`。

## 限制说明

- 只支持“进入回收站”的删除
- `Shift + Delete` 不会触发备份
- 某些软件自己的“永久删除”也可能绕过它
- 超过大小限制的项目会跳过
- 备份目录自身被排除，不会再次触发备份

## 验证是否生效

启动监控后，正常删除一个小文件到回收站。

等待大约 `2-5` 秒后，到这里查看：

```text
D:\background\backup\deleted
```

如果出现按日期分组的目录，并且里面能看到刚删除的文件，说明工具已经正常工作。
