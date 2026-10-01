# 终端临时置顶提示

`terminal_pin_notice.py` 是一个 Windows 小工具。运行后，它会在屏幕右下角显示一个可点击的提示框；点击提示框后，启动脚本的终端窗口会被临时置顶，指定时间结束后自动恢复。

## 环境要求

- Windows 10 或更高版本
- Python 3.10 或更高版本
- Python 安装时需要包含 Tcl/Tk（用于显示提示框）

终端置顶工具只使用 Python 标准库，不需要 `pywin32`。项目中其他脚本使用的第三方包已整理到 `requirements.txt`。

## 使用方法

在目标终端中进入脚本所在目录，然后运行：

```powershell
python terminal_pin_notice.py
```

程序启动后会显示右下角提示框。点击提示框，当前终端窗口会置顶；不点击时，提示框约 15 秒后自动关闭。

### 指定置顶时间

使用 `--seconds` 或 `-s` 指定置顶时长，单位为秒：

```powershell
python terminal_pin_notice.py --seconds 60
python terminal_pin_notice.py -s 120
```

当前代码默认置顶时间为 `2` 秒。建议在实际使用时显式传入需要的秒数，例如 `--seconds 60`。

查看命令帮助：

```powershell
python terminal_pin_notice.py --help
```

## 工作方式

1. 脚本查找启动它的前台窗口、控制台窗口或关联的 Windows Terminal / VS Code 窗口。
2. 在右下角创建提示框。
3. 用户点击提示框后，将找到的终端窗口设置为置顶并激活它。
4. 脚本启动一个后台释放进程，在指定时间后取消置顶。

## 注意事项

- 必须从希望置顶的终端中启动脚本。直接双击运行时，可能无法准确找到目标终端。
- 仅支持 Windows；在 macOS 或 Linux 上运行会直接退出。
- 如果提示“未找到 VS Code 窗口”或置顶失败，请确认目标终端仍然可见，并从该终端重新运行脚本。
- `--seconds` 必须是大于 `0` 的整数。
- 置顶是 Windows 的窗口属性，不会改变终端进程或命令本身。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `terminal_pin_notice.py` | 当前版本的终端置顶提示工具 |
| `backup/terminal_pin_notice.py` | 旧版本备份，仅供参考 |

## 常见启动示例

PowerShell：

```powershell
Set-Location D:\pythonSripts
python .\terminal_pin_notice.py --seconds 60
```

命令提示符（CMD）：

```bat
cd /d D:\pythonSripts
python terminal_pin_notice.py --seconds 60
```

## 配置 Claude Code Stop Hook

项目中的 `install_claude_hook.sh` 可以自动检查 Python 和 Tkinter，并将用户输入提醒功能配置为 Claude Code 的 `Stop` hook。脚本会：

- 将 `terminal_pin_notice.py` 复制到用户目录下的 `.claude` 文件夹；
- 将 `remind_me.ps1` 也复制到 `.claude`，由它读取 Stop 事件中的最后一条用户输入；
- 在 `~/.claude/settings.json` 的 `hooks.Stop` 中追加 PowerShell hook；
- 修改前生成带时间戳的 `settings.json` 备份；
- 重复执行时避免添加相同的 hook；
- 只替换或追加 `hooks.Stop`，不会用格式化后的 JSON 重写其他配置内容。

在 Git Bash、WSL 或其他支持 POSIX Shell 的终端中执行：

```sh
sh install_claude_hook.sh
```

默认会在 Claude 停止时将终端置顶 `60` 秒。可以通过环境变量修改：

```sh
PIN_SECONDS=120 sh install_claude_hook.sh
```

Hook 的调用链为：

```text
Claude Code Stop -> ~/.claude/remind_me.ps1 -> ~/.claude/terminal_pin_notice.py
```

`remind_me.ps1` 会从 Stop 事件提供的 `transcript_path` 中提取最后一条用户输入，显示在右下角提示框中，并保存到 `C:\workspace\last_user_input.txt`。

安装器会自动处理 pip 依赖：

- 如果没有 pip，会先执行 `python -m ensurepip --upgrade`；
- 如果目录中存在 `requirements.txt`，会自动执行 `python -m pip install -r requirements.txt`；
- 也可以通过 `PIP_PACKAGES` 临时指定要安装的包；
- 当前目录的 `requirements.txt` 包含 `firecrawl-py`、`playwright`、`matplotlib` 和 `numpy`。

例如：

```sh
PIP_PACKAGES="requests rich==13.9.4" sh install_claude_hook.sh
```

如果 Tkinter 检查失败，pip 无法解决这个问题；请重新安装 Python，并在安装选项中启用 Tcl/Tk。

`playwright` 安装 Python 包后，还需要安装浏览器运行时：

```sh
python -m playwright install
```

安装器不会修改 `env`，也不会保存 API Token。建议把 `ANTHROPIC_AUTH_TOKEN` 等敏感配置通过 Claude Code 自己的安全配置或环境变量管理，不要直接提交到仓库。