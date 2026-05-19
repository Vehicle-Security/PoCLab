# PoCLab 候选漏洞目录（2）

收录 **公开资料可核验为 LLM/AI 工具参与发现**、且与 PoCLab 目标（内核 / 服务 / 库、可隔离复现）相关的近期条目。主目录见 [VULN_CATALOG.md](./VULN_CATALOG.md)。

---

## 收录标准（本备选表）

1. **可核验**：公告 / CVE 描述 / 厂商致谢中出现 LLM 或 AI 研究项目 credit。  
2. **时间**：以 **2024 年起** 为主。  
3. **PoCLab 相关度**：优先 Linux/FreeBSD 内核、系统服务、密码学/解析库。  
4. **复现**：A/B/C 含义同主目录。

---

## 已在主目录（交叉引用）

| CVE | 发现方 | 组件 | 类型 | 复现 | 权威来源 |
|-----|--------|------|------|------|----------|
| [CVE-2026-31431](https://nvd.nist.gov/vuln/detail/CVE-2026-31431) | **Xint Code**（Theori）+ 人工 | Linux `crypto` / AF_ALG | state → 页缓存写 | A | [copy.fail](https://copy.fail/)、[Xint 博文](https://xint.io/blog/copy-fail-linux-distributions) |

**核验**：NVD 条目存在；copy.fail / Xint 博文 HTTP 200；漏洞描述与 LPE 叙事一致。

---

## Linux kernel（备选）

| CVE | 发现方 | 子系统 | 类型 | 复现 | 权威来源 / PoC | 备注 |
|-----|--------|--------|------|------|----------------|------|
| [CVE-2026-31402](https://nvd.nist.gov/vuln/detail/CVE-2026-31402) | Nicholas Carlini 报告；**公开活动称 Claude Opus 4.6 辅助**（NVD 正文未写 LLM） | net/NFSv4.0 | heap OOB（LOCK replay） | B | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-31402)、[Ubuntu](https://ubuntu.com/security/CVE-2026-31402) | **远程**需双 NFSv4.0 客户端；非单机本地一键 |
| [CVE-2026-31554](https://nvd.nist.gov/vuln/detail/CVE-2026-31554) | Carlini；**内核 commit 写明「his LLM found」** | futex | UAF | B | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2026-31554)、[RH BZ 2461526](https://bugzilla.redhat.com/show_bug.cgi?id=2461526) | 本地 `futex_requeue` 源/目的 flags 不一致 |
| [CVE-2024-23848](https://nvd.nist.gov/vuln/detail/CVE-2024-23848) | **KernelGPT**（论文归因） | media/CEC | UAF | C | [arXiv:2401.00563](https://arxiv.org/html/2401.00563v2) | NVD 确认 `cec_queue_msg_fh` UAF；**NVD 无 LLM 字段** |
| [CVE-2024-23851](https://nvd.nist.gov/vuln/detail/CVE-2024-23851) | KernelGPT（论文） | device-mapper | integer → kmalloc | C | 同上 | NVD：`ctl_ioctl` / `copy_params` |
| [CVE-2024-23849](https://nvd.nist.gov/vuln/detail/CVE-2024-23849) | KernelGPT（论文） | net/RDS | OOB（off-by-one） | C | 同上 | NVD：`rds_recv_track_latency` |
| [CVE-2024-23850](https://nvd.nist.gov/vuln/detail/CVE-2024-23850) | KernelGPT（论文） | fs/btrfs | assertion/崩溃 | C | 同上 | NVD：子卷创建竞态致 assertion；**非 UAF** |
| [CVE-2024-25739](https://nvd.nist.gov/vuln/detail/CVE-2024-25739) | KernelGPT（论文） | fs/UBI | 零字节分配/崩溃 | C | 同上 | NVD：`create_empty_lvol` 缺 `leb_size` 检查 |
| [CVE-2024-50291](https://nvd.nist.gov/vuln/detail/CVE-2024-50291) | KernelGPT（论文） | media/DVB | 缺界检查（索引） | C | 同上 | NVD：`dvb_vb2_expbuf`；**非 GPF 表述** |
| [CVE-2025-38236](https://nvd.nist.gov/vuln/detail/CVE-2025-38236) | —（**非** LLM） | net/UNIX `MSG_OOB` | UAF | B | [Project Zero](https://projectzero.google/2025/08/from-chrome-renderer-code-exec-to-kernel.html) | 对照项：人工 P0 发现 |

**Google Big Sleep（2024）— SQLite，开发版已修**

| 标识 | 发现方 | 组件 | 类型 | 复现 | 来源 |
|------|--------|------|------|------|------|
| [Chromium 372435124](https://project-zero.issues.chromium.org/issues/372435124) | **Big Sleep**（Gemini） | SQLite `series` 扩展 | stack buffer underflow | C | [P0 博文](https://projectzero.google/2024/10/from-naptime-to-big-sleep.html) | **无正式 CVE**（发版前修复） |

---

## FreeBSD kernel（备选）

| CVE | 发现方 | 子系统 | 类型 | 复现 | 权威来源 / PoC | 备注 |
|-----|--------|--------|------|------|----------------|------|
| [CVE-2026-4747](https://nvd.nist.gov/vuln/detail/CVE-2026-4747) | **Claude** + Carlini | net/RPCSEC_GSS | stack overflow | A | [FreeBSD-SA-26:08](https://security.freebsd.org/advisories/FreeBSD-SA-26:08.rpcsec_gss.asc)、[Calif.io](https://blog.calif.io/p/mad-bugs-claude-wrote-a-full-freebsd)、[exploit 仓库](https://github.com/califio/publications/tree/main/MADBugs/CVE-2026-4747) | SA Credits 行含「Nicholas Carlini using Claude」；**内核 RCE 需 kgssapi+NFS 等前提**（见 SA III） |
| [CVE-2026-5398](https://nvd.nist.gov/vuln/detail/CVE-2026-5398) | Carlini + Claude | ioctl/tty | UAF → LPE | B | [FreeBSD-SA-26:10](https://security.freebsd.org/advisories/FreeBSD-SA-26:10.tty.asc) | `TIOCNOTTY` 悬空指针；SA Credits 含 Claude |
| [CVE-2026-6386](https://nvd.nist.gov/vuln/detail/CVE-2026-6386) | Carlini + Claude | mm/pmap（PKRU） | 权限/页表逻辑 | B | [FreeBSD-SA-26:11](https://security.freebsd.org/advisories/FreeBSD-SA-26:11.amd64.asc) | `pmap_pkru_update_range` + 1GB 大页；SA Credits 含 Claude |
| MAD Bugs 批次 | Claude Opus 4.6 | Vim / FreeBSD / Emacs | 多类 | 披露中 | [red.anthropic.com](https://red.anthropic.com/2026/zero-days/) | 宣称 500+；**无完整 CVE 公开列表**，不可逐条验 PoC |

---

## System services / 虚拟化（备选）

| CVE | 发现方 | 组件 | 类型 | 复现 | 来源 |
|-----|--------|------|------|------|------|
| [CVE-2026-5747](https://nvd.nist.gov/vuln/detail/CVE-2026-5747) | Anthropic → AWS VDP | **Firecracker** virtio-pci | OOB write | B | [AWS 2026-015](https://aws.amazon.com/security/security-bulletins/2026-015-aws/) | 致谢「Anthropic」；guest root + 特定前提 |
| [CVE-2026-6479](https://nvd.nist.gov/vuln/detail/CVE-2026-6479) | Calif.io + Claude | **PostgreSQL** | 无限递归 → DoS | B | [PostgreSQL 公告](https://www.postgresql.org/support/security/CVE-2026-6479/) | 官方致谢 Claude；非内存破坏 |
| [CVE-2026-26980](https://nvd.nist.gov/vuln/detail/CVE-2026-26980) | Carlini + Claude | **Ghost** CMS | SQL 注入 | B | [GHSA-w52v-v783-gw97](https://github.com/TryGhost/Ghost/security/advisories/GHSA-w52v-v783-gw97) | Web 应用；References 致谢 Claude |

---

## Parser / 密码学库（备选）

| CVE | 发现方 | 组件 | 类型 | 复现 | 来源 |
|-----|--------|------|------|------|------|
| [CVE-2026-28386](https://nvd.nist.gov/vuln/detail/CVE-2026-28386) | Aisle Research；**后由 Alex Gaynor（Anthropic）独立报告** | OpenSSL | OOB read（AES-CFB/VAES） | B | [OpenSSL secadv 20260407](https://openssl-library.org/news/secadv/20260407.txt) | 厂商评级 **Low**；非主目录 P04（CVE-2022-3602） |
| [CVE-2026-34580](https://nvd.nist.gov/vuln/detail/CVE-2026-34580) | Carlini + Claude | **Botan** | 证书校验逻辑 | B | [GHSA-v782-6fq4-q827](https://github.com/randombit/botan/security/advisories/GHSA-v782-6fq4-q827) | Credit 行含 Claude |
| CVE-2026-5194 等 | Carlini / Calif.io + Claude | **wolfSSL** | 多种 | B | [追踪表](https://github.com/patrickmgarrity/Anthropic-Credited-CVEs) | 社区表；逐条见 NVD |
| Ghostscript / OpenSC / CGIF | Claude Opus 4.6（案例） | 解析库 | 内存破坏 | C | [red.anthropic.com](https://red.anthropic.com/2026/zero-days/) | 已修；**博文未给 CVE 号** |

---

## 参考文献

- [Anthropic：LLM 0-day 评估](https://red.anthropic.com/2026/zero-days/)
- [Google P0：Big Sleep](https://projectzero.google/2024/10/from-naptime-to-big-sleep.html)
- [Anthropic-Credited-CVEs](https://github.com/patrickmgarrity/Anthropic-Credited-CVEs)
- [KernelGPT arXiv](https://arxiv.org/abs/2401.00563)

*最后更新：2026-05-17。*
