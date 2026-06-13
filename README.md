### 下载 ZIP

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.zip" -OutFile "$env:USERPROFILE\Downloads\proxy-setup.zip"
Expand-Archive -Path "$env:USERPROFILE\Downloads\proxy-setup.zip" -DestinationPath "$env:USERPROFILE\Downloads\proxy-setup" -Force
cd "$env:USERPROFILE\Downloads\proxy-setup\proxy-setup-master"
.\install_python.bat
```

**Mac / Linux (curl):**

```bash
curl -L -o ~/Downloads/proxy-setup.tar.gz "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.tar.gz"
mkdir -p ~/Downloads/proxy-setup
tar -xzf ~/Downloads/proxy-setup.tar.gz -C ~/Downloads/proxy-setup --strip-components=1
cd ~/Downloads/proxy-setup
bash setup_proxy.sh
```

**Mac / Linux (wget):**

```bash
wget -O ~/Downloads/proxy-setup.tar.gz "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.tar.gz"
mkdir -p ~/Downloads/proxy-setup
tar -xzf ~/Downloads/proxy-setup.tar.gz -C ~/Downloads/proxy-setup --strip-components=1
cd ~/Downloads/proxy-setup
bash setup_proxy.sh
```

---

### 或 Git Clone

```bash
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup
bash setup_proxy.sh
```

---

### 纯 PowerShell（无需 Python，Windows）

```powershell
powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
```

---

### 纯 bash（无需 Python，Mac / Linux）

```bash
bash setup_proxy.sh
```

如果要用 Python 版（先装 Python）：

```bash
bash install_python.sh
```

> `install_python.sh` 自动适配 Homebrew（含中科大/清华国内镜像）、apt、yum、dnf、pacman。安装后自动检测并运行 `setup_proxy.py`。
