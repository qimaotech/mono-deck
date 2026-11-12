# MonoDeck

[English](README.md) | **简体中文**

MonoDeck 是一款 macOS 原生应用，帮助开发者在同一工作区管理多个仓库、组织跨仓库任务，并打造业务专属 AI 工作流。

## 主要功能

- 批量添加和更新仓库，创建、编辑和清理工作树分组。
- 查看工作树的本地更改、独有提交和落后提交，在外部工具中打开分组或成员目录。
- 支持 Agent 通过 `mono-deck` CLI 和 `mono-deck-workflow` SKILL 管理仓库与分组。

## 工作区如何组织

工作区包含共享文件、成员仓库和任务工作树分组。每个分组汇集当前任务所需仓库工作树。

```text
example-workspace/               # 工作区
├── repositories/
│   ├── order-service/           # 成员仓库
│   └── storefront-web/          # 成员仓库
└── worktrees/
    └── feature-checkout/        # 任务工作树分组
        ├── order-service/       # 任务成员工作树
        └── storefront-web/      # 任务成员工作树
```

工作区根目录是工作区仓库的主工作树，用于存放共享的提示词、技能和项目文档。各分组的根目录是该仓库的链接工作树。每个成员仓库在 `repositories/` 下有自己的主工作树，它在各分组中的任务成员工作树则是同一个成员仓库的链接工作树。

![MonoDeck 工作区中的任务工作树分组、本地更改和独有提交](./.github/assets/1-workspace-overview.png)

## 开始使用

MonoDeck 需要搭载 Apple Silicon 芯片且运行 macOS 26.5 或更高版本的 Mac。从 [Releases](https://github.com/qimaotech/mono-deck/releases) 下载 DMG，将 `MonoDeck.app` 拖入“应用程序”。

DMG 内的 `MonoDeck.app` 采用 ad hoc 签名，未经过 Apple 公证。若下载隔离标记阻止 App 打开，确认安装包来源可信后，可运行以下命令再打开 App。

```bash
xattr -dr com.apple.quarantine /Applications/MonoDeck.app
```

1. 启动 MonoDeck，按引导安装 CLI 并选择工作区目录。首次使用可选一个专用的空目录。
2. 通过 URL 添加仓库，或在添加窗口的“导入”菜单中扫描本地仓库。两种方式都使用本机 Git 认证从远端克隆，本地仓库的未提交改动留在原目录。
3. 选择**创建工作树分组**，并选中当前任务所需的仓库。分组名须是符合 Git 分支命名规则的单层目录名，例如 `feature-checkout`。初始分支名默认与分组同名，也可填写 `feature/checkout`。创建分组使用本地 Git 引用，有可用的同名本地分支时会复用。后续新增成员沿用相同的初始分支名和分支选择规则。

   ![创建工作树分组的窗口，已填写分组名和初始分支名，并选中两个仓库](./.github/assets/2-create-worktree-group.png)

4. 选中分组或单个成员，通过工具栏在已安装的 Agent、编辑器、终端或 Git 工具中打开，在外部工具中完成开发、提交和合并。
5. 在 Git Browser 查看本地更改、独有提交和落后提交。对比以本地记录的远端默认分支为基准。

- **更新仓库**是 `repositories` 区域的更新按钮。MonoDeck 从远端获取各仓库本地 `origin/HEAD` 所指向的分支，并尝试在对应的主工作树中快进合并。主工作树须检出对应的本地分支，且没有未提交改动。
- **更新工作树**是 `worktrees` 区域的更新按钮。MonoDeck 使用本地 Git 数据快进已登记的分组根和分组内各工作树的当前分支。各工作树以所属仓库本地的 `origin/HEAD` 为基准。分组根以工作区仓库本地的 `origin/HEAD` 为基准，只有该引用不存在时才使用工作区根目录当前检出的分支。基准不可用、HEAD 分离、有未提交改动、正在执行 Git 操作或当前分支与基准分叉的工作树会被跳过。

取消操作会保留已完成的更新。

![按分组显示已更新和已跳过项目的工作树更新结果](./.github/assets/3-worktree-update-results.png)

重装后，可在引导或设置中选择原工作区。登记缺失时，MonoDeck 会尝试从本地 Git 数据重建登记，保留已识别仓库和工作树的分支及改动。

## CLI 与 Agent

按引导安装 CLI 后，在工作区目录下运行以下命令。示例假设已添加 `order-service` 和 `storefront-web`。

```bash
mono-deck workspace tree --json
mono-deck group create feature-checkout --branch feature/checkout --repo order-service --repo storefront-web
mono-deck group delete feature-checkout --dry-run
```

`--repo` 使用仓库 ID，也就是仓库 URL 末段去掉 `.git` 后缀后的名称。在工作区外运行时，可用 `--workspace` 指定根目录。参数见各子命令的 `--help`，JSON 输出格式见 [CLI 契约](GLOSSARY.md#external-data-and-cli-contract)。

`group edit --repo` 指定完整的目标成员集合，省略的成员会被删除。用 `--dry-run` 预览删除，目标有变化时重新预览。交互终端会请求确认，使用 `--json` 或在非交互环境中执行删除时，需通过 `--yes` 授权本次命令的删除目标。

安装内置工作流技能后，从工作区根目录启动 Agent，可显式调用 `$mono-deck-workflow` 管理仓库和分组。

### 工作区文件与自动提交

MonoDeck 维护以下工作区文件，并按需自动提交到工作区仓库。

- **`.gitignore`** 会按需补充忽略规则。自动提交包含整个文件，可能一并提交你的手动修改。
- **`mono-deck-workflow`** SKILL 会在打开或重新加载工作区时同步，如有本地改动会被丢弃，如果需要自定义流程可另建 `.agents/skills/mono-deck-workflow-addon/SKILL.md`。

## 使用须知

- **分享配置**可在设置中将工作区配置导出为 YAML 文件，再在目标工作区导入。导入会追加缺失的仓库与分组，跳过 ID 和远端 URL 均匹配的仓库以及同名分组。若仓库 ID 匹配而远端 URL 不同，导入会报告冲突。
- **在 `worktrees` 区域删除工作树或分组**会永久移除对应工作树及其当前本地分支。未提交改动随工作树移除，未合并提交可能丢失。删除仓库会先移除该仓库在各分组中的受管工作树及其当前本地分支，再将其本地克隆目录移至废纸篓。已锁定的工作树需先用 Git 解锁。确认前请核对范围和需要保留的内容。

  ![工作树删除预览，显示工作树路径和有未提交改动的状态](./.github/assets/4-delete-member-worktree.png)

- **取消或部分失败**可能保留已完成的效果，请按结果列表核对已完成和待处理的项目。
- 创建任务成员工作树时，起点提交不能包含 **Git 子模块**。

版本变化见[更新日志](CHANGELOG.md)，构建与测试见[开发细则](DEVELOPMENT.md)。
