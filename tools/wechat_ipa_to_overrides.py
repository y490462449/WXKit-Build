#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从解密版微信 IPA（或 .app 目录 / 裸 Mach-O / .deb）里提取 Objective-C 类名与方法名，
直接生成 WXKit「候选名覆盖」文本 —— 适配新微信版本用，不需要越狱、不需要反编译器。

背景：REA 在 Windows 上只能把 Mach-O 识别成"iOS arm64 二进制"（原生 provider 要 macOS，
Windows 版 Ghidra 只吃 PE），所以类名/方法名的提取用这个脚本完成。

用法：
    python tools/wechat_ipa_to_overrides.py WeChat.ipa
    python tools/wechat_ipa_to_overrides.py Payload/WeChat.app/WeChat
    python tools/wechat_ipa_to_overrides.py DPWechatHelper.deb
    python tools/wechat_ipa_to_overrides.py <path> --out overrides.txt
    python tools/wechat_ipa_to_overrides.py <path> --find m_nsContent      # 看某个字符串在哪个段

输出：
    1) 应用信息（bundle id / 版本 / MinimumOSVersion）—— 先确认系统版本能跑这个微信
    2) 各组候选名（收消息回调 / 发消息 / 消息服务类 / 服务总线 / 字段名）
    3) 可直接粘贴到 WXKit 设置的覆盖文本
"""

import argparse
import struct
import sys
import zipfile
import tarfile
import io
import plistlib
import re
from collections import OrderedDict

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF

SECTION_KEYS = ("__objc_classname", "__objc_methname", "__objc_methtype", "__cstring", "__ustring")

# 微信字段名的常见前缀（用于从字符串里挑出 ivar 名候选）
IVAR_RE = re.compile(rb"^m_[A-Za-z0-9_]{2,40}$")


def cstrings(blob, minlen=2):
    out = []
    for piece in blob.split(b"\x00"):
        if len(piece) >= minlen:
            out.append(piece)
    return out


def decode(piece):
    try:
        return piece.decode("utf-8")
    except UnicodeDecodeError:
        return piece.decode("latin-1", "replace")


def parse_macho(data, path_label):
    """返回 (arch, sections{name: bytes}, symtab_names)。只处理 64 位，够用。"""
    if len(data) < 32:
        return None
    magic = struct.unpack_from("<I", data, 0)[0]
    offset = 0
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        # 取第一个 slice 即可（微信 ipa 一般是单架构）
        nfat = struct.unpack_from(">I", data, 4)[0]
        if nfat < 1:
            return None
        if magic == FAT_MAGIC_64:
            offset = struct.unpack_from(">Q", data, 8 + 32)[0]
        else:
            offset = struct.unpack_from(">I", data, 8 + 16)[0]
        magic = struct.unpack_from("<I", data, offset)[0]
    if magic not in (MH_MAGIC_64,):
        return None

    cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<7I", data, offset + 4)
    arch = {0x0100000C: "arm64", 0x01000007: "x86_64", 7: "i386", 12: "arm"}.get(cputype, hex(cputype))
    sections = OrderedDict()
    symtab = None
    off = offset + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            so = off + 72
            for _s in range(nsects):
                sname = data[so: so + 16].split(b"\x00")[0].decode("latin-1")
                ssize = struct.unpack_from("<Q", data, so + 40)[0]
                soff = struct.unpack_from("<I", data, so + 48)[0]
                if sname in SECTION_KEYS or sname.startswith("__objc_") or sname == "__data":
                    sections.setdefault(sname, b"")
                    sections[sname] += data[soff: soff + ssize]
                so += 80
        elif cmd == 0x2:  # LC_SYMTAB
            symtab = struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize

    names = []
    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        strs = data[stroff: stroff + strsize]
        for i in range(nsyms):
            n_strx = struct.unpack_from("<I", data, symoff + i * 16)[0]
            end = strs.find(b"\x00", n_strx)
            if end > n_strx:
                names.append(decode(strs[n_strx:end]))
    return {"arch": arch, "sections": sections, "symbols": names, "path": path_label}


def collect_strings(macho):
    """返回 {段名: [字符串]}，并汇总类名 / selector / ivar 候选。"""
    by_section = OrderedDict()
    classes, selectors, ivars = set(), set(), set()
    for name, blob in macho["sections"].items():
        if not blob:
            continue
        items = [decode(x) for x in cstrings(blob, 2)]
        by_section[name] = items
        if name == "__objc_classname":
            classes |= set(items)
        if name == "__objc_methname":
            selectors |= set(items)
        # 实测：用 NSSelectorFromString / performSelector 的 selector 会落在 __cstring，
        # ivar 名（m_nsContent 之类）落在 __objc_methname，两边都要扫。
        if name in ("__cstring", "__objc_methname"):
            for item in items:
                if re.match(r"^[A-Za-z_][A-Za-z0-9_]*:", item) or re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", item):
                    selectors.add(item)
        for item in items:
            if IVAR_RE.match(item.encode("utf-8", "ignore")):
                ivars.add(item)
    for sym in macho["symbols"]:
        if sym.startswith("_OBJC_CLASS_$_"):
            classes.add(sym[len("_OBJC_CLASS_$_"):])
        elif sym.startswith("_OBJC_METACLASS_$_"):
            classes.add(sym[len("_OBJC_METACLASS_$_"):])
    return by_section, classes, selectors, ivars


def looks_like_app_class(name):
    for prefix in ("NS", "UI", "WK", "CA", "CG", "OS_", "_", "Swift", "Web", "__"):
        if name.startswith(prefix):
            return False
    return True


def pick(classes, keywords):
    out = [c for c in classes if looks_like_app_class(c) and any(k in c for k in keywords)]
    return sorted(out)


def pick_selectors(selectors, keywords, arity=None):
    out = []
    for sel in selectors:
        if not any(k in sel for k in keywords):
            continue
        if arity is not None and sel.count(":") != arity:
            continue
        out.append(sel)
    return sorted(out)


def candidates(macho):
    by_section, classes, selectors, ivars = collect_strings(macho)
    result = OrderedDict()
    result["msgclass"] = pick(classes, ["Message", "Msg"])[:40]
    result["servicecenter"] = pick(classes, ["ServiceCenter", "ServiceMgr"])[:20]
    result["contactclass"] = pick(classes, ["ContactMgr", "ContactService", "ContactLogic"])[:20]
    result["incoming"] = pick_selectors(selectors, ["MsgWrap"], arity=2)[:40]
    if not result["incoming"]:
        result["incoming"] = pick_selectors(selectors, ["OnAddMsg", "AddMsg"], arity=2)[:40]
    result["sendmsg"] = pick_selectors(selectors, ["SendMsg"], arity=1)[:40]
    result["sendtext"] = pick_selectors(selectors, ["SendText"], arity=2)[:40]
    field_targets = {
        "content": ["m_nsContent", "m_nsMsgContent"],
        "type": ["m_uiMessageType", "m_nMessageType"],
        "from": ["m_nsFromUsr", "m_nsFromUserName"],
        "to": ["m_nsToUsr", "m_nsToUserName"],
        "svrid": ["m_n64MesSvrID", "m_uiMesSvrID", "m_nMesSvrID"],
        "localid": ["m_uiMesLocalID", "m_nMesLocalID"],
        "msgsource": ["m_nsMsgSource"],
    }
    for key, wanted in field_targets.items():
        hits = [w for w in wanted if w in ivars]
        if hits:
            result[key] = hits
    result["_stats"] = {"classes": len(classes), "selectors": len(selectors), "ivars": len(ivars)}
    result["_sections"] = {k: len(v) for k, v in by_section.items()}
    return result


def override_text(result):
    lines = ["# 由 tools/wechat_ipa_to_overrides.py 生成",
             "# 粘到 WXKit 设置 →「适配（候选名覆盖）」→ 保存 → 点「重试挂载消息回调」",
             ""]
    for key in ("servicecenter", "msgclass", "contactclass", "incoming", "sendmsg", "sendtext",
                "content", "type", "from", "to", "svrid", "localid", "msgsource"):
        values = result.get(key) or []
        if values:
            lines.append("%s = %s" % (key, ", ".join(values)))
    return "\n".join(lines) + "\n"


def read_ipa_members(path):
    """返回 [(成员名, bytes)]，只挑可能含主二进制的成员。"""
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        infos = [n for n in names if n.endswith(".app/Info.plist")]
        payloads = [n for n in names if re.match(r"^Payload/[^/]+\.app/[^/]+$", n)]
        out = []
        for n in infos:
            out.append((n, zf.read(n)))
        for n in payloads:
            out.append((n, zf.read(n)))
        return out


def read_deb_members(path):
    """极简 ar 解析：取出 data.tar.* 并返回其中的文件。"""
    blob = open(path, "rb").read()
    if blob[:8] != b"!<arch>\n":
        return []
    members = []
    pos = 8
    while pos + 60 <= len(blob):
        header = blob[pos: pos + 60]
        name = header[:16].decode("latin-1").strip().rstrip("/")
        size = int(header[48:58].decode("latin-1").strip() or "0")
        body = blob[pos + 60: pos + 60 + size]
        members.append((name, body))
        pos += 60 + size + (size % 2)
    out = []
    for name, body in members:
        if not name.startswith("data.tar"):
            continue
        mode = "r:*"
        try:
            with tarfile.open(fileobj=io.BytesIO(body), mode=mode) as tf:
                for member in tf.getmembers():
                    if member.isfile() and member.size < 400 * 1024 * 1024:
                        out.append((member.name, tf.extractfile(member).read()))
        except Exception as e:  # noqa: BLE001
            print("解析 %s 失败: %s" % (name, e), file=sys.stderr)
    return out


def app_info(plist_bytes):
    try:
        info = plistlib.loads(plist_bytes)
    except Exception:  # noqa: BLE001
        return {}
    return {
        "bundle_id": info.get("CFBundleIdentifier"),
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "min_os": info.get("MinimumOSVersion"),
        "executable": info.get("CFBundleExecutable"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="解密版微信 IPA / .app 目录里的二进制 / .deb / 裸 Mach-O")
    parser.add_argument("--out", help="覆盖文本输出路径（默认打印到屏幕）")
    parser.add_argument("--find", help="在段里搜索某个字符串（排查字段名/类名用）")
    args = parser.parse_args()

    members = []
    lower = args.path.lower()
    try:
        if lower.endswith(".ipa") or lower.endswith(".zip"):
            members = read_ipa_members(args.path)
        elif lower.endswith(".deb"):
            members = read_deb_members(args.path)
    except Exception as e:  # noqa: BLE001
        print("读取归档失败: %s" % e, file=sys.stderr)
        return 1
    if not members:
        with open(args.path, "rb") as fh:
            members = [(args.path, fh.read())]

    info = {}
    machos = []
    for name, blob in members:
        if name.endswith("Info.plist"):
            info = app_info(blob) or info
            continue
        parsed = parse_macho(blob, name)
        if parsed:
            machos.append((name, parsed))

    if info:
        print("== 应用信息 ==")
        for key in ("bundle_id", "version", "build", "min_os", "executable"):
            if info.get(key):
                print("  %-10s %s" % (key, info[key]))
        min_os = info.get("min_os") or ""
        if min_os and min_os not in ("", "0.0"):
            print("  → 你的系统版本必须 >= %s（iOS 15.4.1 只能装 MinimumOSVersion <= 15.4.1 的包）" % min_os)
        print()

    if not machos:
        print("没找到 64 位 Mach-O。注意：App Store 下载的加密二进制里 __TEXT 是密文，"
              "类名/方法名会是乱码 —— 请用解密后的 IPA。", file=sys.stderr)
        return 1

    for name, macho in machos:
        print("== 二进制 ==")
        print("  %s  (%s)" % (name, macho["arch"]))
        if args.find:
            target = args.find.encode("utf-8")
            for section, blob in macho["sections"].items():
                if target in blob:
                    print("  字符串 %r 出现在段 %s" % (args.find, section))
            print()
            continue
        result = candidates(macho)
        stats = result["_stats"]
        print("  段统计: %s" % result["_sections"])
        print("  抽到: 类 %d / selector %d / 疑似字段名 %d" % (
            stats["classes"], stats["selectors"], stats["ivars"]))
        print()
        for group, title in (("incoming", "收消息回调（最关键）"), ("msgclass", "消息服务类"),
                             ("sendmsg", "发消息（wrap）"), ("sendtext", "发消息（文本）"),
                             ("servicecenter", "服务总线"), ("contactclass", "通讯录服务")):
            values = result.get(group) or []
            print("-- %s（%d）" % (title, len(values)))
            for v in values[:25]:
                print("   %s" % v)
            if not values:
                print("   （没抽到）")
            print()
        fields = {k: v for k, v in result.items()
                  if k in ("content", "type", "from", "to", "svrid", "localid", "msgsource") and v}
        print("-- 字段名命中（%d）" % len(fields))
        for k, v in fields.items():
            print("   %s = %s" % (k, ", ".join(v)))
        if not fields:
            print("   （没抽到；字段名在 ivar 结构里，若没有符号表就需要用手机上的"
                  "「新消息字段转储」日志确认，见 docs/HOOKS.md）")
        print()

        text = override_text(result)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as fh:
                fh.write(text)
            print("已写出覆盖文本: %s" % args.out)
        else:
            print("== 可粘贴的覆盖文本 ==")
            print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
