## 1. 总体思路

建议把 repo 设计成以下几层：

text

```text
poc-lab/
├── pocs/                  # 每个漏洞/PoC 的定义
├── runtimes/              # 不同运行环境后端：qemu、docker、vagrant、k8s 等
├── images/                # 基础镜像/构建脚本
├── kernels/               # Linux kernel 构建与缓存
├── services/              # system service / web service 模板
├── orchestrator/          # 调度器/CLI
├── schemas/               # PoC 配置 schema
├── tools/                 # 通用工具
└── docs/
```

关键点是：**PoC 不直接绑定实现方式，而是声明它需要什么环境**。

例如：

yaml

```yaml
id: CVE-XXXX-YYYY
name: example linux kernel poc
target:
  type: linux-kernel
  arch: x86_64
  kernel: 5.10.123
runtime:
  backend: qemu
  distro: debian
  rootfs: debian-bullseye
exploit:
  build: make
  run: ./poc
verify:
  type: command
  command: uname -r && dmesg | tail
cleanup:
  strategy: destroy-vm
```

对于 FreeBSD：

yaml

```yaml
id: CVE-XXXX-ZZZZ
name: freebsd kernel poc
target:
  type: freebsd-kernel
  version: "13.2"
  arch: x86_64
runtime:
  backend: qemu
  image: freebsd-13.2.qcow2
exploit:
  build: make
  run: ./poc
verify:
  type: command
  command: uname -a
```

对于 web service：

yaml

```yaml
id: CVE-XXXX-WEB
name: vulnerable web service poc
target:
  type: web-service
runtime:
  backend: docker-compose
  compose: docker-compose.yml
exploit:
  run: python3 exploit.py --target http://target:8080
verify:
  type: http
  url: http://target:8080/health
```

---

## 2. 核心抽象：PoC Manifest

每个 PoC 目录建议包含一个统一配置文件，例如 `poc.yaml`。

text

```text
pocs/
└── CVE-XXXX-YYYY/
    ├── poc.yaml
    ├── exploit/
    │   ├── poc.c
    │   └── Makefile
    ├── patches/
    ├── assets/
    ├── README.md
    └── expected/
```

`poc.yaml` 推荐包含这些字段：

yaml

```yaml
id: CVE-XXXX-YYYY
name: xxx vulnerability
description: short description
severity: high

target:
  type: linux-kernel | freebsd-kernel | system-service | web-service | userspace-app
  os: linux | freebsd | windows | generic
  version: "..."
  arch: x86_64

environment:
  privilege: root | user
  network: true
  cpu: 2
  memory: 2048M
  disk: 10G

runtime:
  backend: qemu | docker | docker-compose | vagrant | k8s | local
  image: ...
  kernel: ...
  rootfs: ...

build:
  commands:
    - make

run:
  command: ./poc
  timeout: 30
  expected_exit_code: 0

verify:
  type: command | http | file | log | crash | custom
  command: dmesg | tail -100
  success_pattern: "BUG|Oops|root"

cleanup:
  strategy: destroy | snapshot-rollback | keep-on-failure

metadata:
  cve: CVE-XXXX-YYYY
  references:
    - https://example.com
  tags:
    - kernel
    - lpe
```

这样之后平台只需要做：

bash

```bash
pocctl run CVE-XXXX-YYYY
pocctl build CVE-XXXX-YYYY
pocctl shell CVE-XXXX-YYYY
pocctl clean CVE-XXXX-YYYY
```

---

## 3. Runtime 后端设计

你需要支持不同类型漏洞，所以 runtime 后端要插件化。

建议定义一个统一接口：

python

View all

```python
class Runtime:
    def prepare(self, manifest):
        pass

    def build(self, manifest):
        pass

    def start(self, manifest):
        pass

    def exec(self, command):
        pass

    def upload(self, src, dst):
        pass

    def verify(self, manifest):
        pass

    def cleanup(self):
        pass
```

Run

然后实现不同后端：

text

```text
runtimes/
├── qemu_linux.py
├── qemu_freebsd.py
├── docker_runtime.py
├── docker_compose_runtime.py
├── vagrant_runtime.py
├── k8s_runtime.py
└── local_runtime.py
```

### 推荐映射

|漏洞类型|推荐运行后端|
|---|---|
|Linux kernel|QEMU/KVM|
|FreeBSD kernel|QEMU/Bhyve/Vagrant|
|system service|Docker、VM、systemd-nspawn|
|web service|Docker Compose、K8s|
|userspace app|Docker、local sandbox|
|Windows service|Hyper-V、VMware、Vagrant|

---

## 4. Linux kernel 多版本切换设计

你提到每个 PoC 的 kernel 版本不同，需要频繁切换。这里建议不要在宿主机上切 kernel，而是使用 **QEMU + kernel artifact cache**。

### 基本结构

text

```text
kernels/
├── linux/
│   ├── 4.19.312/
│   │   ├── bzImage
│   │   ├── vmlinux
│   │   ├── modules.tar.gz
│   │   └── config
│   ├── 5.4.280/
│   ├── 5.10.221/
│   └── 6.1.90/
└── build/
    ├── build-linux-kernel.sh
    └── configs/
```

每个 PoC 只需要声明：

yaml

```yaml
target:
  type: linux-kernel
  kernel: 5.10.221
  config: default-kasan
```

平台检查：

1. 本地是否已有 `bzImage`。
2. 是否有对应 modules。
3. 是否有 rootfs。
4. 没有则自动构建或下载。
5. 启动 QEMU 时传入对应 kernel。

示例：

bash

```bash
qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -kernel kernels/linux/5.10.221/bzImage \
  -append "console=ttyS0 root=/dev/sda nokaslr" \
  -drive file=rootfs/debian-bullseye.qcow2,format=qcow2 \
  -nographic
```

不要真的“切换宿主机 kernel”。那样维护成本高、风险大，也不适合自动化。

---

## 5. 镜像与环境缓存

为了提高复现速度，需要设计 artifact cache。

text

```text
.artifacts/
├── kernels/
├── rootfs/
├── docker-images/
├── freebsd-images/
├── build-cache/
└── logs/
```

建议把环境拆成三类：

### 1. Base image

例如：

text

```text
debian-bullseye-base.qcow2
ubuntu-20.04-base.qcow2
freebsd-13.2-base.qcow2
```

### 2. Overlay image

每次运行 PoC 时创建 overlay：

bash

```bash
qemu-img create -f qcow2 -b debian-bullseye-base.qcow2 run-CVE-XXXX.qcow2
```

这样每次运行结束直接删除 overlay，保证环境干净。

### 3. Build artifact

kernel、module、exploit binary 都缓存。

---

## 6. 对不同系统类型的具体建议

### A. Linux kernel 漏洞

建议使用：

- QEMU/KVM
- initramfs 或 qcow2 rootfs
- kernel artifact 缓存
- gdb / kgdb 可选支持
- snapshot rollback
- serial console log
- dmesg 捕获
- crash/oops 检测

PoC 配置示例：

yaml

```yaml
target:
  type: linux-kernel
  os: linux
  arch: x86_64
  kernel: 5.10.221

runtime:
  backend: qemu
  rootfs: debian-bullseye
  kernel_args:
    - console=ttyS0
    - nokaslr
    - panic=1

verify:
  type: log
  source: serial
  success_pattern: "BUG:|Oops|general protection fault"
```

---

### B. FreeBSD kernel 漏洞

FreeBSD 不适合用 Linux rootfs 那套，要作为单独 runtime：

yaml

```yaml
target:
  type: freebsd-kernel
  os: freebsd
  version: "13.2"
  arch: x86_64

runtime:
  backend: qemu
  image: freebsd-13.2-base.qcow2

verify:
  type: command
  command: uname -a
```

建议单独维护：

text

```text
images/freebsd/
├── 13.2/
├── 13.3/
└── 14.0/
```

如果需要不同 kernel build，也可以类似 Linux：

text

```text
kernels/freebsd/
├── 13.2-RELEASE/
├── 13.3-RELEASE/
└── custom/
```

---

### C. system service 漏洞

这类漏洞有两种情况：

1. 服务依赖 systemd、dbus、namespace、capability。
2. 服务只是普通进程。

如果强依赖 systemd，优先：

- VM
- systemd-nspawn
- privileged Docker

如果不强依赖 systemd：

- Docker 即可。

配置示例：

yaml

```yaml
target:
  type: system-service
  os: linux
  service: vulnerable-daemon
  version: 1.2.3

runtime:
  backend: docker
  dockerfile: Dockerfile

service:
  start:
    - systemctl start vulnerable-daemon
  ports:
    - "1234/tcp"

exploit:
  run: python3 exploit.py --host target --port 1234
```

---

### D. web service 漏洞

建议使用 Docker Compose，因为一个 web 漏洞经常涉及：

- app
- database
- cache
- queue
- nginx
- redis
- elasticsearch

目录：

text

```text
pocs/CVE-XXXX-WEB/
├── poc.yaml
├── docker-compose.yml
├── exploit.py
├── app/
└── README.md
```

配置：

yaml

```yaml
target:
  type: web-service

runtime:
  backend: docker-compose
  compose: docker-compose.yml

healthcheck:
  type: http
  url: http://target:8080/

exploit:
  run: python3 exploit.py --target http://target:8080

verify:
  type: http
  url: http://target:8080/result
  success_pattern: "pwned"
```

---

## 7. 插件化类型系统

建议把 target type 设计成插件，不要写死。

text

```text
plugins/
├── linux_kernel/
│   ├── plugin.yaml
│   ├── runtime.py
│   └── schema.json
├── freebsd_kernel/
├── web_service/
├── system_service/
└── userspace_app/
```

每种插件负责：

1. 校验自己的 `poc.yaml`。
2. 选择 runtime。
3. 准备环境。
4. 定义 verify 方式。
5. 收集日志。

这样后续加类型不会破坏主框架。

---

## 8. 执行流程

推荐统一执行流水线：

text

```text
load manifest
      |
validate manifest
      |
resolve dependencies
      |
prepare image/kernel/service
      |
create isolated run workspace
      |
start runtime
      |
wait healthcheck
      |
build exploit
      |
run exploit
      |
verify result
      |
collect logs/artifacts
      |
cleanup or keep
```

可以抽象成：

bash

```bash
pocctl run CVE-XXXX-YYYY
```

内部流程：

text

```text
pocctl
  -> manifest loader
  -> schema validator
  -> runtime resolver
  -> artifact manager
  -> executor
  -> verifier
  -> reporter
```

---

## 9. Repo 目录建议

一个比较完整的结构：

text

```text
poc-lab/
├── pocs/
│   ├── linux-kernel/
│   │   └── CVE-XXXX-YYYY/
│   ├── freebsd-kernel/
│   │   └── CVE-XXXX-ZZZZ/
│   ├── system-service/
│   │   └── CVE-XXXX-AAAA/
│   └── web-service/
│       └── CVE-XXXX-BBBB/
│
├── runtime/
│   ├── base.py
│   ├── qemu.py
│   ├── docker.py
│   ├── docker_compose.py
│   ├── vagrant.py
│   └── k8s.py
│
├── plugins/
│   ├── linux_kernel/
│   ├── freebsd_kernel/
│   ├── system_service/
│   └── web_service/
│
├── artifacts/
│   ├── kernels/
│   ├── rootfs/
│   ├── images/
│   └── cache/
│
├── schemas/
│   ├── poc.schema.json
│   ├── linux-kernel.schema.json
│   ├── freebsd-kernel.schema.json
│   └── web-service.schema.json
│
├── cli/
│   └── pocctl.py
│
├── examples/
├── docs/
└── README.md
```

---

## 10. Manifest 设计建议

建议分为通用 schema 和类型扩展 schema。

### 通用字段

yaml

```yaml
apiVersion: poclab/v1
kind: PoC

metadata:
  id: CVE-XXXX-YYYY
  name: xxx
  tags: []

target:
  type: linux-kernel

runtime:
  backend: qemu

steps:
  prepare: []
  build: []
  start: []
  exploit: []
  verify: []
  cleanup: []
```

### 类型扩展

Linux kernel：

yaml

```yaml
target:
  type: linux-kernel
  linux:
    kernel: 5.10.221
    config: kasan
    arch: x86_64
    modules: true
```

Web service：

yaml

```yaml
target:
  type: web-service
  web:
    ports:
      - 8080
    healthcheck:
      path: /
```

---

## 11. 安全隔离建议

因为你是在复现漏洞，尤其是 LPE、RCE、kernel crash，隔离非常重要。

建议默认策略：

|类型|隔离方式|
|---|---|
|kernel PoC|QEMU VM|
|FreeBSD kernel PoC|QEMU VM|
|web RCE|Docker Compose 网络隔离|
|system service|VM 或特权容器|
|destructive PoC|VM snapshot|
|unknown PoC|禁止 host network、禁止挂载宿主敏感目录|

建议每次运行创建独立 workspace：

text

```text
runs/
└── CVE-XXXX-YYYY-20260517-120000/
    ├── manifest.yaml
    ├── console.log
    ├── dmesg.log
    ├── exploit.log
    ├── result.json
    └── artifacts/
```

---

## 12. 输出结果格式

每次运行输出统一报告：

json

```json
{
  "id": "CVE-XXXX-YYYY",
  "status": "success",
  "target": {
    "type": "linux-kernel",
    "kernel": "5.10.221"
  },
  "runtime": {
    "backend": "qemu"
  },
  "duration": 42.5,
  "logs": {
    "console": "runs/.../console.log",
    "exploit": "runs/.../exploit.log"
  },
  "verification": {
    "type": "log",
    "matched": true,
    "pattern": "BUG:"
  }
}
```

这样后面可以接 CI、dashboard、批量复现。

---

## 13. 推荐 CLI

bash

```bash
# 查看 PoC
pocctl list

# 运行单个 PoC
pocctl run CVE-XXXX-YYYY

# 只准备环境
pocctl prepare CVE-XXXX-YYYY

# 进入交互 shell
pocctl shell CVE-XXXX-YYYY

# 构建 kernel
pocctl kernel build --version 5.10.221 --config kasan

# 清理缓存
pocctl clean

# 批量运行
pocctl run --tag linux-kernel --parallel 4

# 保留失败环境
pocctl run CVE-XXXX-YYYY --keep-on-failure
```

---

## 14. 最小可行版本 MVP

不要一开始做太复杂。可以按这个顺序落地：

### Phase 1：Linux kernel MVP

支持：

- `poc.yaml`
- QEMU 启动
- 多 kernel artifact
- rootfs overlay
- 上传/编译/运行 PoC
- console log 收集
- 简单 verify

目录：

text

```text
pocs/
runtime/qemu.py
artifacts/kernels/
artifacts/rootfs/
pocctl.py
```

### Phase 2：Docker / web service

支持：

- Dockerfile
- docker-compose
- HTTP healthcheck
- exploit runner
- 网络隔离

### Phase 3：FreeBSD

支持：

- FreeBSD qcow2 image
- QEMU 启动
- SSH 执行命令
- FreeBSD kernel artifact

### Phase 4：插件系统和 CI

支持：

- schema 校验
- 插件化 target
- 批量运行
- JSON 报告
- Dashboard

---

## 15. 一个推荐架构图

text

```text
                 ┌─────────────────┐
                 │     pocctl       │
                 └────────┬────────┘
                          │
                 ┌────────▼────────┐
                 │ Manifest Loader  │
                 └────────┬────────┘
                          │
                 ┌────────▼────────┐
                 │ Schema Validator │
                 └────────┬────────┘
                          │
                 ┌────────▼────────┐
                 │ Runtime Resolver │
                 └────────┬────────┘
                          │
        ┌─────────────────┼─────────────────┐
        │                 │                 │
┌───────▼───────┐ ┌───────▼───────┐ ┌───────▼────────┐
│ QEMU Runtime  │ │Docker Runtime │ │Compose Runtime │
└───────┬───────┘ └───────┬───────┘ └───────┬────────┘
        │                 │                 │
┌───────▼───────┐ ┌───────▼───────┐ ┌───────▼────────┐
│ Linux Kernel  │ │System Service │ │ Web Service    │
└───────────────┘ └───────────────┘ └────────────────┘
```

---

## 16. 关键设计原则

总结一下：

1. **不要切宿主机 kernel**  
    使用 QEMU 加载不同 kernel。
    
2. **PoC 使用 manifest 自描述环境**  
    每个 PoC 明确写需要的 OS、kernel、service、依赖。
    
3. **runtime 后端插件化**  
    QEMU、Docker、Compose、Vagrant、K8s 都作为后端。
    
4. **target type 插件化**  
    Linux kernel、FreeBSD、web service、system service 分开扩展。
    
5. **artifact 缓存化**  
    kernel、rootfs、镜像、exploit binary 都缓存。
    
6. **运行环境一次性化**  
    每次运行用 overlay/snapshot，结束销毁。
    
7. **验证逻辑标准化**  
    command/http/log/file/custom verifier。
    
8. **结果输出结构化**  
    统一输出 JSON，方便 CI 和 Dashboard。
    

---

我建议你把这个 repo 定位成：

> **A declarative vulnerability reproduction lab**  
> 用声明式配置描述漏洞复现环境，由统一编排器自动构建、启动、验证和清理。

如果你要先做 MVP，优先实现：

text

```text
poc.yaml + QEMU Linux kernel runtime + artifact cache + log verifier
```

这个最核心，后面 FreeBSD、web service、system service 都可以自然扩展。