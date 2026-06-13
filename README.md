### 下载 ZIP

PowerShell 执行以下命令下载并解压：

```powershell
Invoke-WebRequest -Uri "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.zip" -OutFile "$env:USERPROFILE\Downloads\proxy-setup.zip"
Expand-Archive -Path "$env:USERPROFILE\Downloads\proxy-setup.zip" -DestinationPath "$env:USERPROFILE\Downloads\proxy-setup" -Force
```

进入目录并运行：

```powershell
cd "$env:USERPROFILE\Downloads\proxy-setup\proxy-setup-master"
.\install_python.bat
```

> 自动检测 Python，无则安装；装完后自动搜索并运行 `setup_proxy.py`。

---

### 或 Git Clone

```bash
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup
bash setup_proxy.sh
```

---

### 纯 PowerShell（无需 Python）

```powershell
powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
```

---

### Mac / Linux

```bash
bash setup_proxy.sh
```

如果要用 Python 版（先装 Python）：

```bash
bash install_python.sh
```

> `install_python.sh` 自动适配 Homebrew（含中科大/清华国内镜像）、apt、yum、dnf、pacman。
