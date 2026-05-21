
# 手动重现和调试 PoC

这个目录用于记录“手工模式”的流程：先在容器里为目标架构交叉编译
PoC 相关 binary，再把这些 binary 搬进 PoCLab 的 QEMU initramfs image。

PoCLab 当前使用的 guest image 是 initramfs：

``` text
out/<arch>/rootfs.img
```

它不是 qcow2 磁盘镜像。手工搬运 binary 时，实际操作对象是已经展开的
rootfs 目录：

``` text
out/<arch>/rootfs/
```

改完这个目录后，需要重新用 `cpio` 打包为 `rootfs.img`。

## 例子源码

以 copy-fail-c 为例：

``` bash
git clone https://github.com/tgies/copy-fail-c copyfail-poc
```

如果已经有源码目录，可以跳过 clone。

## 1. 选择目标架构

`arm64`：

``` bash
ARCH=arm64
CROSS_COMPILE=aarch64-linux-gnu-
CC=aarch64-linux-gnu-gcc
LD=aarch64-linux-gnu-ld
IMAGE_NAME=Image
QEMU_BIN=qemu-system-aarch64
```

`x86_64`：

``` bash
ARCH=x86_64
CROSS_COMPILE=x86_64-linux-gnu-
CC=x86_64-linux-gnu-gcc
LD=x86_64-linux-gnu-ld
IMAGE_NAME=bzImage
QEMU_BIN=qemu-system-x86_64
```

如果在 x86_64 Linux host 上编译 x86_64，也可以用宿主 `gcc`，但为了保持
流程一致，手工模式建议仍然使用容器内的 toolchain。

## 2. 准备构建容器

PoCLab 的 Docker image 内置了交叉编译工具链：

``` bash
docker image inspect kernel-poc-builder >/dev/null 2>&1 || \
  docker build -t kernel-poc-builder build/
```

后续命令默认在仓库根目录执行。

## 3. 准备 rootfs

如果 `out/<arch>/rootfs/` 或 `out/<arch>/rootfs.img` 不存在，先构建
busybox initramfs：

``` bash
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  -e ARCH="$ARCH" \
  -e CROSS_COMPILE="$CROSS_COMPILE" \
  -e IMAGE_NAME="$IMAGE_NAME" \
  kernel-poc-builder \
  bash build/scripts/build_rootfs.sh
```

如果之后要启动 QEMU，还需要 kernel image：

``` bash
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  -e ARCH="$ARCH" \
  -e CROSS_COMPILE="$CROSS_COMPILE" \
  -e IMAGE_NAME="$IMAGE_NAME" \
  kernel-poc-builder \
  bash build/scripts/build_kernel.sh
```

## 4. 在容器里交叉编译 PoC

### Makefile 型 PoC

如果 PoC 自带 Makefile，并且支持 `CC` / `LD` 覆盖，可以直接这样编译。
copy-fail-c 就属于这种情况：

``` bash
docker run --rm \
  -v "$PWD:/work" \
  -w /work/manual/copyfail-poc \
  kernel-poc-builder \
  make clean

docker run --rm \
  -v "$PWD:/work" \
  -w /work/manual/copyfail-poc \
  kernel-poc-builder \
  make CC="$CC" LD="$LD"
```

copy-fail-c 编译后会产生：

``` text
manual/copyfail-poc/exploit
manual/copyfail-poc/exploit-passwd
manual/copyfail-poc/vulnerable
```

### 单文件 C PoC

如果只是一个 `poc.c`：

``` bash
mkdir -p out/manual/$ARCH

docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  kernel-poc-builder \
  "$CC" -O2 -static -g -Wall \
    -o "out/manual/$ARCH/poc" \
    path/to/poc.c \
    -lpthread
```

尽量编译成 static binary。PoCLab 的 initramfs 很小，通常没有完整的动态链接器
和 shared libraries。

### 多文件或特殊构建系统

如果 PoC 需要 CMake、Meson、额外库或自定义构建步骤，仍然保持同一个原则：

``` text
在容器里完成目标架构 binary 的构建
把最终 binary 输出到仓库里的某个目录
再复制到 out/<arch>/rootfs/
```

需要额外依赖时，优先临时扩展 `build/Dockerfile`，或者在一个新的 builder
image 中安装依赖。不要依赖 host 上的库文件，因为 guest 运行环境来自
initramfs。

## 5. 检查 binary 架构

搬进 image 前先检查：

``` bash
file manual/copyfail-poc/exploit
file manual/copyfail-poc/exploit-passwd
file manual/copyfail-poc/vulnerable
```

`arm64` 目标应该看到类似：

``` text
ELF 64-bit LSB executable, ARM aarch64, statically linked
```

`x86_64` 目标应该看到类似：

``` text
ELF 64-bit LSB executable, x86-64, statically linked
```

## 6. 把 binary 搬进 rootfs

建议把一组 PoC 产物放到独立目录，例如 `/root/copyfail/`：

``` bash
mkdir -p "out/$ARCH/rootfs/root/copyfail"

install -m 700 manual/copyfail-poc/exploit \
  "out/$ARCH/rootfs/root/copyfail/exploit"

install -m 700 manual/copyfail-poc/exploit-passwd \
  "out/$ARCH/rootfs/root/copyfail/exploit-passwd"

install -m 700 manual/copyfail-poc/vulnerable \
  "out/$ARCH/rootfs/root/copyfail/vulnerable"
```

PoCLab 的 init 脚本会在 boot 后自动执行 `/root/poc`。如果你希望某个
binary 开机自动跑，把它复制为 `/root/poc`：

``` bash
install -m 700 manual/copyfail-poc/vulnerable \
  "out/$ARCH/rootfs/root/poc"
```

如果你不想自动运行任何 PoC，只想进 guest shell 后手工执行，可以不要改
`/root/poc`，或者删除它：

``` bash
rm -f "out/$ARCH/rootfs/root/poc"
```

进 guest 后手动执行：

``` text
/root/copyfail/vulnerable
/root/copyfail/exploit
/root/copyfail/exploit-passwd
```

## 7. 重新打包 rootfs.img

每次修改 `out/<arch>/rootfs/` 后，都要 repack：

``` bash
(
  cd "out/$ARCH/rootfs"
  find . | cpio -H newc -o
) > "out/$ARCH/rootfs.img"
```

这一步完成后，QEMU 使用的 image 才会包含你刚搬进去的 binary。

## 8. 启动 QEMU

``` bash
ARCH="$ARCH" \
CROSS_COMPILE="$CROSS_COMPILE" \
IMAGE_NAME="$IMAGE_NAME" \
QEMU_BIN="$QEMU_BIN" \
bash build/scripts/run.sh
```

如果 `/root/poc` 存在，系统启动后会自动执行它。执行完之后会进入 shell，
可以继续手动运行 `/root/copyfail/` 下的其他 binary。

## 9. 常见问题

`No such file or directory` 但文件明明存在：

通常是动态链接器不存在，或者 binary 架构不对。先用 `file` 检查是否是目标
架构、是否 static linked。

`Permission denied`：

检查 rootfs 里的执行权限：

``` bash
chmod 700 "out/$ARCH/rootfs/root/poc"
chmod 700 "out/$ARCH/rootfs/root/copyfail/"*
```

修改了 rootfs 但 QEMU 里看不到：

忘了重新打包 `rootfs.img`。重新执行第 7 步。

想替换自动运行入口：

重新复制新的 binary 到 `/root/poc`，然后 repack：

``` bash
install -m 700 "out/$ARCH/rootfs/root/copyfail/exploit" \
  "out/$ARCH/rootfs/root/poc"

(
  cd "out/$ARCH/rootfs"
  find . | cpio -H newc -o
) > "out/$ARCH/rootfs.img"
```
