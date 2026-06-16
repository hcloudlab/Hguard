# VPSGuard

VPSGuard is a one-click Ubuntu LTS VPS initialization and SSH security hardening tool.

It is designed for a brand-new VPS after the first root login.

## What VPSGuard Does

- Checks Ubuntu LTS system compatibility
- Updates system packages
- Installs basic server tools
- Creates a new sudo user: `alex`
- Copies root SSH public keys to the new sudo user
- Tests sudo permission
- Installs and configures UFW firewall
- Allows only the current SSH port by default
- Installs and configures fail2ban
- Disables root SSH login
- Disables SSH password login
- Keeps SSH key login enabled

## Supported System

Ubuntu LTS only.

Recommended:

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

---

# SSH Key Preparation Before Running VPSGuard

> Important: VPSGuard expects the root account to already have at least one SSH public key in `/root/.ssh/authorized_keys` before the script runs.

Before running VPSGuard on a brand-new VPS, make sure SSH key login is ready.

Key rules:

- The Private Key / private key stays on your local computer, phone, or Termius.
- The Public Key / public key is copied to the VPS.
- Never paste or upload your Private Key / private key to the VPS.
- VPSGuard requires `/root/.ssh/authorized_keys` to already exist and contain at least one SSH public key.
- VPSGuard copies root's existing SSH public key to the new sudo user created by the script.
- After installation, log in as the new user with the same private key.

## macOS / Linux Local Terminal

Generate an SSH key if you do not already have one:

```bash
ssh-keygen -t ed25519 -C "vpsguard"
```

Show your public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Copy the public key to the new VPS if `ssh-copy-id` is available:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@YOUR_SERVER_IP
```

If `ssh-copy-id` is not available, log in as root with the initial VPS password:

```bash
ssh root@YOUR_SERVER_IP
```

Then create and edit `/root/.ssh/authorized_keys`:

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
nano /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

One-line append example:

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo 'PASTE_YOUR_PUBLIC_KEY_HERE' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

Replace `PASTE_YOUR_PUBLIC_KEY_HERE` with your real public key, not your private key.

## Termius

1. Open Termius.
2. Go to Keychain.
3. Select or create an SSH Key.
4. Copy the Public Key, not the Private Key.
5. Create a new Host for the VPS.
6. Log in as root using the initial VPS password.
7. Add the Public Key to `/root/.ssh/authorized_keys`.
8. Change the Host authentication method to Key.
9. Select the same Termius private key.
10. Test root key login before running VPSGuard.

---

# 运行 VPSGuard 前的 SSH 密钥准备

> 重要：运行 VPSGuard 之前，root 账户的 `/root/.ssh/authorized_keys` 里必须已经有至少一个 SSH 公钥。

在一台全新的 VPS 上运行 VPSGuard 之前，请先确认 SSH 密钥登录已经准备好。

关键规则：

- Private Key / 私钥保留在你的本地电脑、手机或 Termius 里。
- Public Key / 公钥复制到 VPS。
- 绝对不要把 Private Key / 私钥粘贴或上传到 VPS。
- VPSGuard 运行前要求 `/root/.ssh/authorized_keys` 已经存在，并且里面至少有一个 SSH 公钥。
- VPSGuard 会把 root 账户已有的 SSH 公钥复制给脚本创建的新 sudo 用户。
- 安装完成后，用户应该使用新用户和同一个私钥登录。

## macOS / Linux 本地终端

如果你还没有 SSH Key，可以生成一个：

```bash
ssh-keygen -t ed25519 -C "vpsguard"
```

查看公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

如果本地支持 `ssh-copy-id`，可以直接复制公钥到新 VPS：

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@YOUR_SERVER_IP
```

如果没有 `ssh-copy-id`，先用 VPS 初始 root 密码登录：

```bash
ssh root@YOUR_SERVER_IP
```

然后创建并编辑 `/root/.ssh/authorized_keys`：

```bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
nano /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

也可以用一行命令追加公钥：

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo 'PASTE_YOUR_PUBLIC_KEY_HERE' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
```

请把 `PASTE_YOUR_PUBLIC_KEY_HERE` 替换成你的真实公钥，不是私钥。

## Termius 操作步骤

1. 打开 Termius。
2. 进入 Keychain。
3. 选择已有 SSH Key，或新建一个 SSH Key。
4. 复制 Public Key，不要复制 Private Key。
5. 新建 VPS Host。
6. 先用 VPS 初始 root 密码登录。
7. 把 Public Key 添加到 `/root/.ssh/authorized_keys`。
8. 把 Host 的认证方式改成 Key。
9. 选择对应的 Termius 私钥。
10. 确认 root 可以使用密钥登录后，再运行 VPSGuard。

---

# One-click Deployment

Run the command below as root only after your SSH public key has been added to `/root/.ssh/authorized_keys`.

curl version:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

wget version:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

---

# 一键部署

只有在你已经把 SSH 公钥添加到 `/root/.ssh/authorized_keys` 之后，才使用 root 运行下面的一键部署命令。

curl 版本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

wget 版本：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

---

# After Installation Login

After VPSGuard finishes, do not keep using root login. Log in with the new sudo user:

```bash
ssh alex@YOUR_SERVER_IP -p 22
```

For Termius after installation:

- Host username: `alex`
- Authentication: `Key`
- Selected Key: the same private key whose public key was added before running VPSGuard.
- Do not use root login.
- Do not use password login.

Test sudo after logging in:

```bash
sudo whoami
```

Expected output:

```bash
root
```

---

# 安装后登录

VPSGuard 安装完成后，不要继续使用 root 登录。请使用新 sudo 用户登录：

```bash
ssh alex@YOUR_SERVER_IP -p 22
```

Termius 安装后设置：

- 用户名改成 `alex`
- 认证方式选择 `Key`
- 选择之前添加公钥时对应的同一个私钥
- 不要使用 root 登录
- 不要使用密码登录

登录后测试 sudo：

```bash
sudo whoami
```

预期输出：

```bash
root
```

---

## Custom User

If you want to use another username:

```bash
NEW_USER=deploy bash install.sh
```

## Custom SSH Port

VPSGuard automatically detects the current SSH port.

You can also specify it manually:

```bash
SSH_PORT=22 bash install.sh
```

## Check Status

```bash
bash status.sh
```

## Uninstall

```bash
bash uninstall.sh
```

## Important Warning

Do not close your current root SSH session immediately after running VPSGuard.

Open a new terminal window and test the new sudo user login first:

```bash
ssh alex@YOUR_SERVER_IP -p 22
sudo whoami
```

Only close the root session after confirming that the new user login works.

## License

MIT
