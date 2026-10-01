"""Show a clickable notice that temporarily pins the launching terminal."""

import argparse
import ctypes
import os
import subprocess
import sys
import time
import tkinter as tk
from ctypes import wintypes


user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

HWND_TOPMOST = -1
HWND_NOTOPMOST = -2
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_SHOWWINDOW = 0x0040
SW_RESTORE = 9
SPI_GETWORKAREA = 0x0030


class ProcessEntry32(ctypes.Structure):
    _fields_ = [
        ("dwSize", wintypes.DWORD),
        ("cntUsage", wintypes.DWORD),
        ("th32ProcessID", wintypes.DWORD),
        ("th32DefaultHeapID", ctypes.POINTER(ctypes.c_ulong)),
        ("th32ModuleID", wintypes.DWORD),
        ("cntThreads", wintypes.DWORD),
        ("th32ParentProcessID", wintypes.DWORD),
        ("pcPriClassBase", ctypes.c_long),
        ("dwFlags", wintypes.DWORD),
        ("szExeFile", wintypes.WCHAR * 260),
    ]


def process_ancestors(process_id: int) -> set[int]:
    snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
    if snapshot == ctypes.c_void_p(-1).value:
        return {process_id}

    parent_by_id: dict[int, int] = {}
    entry = ProcessEntry32()
    entry.dwSize = ctypes.sizeof(entry)
    try:
        if kernel32.Process32FirstW(snapshot, ctypes.byref(entry)):
            while True:
                parent_by_id[entry.th32ProcessID] = entry.th32ParentProcessID
                if not kernel32.Process32NextW(snapshot, ctypes.byref(entry)):
                    break
    finally:
        kernel32.CloseHandle(snapshot)

    ancestors = {process_id}
    current = process_id
    while current in parent_by_id and parent_by_id[current] not in ancestors:
        current = parent_by_id[current]
        ancestors.add(current)
    return ancestors


def find_terminal_window() -> int | None:
    foreground_window = user32.GetForegroundWindow()
    if foreground_window and user32.IsWindowVisible(foreground_window):
        title_length = user32.GetWindowTextLengthW(foreground_window)
        title = ctypes.create_unicode_buffer(title_length + 1)
        user32.GetWindowTextW(foreground_window, title, title_length + 1)
        if title.value:
            return foreground_window

    console_window = kernel32.GetConsoleWindow()
    if console_window and user32.IsWindowVisible(console_window):
        return console_window

    process_ids = process_ancestors(os.getpid())
    candidates: list[tuple[int, int]] = []

    enum_proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def collect_window(hwnd: int, _lparam: int) -> bool:
        process_id = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
        if process_id.value in process_ids and user32.IsWindowVisible(hwnd):
            title_length = user32.GetWindowTextLengthW(hwnd)
            title = ctypes.create_unicode_buffer(title_length + 1)
            user32.GetWindowTextW(hwnd, title, title_length + 1)
            class_name = ctypes.create_unicode_buffer(256)
            user32.GetClassNameW(hwnd, class_name, 256)
            score = 0
            if class_name.value == "Chrome_WidgetWin_1":
                score += 10
            if "Visual Studio Code" in title.value:
                score += 20
            if title.value:
                score += 1
            candidates.append((score, hwnd))
        return True

    user32.EnumWindows(enum_proc(collect_window), 0)
    if candidates:
        return max(candidates)[1]

    console_title = ctypes.create_unicode_buffer(512)
    kernel32.GetConsoleTitleW(console_title, len(console_title))
    terminal_candidates: list[tuple[int, int]] = []

    def collect_terminal_window(hwnd: int, _lparam: int) -> bool:
        if not user32.IsWindowVisible(hwnd):
            return True
        class_name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, class_name, 256)
        if class_name.value != "CASCADIA_HOSTING_WINDOW_CLASS":
            return True

        title_length = user32.GetWindowTextLengthW(hwnd)
        title = ctypes.create_unicode_buffer(title_length + 1)
        user32.GetWindowTextW(hwnd, title, title_length + 1)
        score = 1
        if console_title.value and console_title.value in title.value:
            score += 10
        terminal_candidates.append((score, hwnd))
        return True

    user32.EnumWindows(enum_proc(collect_terminal_window), 0)
    return max(terminal_candidates)[1] if terminal_candidates else None


def set_topmost(hwnd: int, enabled: bool) -> bool:
    if enabled:
        user32.ShowWindow(wintypes.HWND(hwnd), SW_RESTORE)

    changed = user32.SetWindowPos(
        wintypes.HWND(hwnd),
        wintypes.HWND(HWND_TOPMOST if enabled else HWND_NOTOPMOST),
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
    )
    if not enabled or not changed:
        return bool(changed)

    user32.BringWindowToTop(wintypes.HWND(hwnd))
    user32.AllowSetForegroundWindow(wintypes.DWORD(-1))
    activated = user32.SetForegroundWindow(wintypes.HWND(hwnd))
    return bool(activated)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Show a notice that temporarily pins the launching terminal"
    )
    parser.add_argument(
        "--message",
        default="点击此提示，将当前终端置顶 {seconds} 秒",
        help="提示框正文；可使用 {seconds} 插入置顶秒数",
    )
    parser.add_argument(
        "-s",
        "--seconds",
        type=int,
        default=2,
        help="How long the terminal stays on top (default: 2 seconds)",
    )
    parser.add_argument("--release-hwnd", type=int, help=argparse.SUPPRESS)
    return parser.parse_args()


def start_release_worker(hwnd: int, seconds: int) -> None:
    command = [
        sys.executable,
        os.path.abspath(__file__),
        "--release-hwnd",
        str(hwnd),
        "--seconds",
        str(seconds),
    ]
    subprocess.Popen(
        command,
        creationflags=0x08000000,
        close_fds=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def release_after_delay(hwnd: int, seconds: int) -> None:
    time.sleep(seconds)
    set_topmost(hwnd, False)


def show_notice(terminal_window: int | None, seconds: int, message_text: str) -> None:
    root = tk.Tk()
    root.withdraw()
    notice = tk.Toplevel(root)
    notice.overrideredirect(True)
    notice.attributes("-topmost", True)
    notice.configure(background="#202124")

    width, height = 360, 112
    work_area = wintypes.RECT()
    user32.SystemParametersInfoW(
        SPI_GETWORKAREA, 0, ctypes.byref(work_area), 0
    )
    x = work_area.right - width - 18
    y = work_area.bottom - height - 18
    notice.geometry(f"{width}x{height}+{x}+{y}")

    frame = tk.Frame(notice, background="#202124", padx=18, pady=14)
    frame.pack(fill="both", expand=True)
    title = tk.Label(
        frame,
        text="CodeAgent任务执行结束提醒",
        foreground="#ffffff",
        background="#202124",
        font=("Microsoft YaHei UI", 12, "bold"),
        anchor="w",
    )
    title.pack(fill="x")
    try:
        notice_text = message_text.format(seconds=seconds)
    except (KeyError, IndexError, ValueError):
        # 消息里含有 { }（例如粘贴的代码）时退化为原样显示，仅替换 {seconds}
        notice_text = message_text.replace("{seconds}", str(seconds))
    message = tk.Label(
        frame,
        text=notice_text,
        foreground="#d7d9dc",
        background="#202124",
        font=("Microsoft YaHei UI", 10),
        anchor="w",
    )
    message.pack(fill="x", pady=(8, 0))

    clicked = False

    def close_notice() -> None:
        if notice.winfo_exists():
            notice.destroy()

    def exit_notice() -> None:
        root.destroy()

    def pin_terminal(_event: tk.Event | None = None) -> None:
        nonlocal clicked
        if clicked:
            return
        clicked = True
        if terminal_window:
            if set_topmost(terminal_window, True):
                start_release_worker(terminal_window, seconds)
            else:
                message.configure(text="VS Code 置顶失败，请重试")
                root.after(1500, exit_notice)
                return
        else:
            message.configure(text="未找到 VS Code 窗口")
            root.after(1500, exit_notice)
            return
        root.after(100, exit_notice)

    for widget in (notice, frame, title, message):
        widget.bind("<Button-1>", pin_terminal)
        widget.configure(cursor="hand2")

    root.after(15000, exit_notice)
    root.mainloop()


def main() -> None:
    args = parse_args()
    if os.name != "nt":
        raise SystemExit("此脚本仅支持 Windows。")
    if args.seconds <= 0:
        raise SystemExit("--seconds 必须大于 0。")
    if args.release_hwnd:
        release_after_delay(args.release_hwnd, args.seconds)
        return
    show_notice(find_terminal_window(), args.seconds, args.message)


if __name__ == "__main__":
    main()
