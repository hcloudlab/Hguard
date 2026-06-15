# VPSGuard

VPSGuard is a one-click Ubuntu LTS VPS initialization and SSH security hardening tool.

It is designed for a new VPS after the first root login.

## What VPSGuard Does

- Check Ubuntu LTS system
- Update system packages
- Install basic tools
- Create a new sudo user: `alex`
- Copy root SSH public keys to the new user
- Test sudo permission
- Install and configure UFW firewall
- Allow only the current SSH port by default
- Install and configure fail2ban
- Disable root SSH login
- Disable SSH password login
- Keep SSH key login enabled
- Print final configuration with colored output

## Supported System

Ubuntu LTS only.

Recommended:

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

## Important Before Running

Before running VPSGuard, make sure `/root/.ssh/authorized_keys` exists and contains your SSH public key.

Check:

```bash
ls -la /root/.ssh
cat /root/.ssh/authorized_keys
```

If `authorized_keys` is empty, add your SSH public key first.

## 安装前准备：确认 SSH 公钥和私钥

在本地电脑查看是否已有 SSH 公钥：

```bash
ls ~/.ssh
```

如果没有 SSH 密钥，生成新的 ed25519 密钥：

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

查看公钥内容：

```bash
cat ~/.ssh/id_ed25519.pub
```

需要把 `.pub` 公钥内容添加到 VPS 的 `~/.ssh/authorized_keys`。

VPSGuard 安装完成后，默认使用新用户登录：

```bash
ssh alex@你的服务器IP
```

如果使用指定私钥路径：

```bash
ssh -i ~/.ssh/id_ed25519 alex@你的服务器IP
```

请确认新用户可以使用 SSH 私钥登录后，再关闭当前 root 会话，避免把自己锁在服务器外面。

## Quick Start

Run as root:

```bash
apt update && apt install -y curl && bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

If your system requires sudo:

```bash
sudo apt update && sudo apt install -y curl
bash <(curl -fsSL https://raw.githubusercontent.com/hexa46656-creator/vpsguard/main/install.sh)
```

## Default User

The default new user is:

```bash
alex
```

After installation, test login from your local computer:

```bash
ssh alex@YOUR_SERVER_IP -p 22
```

Then test sudo:

```bash
sudo whoami
```

Expected output:

```bash
root
```

## Default Open Ports

VPSGuard only allows the current SSH port by default.

Usually this means:

```bash
22/tcp
```

It does not open `80`, `443`, `8443`, or other service ports automatically.

If you deploy a website later:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

If you deploy a custom service later:

```bash
sudo ufw allow YOUR_PORT/tcp
```

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

Open a new terminal window and test:

```bash
ssh alex@YOUR_SERVER_IP -p 22
sudo whoami
```

Only close the root session after confirming that the new user login works.

## License

MIT
