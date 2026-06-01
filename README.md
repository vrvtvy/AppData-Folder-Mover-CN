# AppData 文件夹移动工具（原项目Ideshon/AppData-Folder-Mover，此为汉化版。）

该程序将选定的文件夹从 `%USERPROFILE%\AppData` 移动到指定位置，并在原路径创建 NTFS junction 链接。

## v4 新增功能

### 1. 按大小排序子文件夹

新增了「大小」按钮。

功能：

1. 获取当前选定的源文件夹。
2. 如果未选择源文件夹，则使用 `%LOCALAPPDATA%`。
3. 计算直接子文件夹的大小。
4. 显示一个单独的窗口，按大小降序排列。
5. 双击可选择子文件夹作为源文件夹。

注意：链接文件夹/junction 不会展开，也不会计入目标的实际大小。这是特意设计的，以便已移动的文件夹不会显示为普通本地文件夹。

### 2. 检查选定文件夹内已移动的文件夹

程序现在会检查选定文件夹内的嵌套 `junction`/`symlink`/reparse point 文件夹。

问题示例：

```text
已选择：
C:\Users\User\AppData\Local\Yandex

但内部已存在移动的文件夹：
C:\Users\User\AppData\Local\Yandex\YandexBrowser\User Data -> G:\Appdata\Local\Yandex\YandexBrowser\User Data
```

在这种情况下，程序会阻止移动 `Local\Yandex`，因为移动父文件夹可能会破坏嵌套链接。

正确做法：

- 选择更精确的文件夹，该文件夹尚未包含嵌套链接；
- 先手动恢复/取消已移动的嵌套文件夹；
- 不要整体移动父文件夹。

## v3 功能

程序会检查在要移动的文件夹中持有文件的应用程序。

1. 移动前通过 Windows Restart Manager 检查文件夹占用情况。
2. 显示可能妨碍移动的进程列表。
3. 建议自动关闭它们。
4. 首先尝试软关闭窗口。
5. 如果进程仍然持有文件，会单独询问是否强制终止。

「占用」按钮启动手动检查。

## 目标路径逻辑

目标路径根据 `AppData` 之后的完整路径构建。

示例：

```text
源文件夹：
C:\Users\User\AppData\Local\Yandex\YandexBrowser\User Data

选择的基础文件夹：
G:\Appdata

新文件夹：
G:\Appdata\Local\Yandex\YandexBrowser\User Data
```

## 运行步骤

1. 解压压缩包。
2. 运行 `Start-AppData-Folder-Mover.bat`。
3. 在 `AppData` 内选择源文件夹。
4. 点击「基础」并选择另一个磁盘上的基础文件夹。
5. 程序会自动填写 `AppData` 之后的完整路径。
6. 如有需要，点击「大小」查找最大的子文件夹。
7. 如有需要，点击「占用」检查干扰的应用程序。
8. 点击「检查」。
9. 点击「移动」。

## 大文件夹移动的详细输出

对于大文件夹，使用 `robocopy`。

详细输出会显示在：

1. 运行 `.bat` 的控制台中。
2. 文件夹内的文件中：

```text
detailed_logs
```

「日志」按钮打开此文件夹。

## 程序执行步骤

1. 检查源文件夹是否在 `AppData` 内。
2. 检查源文件夹是否为链接。
3. 检查选定文件夹内是否存在已移动的嵌套链接文件夹。
4. 检查持有文件的应用程序。
5. 经用户同意后关闭干扰进程。
6. 将源文件夹重命名为临时文件夹。
7. 通过 `robocopy` 将临时文件夹复制到新位置。
8. 在原路径创建 `junction`：

```text
mklink /J
```

9. 成功创建链接后删除临时源副本。

## 重要提示

- 不要整体移动整个 `AppData`、`Local`、`Roaming` 或 `LocalLow`。
- 移动前最好手动关闭程序/游戏。
- 自动关闭可能导致未保存数据丢失。
- 目标磁盘必须是 NTFS。
- 文件夹使用 `junction`，而非普通快捷方式 `.lnk`。
- `junction` 不支持网络路径。
- 如果选定文件夹内已存在嵌套的已移动文件夹，父文件夹的移动将被阻止。

<img width="1110" height="855" alt="afmcn" src="https://github.com/user-attachments/assets/5e5bd032-9018-4648-8209-3ec696bcc3e5" />
