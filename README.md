# VPSGuard v0.3.5

VPSGuard 是面向 Ubuntu LTS 新 VPS 的 Bash 初始化与 SSH 安全加固工具。它创建或复用一个由用户明确指定的管理员账户，配置 SSH 公钥、sudo、UFW、fail2ban，并在内核支持时启用 Linux 原生 BBR。

VPSGuard 不安装第三方内核，不自动重启服务器，也不会在卸载时无条件关闭整套防火墙或 fail2ban。

## 主要功能

- 安装时必须手动填写管理员用户名，不存在隐藏默认用户名
- 复用已有普通用户时保留密码、home、现有公钥和用户文件
- 默认使用发行版标准 `sudo` 组和用户密码提供完整管理员权限
- 可显式选择高风险的完整免密码 sudo，并通过独立受管 sudoers 文件实现
- 在 SSH 加固前验证公钥、sudo 策略和所选模式的真实行为
- 使用 `/etc/ssh/sshd_config.d/00-vpsguard.conf` 管理独立 SSH 配置
- 在主配置首行加入可识别、可卸载的精确 Include，避免云镜像的前置 SSH 指令抢先生效
- 在 `ssh.socket` 模式下管理独立 systemd socket drop-in，使 systemd 实际监听目标端口
- 使用 `sshd -t` 和 `sshd -T` 验证语法及最终生效值
- 支持 `ssh.socket`、`ssh.service`、`sshd.service` 和传统 service 模式
- 精确验证 SSH 监听端口及 UFW TCP 规则
- 更换端口时保留旧监听和旧规则，直到第二终端登录被明确确认
- 显式安装并验证 fail2ban systemd backend 依赖，兼容禁用推荐包的精简云镜像
- 默认尝试启用发行版内核自带的 `fq + bbr`
- 每次重跑检查真实状态并收敛，不再只根据 phase 标记跳过
- 卸载只处理可识别的 VPSGuard 文件和记录过的规则

## Ubuntu 状态

| Ubuntu | 当前状态 | 说明 |
| --- | --- | --- |
| 22.04 LTS | 静态与 mock 测试目标 | 尚未在本次升级中进行真实 VPS 安装/卸载验证 |
| 24.04 LTS | 静态与 mock 测试目标 | 包含 `ssh.socket` 路径测试；真实远程切换仍待临时 VPS 验证 |
| 26.04 LTS | Experimental / 待验证 | 官方已发布，但当前没有 GitHub-hosted 26.04 runner，也未做真实 VPS 验证 |

“静态与 mock 测试目标”不等于生产环境验证。首次使用 v0.3.5 时，建议选择带云控制台的临时 VPS。

## 运行前准备 SSH 公钥

运行前，root 的 `/root/.ssh/authorized_keys` 必须包含至少一个可用公钥。不要把私钥上传到 VPS。

macOS、Linux 或 Windows OpenSSH 可以生成 Ed25519 密钥：

```bash
ssh-keygen -t ed25519 -C "vpsguard"
```

查看公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

将 `.pub` 公钥内容添加到 VPS：

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
nano /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

先确认 root 公钥登录可用，再运行 VPSGuard。

## 交互式安装

以 root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hcloudlab/vpsguard/main/install.sh)
```

或：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hcloudlab/vpsguard/main/install.sh)
```

首次安装会提示：

```text
请输入要创建的管理员用户名：
```

直接回车不会采用默认值。用户名必须：

- 使用小写字母或下划线开头
- 后续只包含小写字母、数字、下划线或连字符
- 总长度不超过 32 个字符
- 不能是 `root` 或已知系统账户

如果用户已存在，脚本会显示现状并要求确认；不会删除用户、重置密码或覆盖现有公钥，而是只合并缺失的公钥和配置。

随后会选择 sudo 模式：

```text
请选择管理员 sudo 模式：
1. 密码 sudo（推荐）
2. 免密码 sudo（高风险）
```

默认选择 `1`。密码模式会要求为该账户设置一个强密码，并在修改 SSH 前实际输入一次该密码验证 sudo。免密码模式必须阅读风险提示并精确输入 `I UNDERSTAND`，否则返回选择菜单。

无论选择哪种 sudo 模式，SSH 都保持公钥登录：`PasswordAuthentication no`、`PermitRootLogin no`、`PubkeyAuthentication yes`。

## sudo 权限模型

两种模式都会把管理用户加入 Ubuntu 的 `sudo` 组。

### 密码 sudo（默认、推荐）

- 通过 `passwd` 在可信终端设置 Linux 用户密码；
- `passwd -S` 必须显示 `P`；
- 不保留 VPSGuard 的 `NOPASSWD: ALL` 文件；
- `sudo -n true` 必须失败；
- SSH 加固前必须实际输入用户密码完成 `sudo -v` 验证。

### 免密码 sudo（高风险可选项）

VPSGuard 创建：

```text
/etc/sudoers.d/vpsguard-<username>
```

权限为 `root:root 440`，策略行为是：

```text
<username> ALL=(ALL:ALL) NOPASSWD: ALL
```

文件使用原子写入并通过 `visudo -cf` 校验；`sudo -n true` 和 `sudo -n -i true` 都必须成功。免密码 sudo 不等于空 Linux 密码：VPSGuard 不会删除密码，也不会主动创建空密码。新账户可以保持 locked 或 unset password；已有密码也会原样保留。

此模式风险很高：任何获得该用户 SSH 私钥的人都可以立即取得 root 权限。SSH 密码登录仍始终关闭，但这不能缓解私钥泄露导致的直接 root 权限泄露。

## 参数化安装

先下载脚本，再通过经过校验的环境变量运行：

```bash
curl -fsSLo /tmp/vpsguard-install.sh \
  https://raw.githubusercontent.com/hcloudlab/vpsguard/main/install.sh
sudo -E env NEW_USER=myadmin bash /tmp/vpsguard-install.sh
```

指定目标 SSH 端口：

```bash
sudo -E env NEW_USER=myadmin SSH_PORT=2222 bash /tmp/vpsguard-install.sh
```

`NEW_USER` 和 `SSH_PORT` 可以通过参数提供。首次安装没有 TTY 时使用安全默认值 `password`；已配置的非交互重跑保持当前模式。密码设置及首次认证仍必须通过可信终端完成：

- 不会创建一个无密码的新管理员；
- 新用户应先由管理员通过控制台创建、加入 `sudo` 组并设置密码；
- 即使现有用户已有密码，首次 VPSGuard 安装仍要求终端完成实际 sudo 密码认证。

这项门禁不能通过环境变量传入密码绕过，避免密码进入进程列表、Shell 历史或日志。

## 重跑与更换管理用户

统一配置保存在：

```text
/etc/vpsguard/config.env
```

配置文件由 root 拥有，权限为 `600`。`install.sh`、`status.sh` 和 `uninstall.sh` 都读取这一个来源，但不会直接 `source` 未验证数据。

交互式重跑会提供：

```text
1. 继续使用
2. 更换管理用户
3. 取消
```

更换管理用户不会删除旧用户或旧用户数据。新用户必须完成公钥和 sudo 验证后，SSH 加固才会继续。

重跑还会显示当前 sudo 模式并提供：

```text
1. 保持当前模式
2. 切换为密码 sudo
3. 切换为免密码 sudo
4. 取消
```

`passwordless` 切换到 `password` 时，VPSGuard 会先设置或确认有效密码和标准 sudo 策略，再事务性移除受管 NOPASSWD 文件、实际验证密码 sudo，并确认 `sudo -n true` 失败；失败会恢复原 sudoers 文件。反向切换会先创建和验证受管文件，不删除已有用户密码。未知 sudoers 文件不会被修改。

## SSH 端口切换安全门禁

当目标端口与旧端口不同，VPSGuard 会：

1. 记录旧端口；
2. 精确放行新、旧两个 UFW 端口；
3. 让 SSH 临时同时监听新旧端口；
4. 使用 `sshd -t`、`sshd -T` 和 `ss -ltnp` 验证；
5. 输出第二终端测试命令；
6. 只有输入大写 `YES` 后才结束旧监听；
7. 只删除由 VPSGuard 自己添加并记录的旧 UFW 规则。

第二终端测试示例：

```bash
ssh -p 2222 myadmin@SERVER_IP
sudo -i
```

密码模式下，`sudo -i` 应提示输入 `myadmin` 的用户密码，`sudo -n true` 应失败。免密码模式下，`sudo -n true` 和 `sudo -n -i true` 应成功。

如果没有输入 `YES`，安装状态会成为：

```text
pending-port-finalization
```

旧端口会继续保留。这不是安装失败；确认外部登录后重新运行 VPSGuard 即可完成第二阶段。不要提前关闭当前 SSH 会话。

## BBR

VPSGuard 默认尝试启用 Linux 原生 BBR：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

管理文件：

```text
/etc/sysctl.d/99-vpsguard-bbr.conf
/etc/modules-load.d/vpsguard-bbr.conf  # 仅在 tcp_bbr 作为已加载模块时需要
```

BBR 状态分为：

- `enabled`
- `already-enabled`
- `unsupported`
- `failed`

OpenVZ、容器、受限 VPS 或不支持 BBR 的发行版内核可能显示 `unsupported`。这不会触发第三方内核安装，也不会阻止核心 SSH 安装。

检查真实状态：

```bash
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

BBR 不保证降低物理延迟、消除丢包或让所有线路提速。

## 状态检查

```bash
sudo bash status.sh
```

状态脚本会显示：

- VPSGuard 版本、配置和安装状态
- 管理用户、home、shell、公钥权限状态
- `Sudo mode`、`Password state`、`Sudo group membership`
- `Managed sudoers file`、`visudo validation`、`Passwordless sudo effective`
- SSH 期望端口、有效端口、实际监听和 systemd unit 状态
- root/password/public-key 登录最终有效值
- UFW 新旧端口规则
- fail2ban 服务和 VPSGuard jail
- BBR 支持、可用算法、当前算法、qdisc 和持久化文件

它不会输出完整公钥、密码、Token 或私钥。

## 安装前状态与管理文件

VPSGuard 首次修改系统前会记录：

```text
/etc/vpsguard/state.env
/etc/vpsguard/managed-rules
```

独立管理文件包括：

```text
/etc/ssh/sshd_config.d/00-vpsguard.conf
/etc/systemd/system/ssh.socket.d/00-vpsguard.conf  # 仅 ssh.socket 模式
/etc/fail2ban/jail.d/vpsguard-sshd.local
/etc/sudoers.d/vpsguard-<username>               # 仅免密码 sudo 模式
/etc/sysctl.d/99-vpsguard-bbr.conf
/etc/modules-load.d/vpsguard-bbr.conf
```

VPSGuard 不删除未知 SSH 片段、未知 systemd socket override、未知 fail2ban jail 或其他软件的 BBR 配置。主 `sshd_config` 中只维护带明确起止标记的首行 Include 区块。

## 安全卸载

```bash
sudo bash uninstall.sh
```

必须输入：

```text
UNINSTALL
```

卸载行为：

- 不删除管理员用户、home、authorized_keys 或用户文件
- 不执行全局 `ufw disable` 或 `ufw reset`
- 不停止或禁用整套 fail2ban
- 只删除可识别的 VPSGuard 管理文件
- 密码模式不额外处理 sudoers
- 免密码模式只有在有效用户密码、sudo 组标准权限和删除后的行为检查都证明安全时，才删除带 VPSGuard 管理标记的 sudoers 文件
- 无法证明安全时保留免密码 sudoers 文件并报告 partial uninstall；未知 sudoers 文件始终保留
- 只考虑删除记录过的 UFW 规则，并始终保留当前 SSH 端口规则
- SSH 端口已改变或仍待确认时，保留 SSH 片段和状态，避免远程失联
- 删除 BBR 持久化文件时不强制切换拥塞算法、不重启 VPS

安全条件不足时会返回部分卸载，并保留必要状态供人工处理。

## 本地开发验证

测试只使用临时目录、纯函数和命令 stub，不操作真实 `/etc`、SSH、UFW、systemd、用户或 sysctl：

```bash
bash -n install.sh
bash -n status.sh
bash -n uninstall.sh
shellcheck -x install.sh status.sh uninstall.sh tests/*.sh
bash tests/run.sh
```

GitHub Actions 在 Ubuntu 22.04 和 24.04 runner 上执行同样的静态与隔离测试，不进行真实远程 SSH 联调。

## 版本与许可

- 当前版本：`0.3.5`
- 更新记录：[CHANGELOG.md](CHANGELOG.md)
- 许可：[MIT](LICENSE)
- 仓库：[github.com/hcloudlab/vpsguard](https://github.com/hcloudlab/vpsguard)
