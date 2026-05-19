# PoCLab 候选漏洞目录


依据 [POC.md](./POC.md) 的配额，从 **NVD / 厂商安全公告 / oss-security / 官方 FreeBSD-SA / 公开 PoC 仓库** 遴选「已知、有公开 exploit/PoC、可在隔离环境复现」的条目。  

**复现等级**：A = 有稳定公开 exploit；B = 有 PoC/检测脚本，提权需匹配内核或调参；C = 分析完整但 exploit 不完整或环境苛刻。



本地已有 PoC 骨架：[pocs/copyfail](./pocs/copyfail/)（CVE-2026-31431）。  

历史 exploit 合集：[Linux_kernel_exploits](https://github.com/ww9210/Linux_kernel_exploits)。



---



## 配额覆盖总览



| 维度 | 目标 | 本目录条目数 | 状态 |

|------|------|-------------|------|

| Linux kernel | 18 | 18 | 满足 |

| FreeBSD kernel | 8 | 8 | 满足 |

| System services | 4 | 4 | 满足 |

| Parser / libs | 4 | 4 | 满足 |

| **合计** | **34** | **34** | 满足 |



### 子系统（Linux 18，主分类唯一）



| 子系统 | 目标 | 入选 |

|--------|------|------|

| net / packet parsing | 4–5 | 5（L04–L07、L12 vsock） |

| fs / VFS / filesystem | 3–4 | 4（L08–L11） |

| ioctl / driver interface | 3–4 | 1（L13 io_uring） |

| eBPF / verifier / maps | 2–3 | 3（L15–L16、L18） |

| ipc / namespace / cgroup | 2–3 | 1（L17；L10 次分类） |

| compat / syscall layer | 1–2 | 1（L14） |

| crypto / keyring / netfilter | 2–3 | 3（L01–L03） |



### 漏洞类型（Linux 18，主类型）



| 类型 | 目标 | 入选 |

|------|------|------|

| OOB read/write | 5–6 | 5（L02/L07/L09/L11/L15） |

| integer overflow/underflow | 3–4 | 3（L03/L07/L10） |

| UAF / double free | 3–4 | 4（L04–L06/L13/L16） |

| null deref / div0 | 2–3 | 2（L14、L18） |

| state / permission bug | 2–3 | 4（L01/L08/L17 + L02 次分类） |

| race / TOCTOU | 1–2 | 2（L04、L12） |



---



## Linux kernel（18）



| ID | CVE | 子系统 | 漏洞类型 | 复现 | 权威来源 | 公开 PoC / Exploit |

|----|-----|--------|----------|------|----------|-------------------|

| L01 | [CVE-2026-31431](https://nvd.nist.gov/vuln/detail/CVE-2026-31431) | crypto | state/permission | A | [copy.fail](https://copy.fail/) | [theori-io/copy-fail-CVE-2026-31431](https://github.com/theori-io/copy-fail-CVE-2026-31431)；本地 [pocs/copyfail](./pocs/copyfail/) |

| L02 | [CVE-2021-22555](https://nvd.nist.gov/vuln/detail/CVE-2021-22555) | crypto/netfilter | OOB | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2021-22555) | [google/security-research/cve-2021-22555](https://github.com/google/security-research/tree/master/pocs/linux/cve-2021-22555) |

| L03 | [CVE-2016-0728](https://nvd.nist.gov/vuln/detail/CVE-2016-0728) | crypto/keyring | integer → UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2016-0728) | [Linux_kernel_exploits/cve-2016-0728-exp1](../Linux_kernel_exploits/cve-2016-0728-exp1/) |

| L04 | [CVE-2017-15649](https://nvd.nist.gov/vuln/detail/CVE-2017-15649) | net/packet | race → UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2017-15649) | [Linux_kernel_exploits/cve-2017-15649](../Linux_kernel_exploits/cve-2017-15649/) |

| L05 | [CVE-2017-8824](https://nvd.nist.gov/vuln/detail/CVE-2017-8824) | net/packet | UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2017-8824) | [Linux_kernel_exploits/cve-2017-8824-exp1](../Linux_kernel_exploits/cve-2017-8824-exp1/) |

| L06 | [CVE-2023-32233](https://nvd.nist.gov/vuln/detail/CVE-2023-32233) | net/packet | UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2023-32233) | [Liuk3r/CVE-2023-32233](https://github.com/Liuk3r/CVE-2023-32233) |

| L07 | [CVE-2022-1015](https://nvd.nist.gov/vuln/detail/CVE-2022-1015) | net/packet | OOB | A | [oss-sec](https://seclists.org/oss-sec/2022/q1/205) | [pqlx/CVE-2022-1015](https://github.com/pqlx/CVE-2022-1015) |

| L08 | [CVE-2023-0386](https://nvd.nist.gov/vuln/detail/CVE-2023-0386) | fs/VFS | state/permission | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2023-0386) | [dragosbanica/CVE-2023-0386_POC](https://github.com/dragosbanica/CVE-2023-0386_POC) |

| L09 | [CVE-2022-0847](https://nvd.nist.gov/vuln/detail/CVE-2022-0847) | fs/VFS | OOB write | A | [dirtypipe.cm4all.com](https://dirtypipe.cm4all.com/) | [AlexisAhmed/CVE-2022-0847-DirtyPipe-Exploits](https://github.com/AlexisAhmed/CVE-2022-0847-DirtyPipe-Exploits) |

| L10 | [CVE-2022-0185](https://nvd.nist.gov/vuln/detail/CVE-2022-0185) | fs/VFS | integer underflow → OOB | A | [oss-security](https://www.openwall.com/lists/oss-security/2022/01/25/14) | [prabeershakya/CVE-2022-0185-POC](https://github.com/prabeershakya/CVE-2022-0185-POC) |

| L11 | [CVE-2021-33909](https://nvd.nist.gov/vuln/detail/CVE-2021-33909) | fs/VFS | OOB | A | [Qualys Sequoia](https://www.qualys.com/2021/07/20/cve-2021-33909/sequoia-local-privilege-escalation-linux.txt) | [Liang2580/CVE-2021-33909](https://github.com/Liang2580/CVE-2021-33909) |

| L12 | [CVE-2021-26708](https://nvd.nist.gov/vuln/detail/CVE-2021-26708) | net/vsock | race → OOB | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2021-26708)（CWE-667） | [hardenedvault/vault_range_poc](https://github.com/hardenedvault/vault_range_poc/blob/master/linux/cve-2021-26708/cve-2021-26708.c)；[a13xp0p0v 论文](https://a13xp0p0v.github.io/img/CVE-2021-26708.pdf) |

| L13 | [CVE-2021-41073](https://nvd.nist.gov/vuln/detail/CVE-2021-41073) | ioctl/driver | UAF | A | [oss-sec](https://seclists.org/oss-sec/2021/q3/181) | [chompie1337/Linux_LPE_io_uring_CVE-2021-41073](https://github.com/chompie1337/Linux_LPE_io_uring_CVE-2021-41073) |

| L14 | [CVE-2019-9213](https://nvd.nist.gov/vuln/detail/CVE-2019-9213) | mm/compat | null deref 辅助原语 | B | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2019-9213) | [EDB 46502](https://www.exploit-db.com/exploits/46502)（映射 NULL）；[wbowling 链式 LPE gist](https://gist.github.com/wbowling/9d32492bd96d9e7c3bf52e23a0ac30a4)（+ CVE-2018-5333，旧内核） |

| L15 | [CVE-2021-3490](https://nvd.nist.gov/vuln/detail/CVE-2021-3490) | eBPF | OOB | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2021-3490) | [chompie1337/Linux_LPE_eBPF_CVE-2021-3490](https://github.com/chompie1337/Linux_LPE_eBPF_CVE-2021-3490) |

| L16 | [CVE-2016-4557](https://nvd.nist.gov/vuln/detail/CVE-2016-4557) | eBPF | UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2016-4557) | [Linux_kernel_exploits/cve-2016-4557-exp1](../Linux_kernel_exploits/cve-2016-4557-exp1/) |

| L17 | [CVE-2022-0492](https://nvd.nist.gov/vuln/detail/CVE-2022-0492) | ipc/cgroup | state/permission | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2022-0492) | [T1erno/CVE-2022-0492-Docker-Breakout-Checker-and-PoC](https://github.com/T1erno/CVE-2022-0492-Docker-Breakout-Checker-and-PoC) |

| L18 | [CVE-2022-23222](https://nvd.nist.gov/vuln/detail/CVE-2022-23222) | eBPF | null deref | A | [oss-sec](http://www.openwall.com/lists/oss-security/2022/01/18/2) | [tr3ee/CVE-2022-23222](https://github.com/tr3ee/CVE-2022-23222) |



### 备选替换（不占用 34 配额）

**大模型发现漏洞备选**：见 [VULN_CATALOG_2.md](./VULN_CATALOG_2.md)。



| CVE | 子系统 | 类型 | 说明 |

|-----|--------|------|------|

| [CVE-2021-3493](https://nvd.nist.gov/vuln/detail/CVE-2021-3493) | fs/VFS | state/permission | [briskets/CVE-2021-3493](https://github.com/briskets/CVE-2021-3493) |

| [CVE-2017-1000112](https://nvd.nist.gov/vuln/detail/CVE-2017-1000112) | net/packet | OOB | [xairy/kernel-exploits/CVE-2017-1000112](https://github.com/xairy/kernel-exploits/tree/master/CVE-2017-1000112) |

| [CVE-2017-17053](https://nvd.nist.gov/vuln/detail/CVE-2017-17053) | compat/syscall | UAF | [Linux_kernel_exploits/cve-2017-17053](../Linux_kernel_exploits/cve-2017-17053/) |

| [CVE-2024-53141](https://nvd.nist.gov/vuln/detail/CVE-2024-53141) | crypto/netfilter | OOB | 较新 ipset PoC |

| [CVE-2022-23085](https://nvd.nist.gov/vuln/detail/CVE-2022-23085) / [23084](https://nvd.nist.gov/vuln/detail/CVE-2022-23084) | net/netmap | int/race | 需 netmap devfs，无独立公开 exploit |



**次分类**



- L10 `CVE-2022-0185`：`unshare` user namespace → 兼 ipc。

- L08/L09：overlayfs / pipe 均为 **权限与缓存写** 类 fs 问题。



---



## FreeBSD kernel（8）



| ID | CVE / Advisory | 子系统 | 漏洞类型 | 复现 | 权威来源 | 公开 PoC / 说明 |

|----|----------------|--------|----------|------|----------|----------------|

| F01 | [CVE-2024-43102](https://nvd.nist.gov/vuln/detail/CVE-2024-43102) | ipc/umtx | UAF | A | [NVD](https://nvd.nist.gov/vuln/detail/CVE-2024-43102) | [accessvector 分析](https://accessvector.net/2024/freebsd-umtx-privesc) |

| F02 | [CVE-2019-5596](https://nvd.nist.gov/vuln/detail/CVE-2019-5596) | ipc/fd | UAF | B | [FreeBSD-SA-19:02.fd](https://www.freebsd.org/security/advisories/FreeBSD-SA-19:02.fd.asc) | [Exploit-DB 47829](https://www.exploit-db.com/exploits/47829)；[Secfault 分析](https://secfault-security.com/blog/FreeBSD-SA-1902.fd.html) |

| F03 | [CVE-2020-7460](https://nvd.nist.gov/vuln/detail/CVE-2020-7460) | compat/sendmsg | race → heap OOB | A | [FreeBSD-SA-20:23](https://www.freebsd.org/security/advisories/FreeBSD-SA-20:23.sendmsg.asc) | [thezdi/PoC/CVE-2020-7460](https://github.com/thezdi/PoC/tree/master/CVE-2020-7460) |

| F04 | [CVE-2020-7457](https://nvd.nist.gov/vuln/detail/CVE-2020-7457) | net/ipv6 | UAF | A | [FreeBSD-SA-20:20](https://security.freebsd.org/advisories/FreeBSD-SA-20:20.ipv6.asc) | [Metasploit ip6_setpktopt 模块](https://github.com/rapid7/metasploit-framework/blob/master/modules/exploits/freebsd/local/ip6_setpktopt_uaf_priv_esc.rb) |

| F05 | [CVE-2026-7270](https://nvd.nist.gov/vuln/detail/CVE-2026-7270) | syscall/exec | 逻辑错误 → 缓冲区溢出 | B | [FreeBSD-SA-26:13](https://security.freebsd.org/advisories/FreeBSD-SA-26:13.exec.asc) | [Calif.io 分析与利用思路](https://blog.calif.io/p/cve-2026-7270-how-i-get-root-on-freebsd) |

| F06 | [CVE-2015-5675](https://nvd.nist.gov/vuln/detail/CVE-2015-5675) | syscall/IRET | state/logic | B | [FreeBSD-SA-15:21](https://www.freebsd.org/security/advisories/FreeBSD-SA-15:21.amd64.asc) | [Metasploit intel_sysret_priv_esc](https://github.com/rapid7/metasploit-framework/blob/master/modules/exploits/freebsd/local/intel_sysret_priv_esc.rb)（9.3/10.1 amd64） |

| F07 | [CVE-2014-0998](https://nvd.nist.gov/vuln/detail/CVE-2014-0998) | ioctl/vt | integer → OOB | B | [FreeBSD-EN-15:01](https://www.freebsd.org/security/advisories/FreeBSD-EN-15:01.vt.asc) | [fulldisclosure CORE-2015-0003](http://seclists.org/fulldisclosure/2015/Jan/107)（含 VT_WAITACTIVE PoC） |

| F08 | [CVE-2023-3494](https://nvd.nist.gov/vuln/detail/CVE-2023-3494) | hypervisor/bhyve | heap overflow | B | [FreeBSD-SA-23:07](https://www.freebsd.org/security/advisories/FreeBSD-SA-23:07.bhyve.asc) | 恶意 guest 逃逸至宿主机 bhyve 进程（通常 root） |



---



## System services（4）



| ID | CVE | 组件 | 漏洞类型 | 复现 | 权威来源 | 公开 PoC |

|----|-----|------|----------|------|----------|----------|

| S01 | [CVE-2021-4034](https://nvd.nist.gov/vuln/detail/CVE-2021-4034) | polkit pkexec | heap overflow | A | [GitHub Security Lab](https://securitylab.github.com/advisories/GHSL-2021-034-polkit/) | [berdav/CVE-2021-4034](https://github.com/berdav/CVE-2021-4034) |

| S02 | [CVE-2021-3156](https://nvd.nist.gov/vuln/detail/CVE-2021-3156) | sudo | heap overflow | A | [Qualys Baron Samedit](https://www.qualys.com/2021/01/26/cve-2021-3156/baron-samedit-heap-based-overflow-sudo.txt) | [blasty/CVE-2021-3156](https://github.com/blasty/CVE-2021-3156) |

| S03 | [CVE-2021-3560](https://nvd.nist.gov/vuln/detail/CVE-2021-3560) | polkit | race/TOCTOU | A | [GitHub Security Lab](https://securitylab.github.com/advisories/GHSL-2021-074-polkit/) | [secnigma/CVE-2021-3560-Polkit-Privilege-Esclation](https://github.com/secnigma/CVE-2021-3560-Polkit-Privilege-Esclation) |

| S04 | [CVE-2021-44142](https://www.samba.org/samba/security/CVE-2021-44142.html) | Samba vfs_fruit | OOB R/W | A | [Samba 官方公告](https://www.samba.org/samba/security/CVE-2021-44142.html) | [gist PoC](https://gist.github.com/0xsha/0859033e1777490576923a27fbcd23ac) |



---



## Parser / libs（4）



| ID | CVE | 组件 | 漏洞类型 | 复现 | 权威来源 | 公开 PoC |

|----|-----|------|----------|------|----------|----------|

| P01 | [CVE-2022-40303](https://nvd.nist.gov/vuln/detail/CVE-2022-40303) | libxml2 | integer overflow | B | [oss-security](https://www.openwall.com/lists/oss-security/2022/10/20/8) | [Packetstorm 169825](https://packetstormsecurity.com/files/169825/)（`xmlParseNameComplex` + `--huge`） |

| P02 | [CVE-2020-24977](https://nvd.nist.gov/vuln/detail/CVE-2020-24977) | libxml2 | OOB read | B | [Red Hat Bugzilla 1877788](https://bugzilla.redhat.com/show_bug.cgi?id=1877788) | `xmlEncodeEntitiesInternal`（entities.c）；需 libxml2 2.9.10 + 自备畸形实体样本触发 |

| P03 | [CVE-2023-45853](https://nvd.nist.gov/vuln/detail/CVE-2023-45853) | zlib MiniZip | integer overflow → heap OOB | B | [oss-security](https://www.openwall.com/lists/oss-security/2023/10/20/9) | [Exploit-DB 52181](https://www.exploit-db.com/exploits/52181) |

| P04 | [CVE-2022-3602](https://nvd.nist.gov/vuln/detail/CVE-2022-3602) | OpenSSL | stack buffer overflow | B | [OpenSSL 安全公告](https://www.openssl.org/news/secadv/20221101.txt) | [eatscrayon/CVE-2022-3602-poc](https://github.com/eatscrayon/CVE-2022-3602-poc)（多为 DoS；RCE 需特制证书链） |
