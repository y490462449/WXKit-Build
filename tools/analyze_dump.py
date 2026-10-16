#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
分析 WXKit 运行时导出的 wxkit-classes.txt，找出可用的 hook 目标。

用法：
    python tools/analyze_dump.py wxkit-classes.txt
    python tools/analyze_dump.py wxkit-classes.txt --keyword OnAddMsg

输出：
    1. 消息收发回调候选（用来替换 WXKBridge.m 里的 WXKIncomingMessageSelectors）
    2. 发消息方法候选（WXKSendMsgSelectors / WXKSendTextSelectors）
    3. 撤回、服务定位、自身账号相关候选
把输出贴给维护者，就能把候选名收敛成你那一版微信的真实名字。
"""

import argparse
import re
import sys
from collections import defaultdict

RULES = [
    ("新消息回调", ["OnAddMsg", "onAddMsg", "AddMsg:"]),
    ("发消息方法", ["SendMsg:", "AsyncSendMsg", "SendText", "sendText", "SendMessage"]),
    ("撤回", ["Revoke", "revoke", "RevokeMsg"]),
    ("服务定位", ["getService", "defaultCenter", "sharedInstance"]),
    ("自身账号", ["getSelfContact", "getMyContact", "getSelf", "SelfContact"]),
    ("会话/联系人", ["Session", "Contact", "Chatroom"]),
]


def parse(path):
    classes = []
    current = None
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.rstrip("\n")
            match = re.match(r"^=== (\S+) \(super=(\S+)\) ===$", line)
            if match:
                current = {"name": match.group(1), "super": match.group(2), "methods": []}
                classes.append(current)
                continue
            if current is None:
                continue
            method = re.match(r"^\s+([+-]) (\S+)\s*(.*)$", line)
            if method:
                current["methods"].append(
                    {"kind": method.group(1), "selector": method.group(2), "types": method.group(3)}
                )
    return classes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dump", help="wxkit-classes.txt 路径")
    parser.add_argument("--keyword", action="append", default=[],
                        help="额外关键字（可多次指定），只列出包含它的类")
    parser.add_argument("--limit", type=int, default=40)
    args = parser.parse_args()

    classes = parse(args.dump)
    if not classes:
        print("没解析到任何类，确认文件是不是 wxkit-classes.txt", file=sys.stderr)
        return 1

    print(f"共解析 {len(classes)} 个类\n")

    for title, keywords in RULES:
        hits = []
        for cls in classes:
            if args.keyword and not any(k in cls["name"] for k in args.keyword):
                continue
            matched = [m for m in cls["methods"]
                       if any(k in m["selector"] for k in keywords)]
            if matched:
                hits.append((cls, matched))
        if not hits:
            continue
        print("=" * 70)
        print(f"# {title}（{len(hits)} 个类命中）")
        print("=" * 70)
        for cls, matched in sorted(hits, key=lambda x: -len(x[1]))[: args.limit]:
            print(f"\n{cls['name']}  (super={cls['super']})")
            for m in matched[:25]:
                print(f"   {m['kind']} {m['selector']}   {m['types']}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
