#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
WXKit 源码静态检查（在没有编译器的机器上尽可能提前发现问题）。

检查项：
  1. 括号配平（花括号 / 圆括号 / 方括号）
  2. #import "..." 的本地头文件是否存在
  3. 头文件里 @interface 声明的方法，.m 里是否都有实现
  4. 给「本工程自己的类」发消息时，selector 是否声明过、参数个数是否对得上
     —— 这类错误在真机上表现是 unrecognized selector 崩溃或传参错位崩溃，必须在交付前查出来
  5. WXKxxx(...) 形式的 C 函数是否有声明
用法： python tools/check_sources.py [项目根目录]
退出码：0 = 无问题
"""

import pathlib
import re
import sys

NSOBJECT_SELECTORS = {
    "alloc", "init", "new", "class", "self", "description", "debugDescription",
    "respondsToSelector:", "conformsToProtocol:", "isKindOfClass:", "isMemberOfClass:",
    "performSelector:", "performSelector:withObject:", "performSelector:withObject:withObject:",
    "methodForSelector:", "release", "retain", "autorelease", "copy", "mutableCopy",
    "isEqual:", "hash", "valueForKey:", "setValue:forKey:", "addObserver:selector:name:object:",
    "string", "array", "dictionary", "set", "data", "numberWithBool:", "numberWithInt:",
    "numberWithInteger:", "numberWithDouble:", "numberWithLongLong:", "stringWithFormat:",
    "stringWithUTF8String:", "stringWithString:", "arrayWithArray:", "dictionaryWithDictionary:",
}

SIMPLE_SELECTOR = re.compile(r"^[A-Za-z_]\w*$")

# 中文字符（含全角标点）。正常只出现在字符串字面量和注释里；
# 去注释去字符串后还有中文，基本就是引号写错导致字符串提前结束。
CJK = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")


def cjk_outside_string_issues(path, code):
    issues = []
    lines = code.split("\n")
    for match in CJK.finditer(code):
        line_no = code[:match.start()].count("\n") + 1
        raw_line = lines[line_no - 1] if line_no - 1 < len(lines) else ""
        stripped = raw_line.strip()
        if stripped.startswith("#"):
            continue   # #pragma mark 之类允许中文
        issues.append(f"{path.name}:{line_no} 字符串/注释之外出现中文字符（常见原因：引号写错），"
                      f"该行: {stripped[:60]}")
        if len(issues) >= 3:
            break
    return issues


def strip_comments_and_strings(text):
    """返回 (去掉注释和字符串的代码, 原文本)。字符串替换成等长空格以便定位。"""
    out = []
    i, n = 0, len(text)
    state = None
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state is None:
            if c == "/" and nxt == "/":
                state = "line"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block"
                i += 2
                continue
            if c == '"' or c == "'":
                state = "str" if c == '"' else "chr"
                out.append(" ")
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if state == "line":
            if c == "\n":
                state = None
                out.append(c)
            i += 1
            continue
        if state == "block":
            if c == "*" and nxt == "/":
                state = None
                i += 2
                continue
            i += 1
            continue
        # 字符串内部
        if c == "\\":
            i += 2
            continue
        if (state == "str" and c == '"') or (state == "chr" and c == "'"):
            state = None
        i += 1
    return "".join(out)


def balance_issues(path, code):
    issues = []
    for open_ch, close_ch, label in (("{", "}", "花括号"), ("(", ")", "圆括号"), ("[", "]", "方括号")):
        delta = code.count(open_ch) - code.count(close_ch)
        if delta:
            issues.append(f"{path.name}: {label}不配平 {delta:+d}")
    return issues


def collect_method_list(code):
    """按出现顺序返回 [(selector, arity)]，重复定义要能被看见（dict 会吃掉重复项）。"""
    methods = []
    lines = code.split("\n")
    buffer = ""
    collecting = False
    for line in lines:
        stripped = line.strip()
        if not collecting:
            if re.match(r"^[+-]\s*\(", stripped) or re.match(r"^[+-]\s*[A-Za-z_]", stripped):
                collecting = True
                buffer = stripped
            else:
                continue
        else:
            buffer += " " + stripped
        if ";" in buffer or "{" in buffer:
            selector, arity = selector_from_declaration(buffer)
            if selector:
                methods.append((selector, arity))
            collecting = False
            buffer = ""
    return methods


def collect_methods(text, code):
    """返回 {selector: arity}，来自 @interface / @implementation 中的方法声明与实现。"""
    return dict(collect_method_list(code))


def strip_parens(part):
    out = []
    depth = 0
    for ch in part:
        if ch == "(":
            depth += 1
            continue
        if ch == ")":
            depth = max(0, depth - 1)
            continue
        if depth == 0:
            out.append(ch)
    return "".join(out)


def selector_from_declaration(declaration):
    # 截断到方法体/分号之前，避免把函数体里的关键字也当成 selector 段
    cut = len(declaration)
    for mark in ("{", ";"):
        idx = declaration.find(mark)
        if idx != -1:
            cut = min(cut, idx)
    body = strip_parens(declaration[:cut]).lstrip("+-").strip()
    parts = re.findall(r"([A-Za-z_]\w*)\s*:", body)
    if parts:
        return "".join(p + ":" for p in parts), len(parts)
    match = re.match(r"([A-Za-z_]\w*)", body)
    if match:
        return match.group(1), 0
    return None, 0


def find_interfaces(text):
    """返回 {类名: 方法字典}，来自所有 @interface 块（含类扩展）。"""
    result = {}
    for match in re.finditer(r"@interface\s+(WXK\w+)", text):
        name = match.group(1)
        end = text.find("@end", match.end())
        if end == -1:
            continue
        block = text[match.end():end]
        methods = collect_methods(text, strip_comments_and_strings(block))
        result.setdefault(name, {}).update(methods)
    return result


def find_implementations(text):
    result = {}
    for match in re.finditer(r"@implementation\s+(WXK\w+)", text):
        name = match.group(1)
        end = text.find("@end", match.end())
        if end == -1:
            continue
        block = text[match.end():end]
        methods = collect_methods(text, strip_comments_and_strings(block))
        result.setdefault(name, {}).update(methods)
    return result


def scan_message_sends(code, own_classes):
    """找出 [WXKXxx sel:...] / [self sel:...] 形式的消息发送，返回 (receiver, selector, arity, offset)。"""
    results = []
    for match in re.finditer(r"\[(WXK\w+|self|super)(?=\s)", code):
        start = match.end()
        depth = 1
        i = start
        n = len(code)
        paren = 0
        while i < n:
            ch = code[i]
            if ch == "(":
                paren += 1
            elif ch == ")":
                paren = max(0, paren - 1)
            elif ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if i >= n:
            continue
        inner = code[start:i]
        selector, arity = selector_from_expression(inner)
        if selector:
            results.append((match.group(1), selector, arity, match.start()))
    return results


def selector_from_expression(inner):
    """从消息表达式中提取 selector 链（只取顶层、括号与外层方括号之外的标识符:）。"""
    parts = []
    i, n = 0, len(inner)
    depth_paren = 0
    rest = inner
    # 逐段匹配：标识符 + 可选空格 + 冒号 + 参数（跳过平衡的括号/方括号/引号内容）
    while i < n:
        match = re.match(r"\s*([A-Za-z_]\w*)\s*:", rest[i:])
        if not match:
            break
        parts.append(match.group(1))
        i += match.end()
        # 跳过参数
        skip = 0
        depth = 0
        while i < n:
            ch = rest[i]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            if depth == 0 and ch == " ":
                # 可能是下一个 selector 段的开始
                look = re.match(r"\s*[A-Za-z_]\w*\s*:", rest[i:])
                if look:
                    break
            i += 1
        if i >= n:
            break
    if parts:
        return "".join(p + ":" for p in parts), len(parts)
    match = re.match(r"\s*([A-Za-z_]\w*)", inner)
    if match:
        return match.group(1), 0
    return None, 0


def block_end_issues(path, code):
    """@interface / @implementation 的个数必须与 @end 相同（缺 @end 是硬错误）。"""
    opens = len(re.findall(r"@(?:interface|implementation)\b", code))
    ends = len(re.findall(r"@end\b", code))
    if opens != ends:
        return [f"{path.name}: @interface/@implementation {opens} 个但 @end {ends} 个（缺或多 @end）"]
    return []


def duplicate_method_issues(path, code):
    """同一个 @implementation 里重复定义同一个 selector 是硬错误。"""
    issues = []
    for match in re.finditer(r"@implementation\s+(WXK\w+)", code):
        name = match.group(1)
        end = code.find("@end", match.end())
        if end == -1:
            continue
        block = code[match.end():end]
        seen = set()
        for sel, _arity in collect_method_list(block):
            if sel in seen:
                issues.append(f"{path.name}: @implementation {name} 里重复定义了 {sel}")
            seen.add(sel)
    return issues


def parse_c_function_arity(text):
    """解析 C 函数参数个数：名字 -> (arity, is_variadic)。

    关键点：必须只在"声明/定义"上下文里取签名（行首、带返回类型），
    否则 `WXKLog(@"...")` 这种调用会被误当成声明 —— 字符串在预处理阶段已被剥离，
    调用看起来和声明一模一样。
    """
    result = {}
    type_prefix = (r"(?:static\s+)?(?:void|id|BOOL|instancetype|Class|SEL|IMP|NSInteger|NSUInteger|"
                   r"CGFloat|NSTimeInterval|NSString|NSArray|NSDictionary|NSMutableArray|"
                   r"NSMutableDictionary|NSMutableString|WXK\w+)")
    pattern = re.compile(
        type_prefix + r"[\w\s\*<>]*?\b(WXK[A-Z]\w+)\s*\(([^;{)]*)\)\s*"
        r"(?:NS_FORMAT_FUNCTION\([^)]*\))?\s*[;{]")
    for match in pattern.finditer(text):
        name, params = match.group(1), match.group(2).strip()
        if not params or params == "void":
            result[name] = (0, False)
            continue
        variadic = "..." in params
        clean = params.replace("...", "").strip()
        commas = clean.count(",")
        arity = commas + 1 if clean else 0
        if variadic:
            arity = max(0, arity - 1)
        result[name] = (arity, variadic)
    return result


def count_call_args(code, open_index):
    """从 '(' 位置开始数顶层逗号，返回 (参数个数, 结束位置)；空参数算 0 个。"""
    depth = 0
    i = open_index
    n = len(code)
    commas = 0
    has_content = False
    while i < n:
        ch = code[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return (0 if not has_content else commas + 1), i
        elif ch == "," and depth == 1:
            commas += 1
        elif depth == 1 and not ch.isspace() and ch not in "([{":
            has_content = True
        i += 1
    return -1, n


def c_call_arity_issues(path, code, arity_table, definition_offsets):
    issues = []
    for match in re.finditer(r"\b(WXK[A-Z]\w+)\s*\(", code):
        name = match.group(1)
        if name not in arity_table:
            continue
        if match.start() in definition_offsets.get(name, ()):
            continue
        open_index = code.index("(", match.start())
        args, _ = count_call_args(code, open_index)
        if args < 0:
            continue   # 括号不配平，交给 balance 检查
        arity, variadic = arity_table[name]
        if variadic:
            if args < arity:
                issues.append(f"{path.name}: {name} 至少需要 {arity} 个参数，这里只传了 {args} 个")
        elif args != arity:
            issues.append(f"{path.name}: {name} 需要 {arity} 个参数，这里传了 {args} 个")
    return issues


def resolve_root(argument):
    """允许在仓库根目录或 WXKit 目录下运行：找不到 src 时自动向下找一层。"""
    root = pathlib.Path(argument)
    if (root / "src").is_dir():
        return root
    for candidate in sorted(root.glob("*/src")):
        return candidate.parent
    return root


SOURCE_DIRS = ("src", "probe")


def gather_files(root):
    """src/ 与 probe/ 下的 .m/.h 都要查（探针是独立产物，但同样不能有低级错误）。"""
    headers, sources = [], []
    for name in SOURCE_DIRS:
        base = root / name
        if not base.is_dir():
            continue
        headers += sorted(base.rglob("*.h"))
        sources += sorted(base.rglob("*.m"))
    return headers, sources


def main():
    root = resolve_root(sys.argv[1] if len(sys.argv) > 1 else r"E:\DEB\WXKit")
    src = root / "src"
    if not src.is_dir():
        print(f"找不到源码目录：{src}")
        return 1
    headers, sources = gather_files(root)
    all_files = headers + sources
    header_names = {p.name for p in headers}

    issues = []
    codes = {}
    texts = {}
    for path in all_files:
        raw = path.read_text(encoding="utf-8")
        code = strip_comments_and_strings(raw)
        texts[path] = raw
        codes[path] = code
        issues += balance_issues(path, code)
        issues += cjk_outside_string_issues(path, code)
        issues += block_end_issues(path, code)
        issues += duplicate_method_issues(path, code)
        for match in re.finditer(r'#import\s+"([^"]+)"', raw):
            if match.group(1) not in header_names:
                issues.append(f"{path.name}: 找不到头文件 {match.group(1)}")

    declared = {}
    implemented = {}
    # 声明也要看 .m：私有方法通常写成 @interface X () … @end，只查头文件会漏掉它们
    for path in headers + sources:
        for name, methods in find_interfaces(texts[path]).items():
            declared.setdefault(name, {}).update(methods)
    for path in sources:
        for name, methods in find_implementations(texts[path]).items():
            implemented.setdefault(name, {}).update(methods)

    for name, methods in declared.items():
        for selector in methods:
            if selector not in implemented.get(name, {}):
                issues.append(f"{name}: 声明了 {selector} 但没有实现")

    own_classes = set(declared) | set(implemented)
    declared_c_functions = set()
    for path in headers:
        declared_c_functions |= set(re.findall(r"\b(WXK[A-Z]\w+)\s*\(", texts[path]))
    defined_c_functions = set()
    for path in sources:
        # 函数定义（含带 __attribute__ 前缀的），例如： static void WXKEntry(void) {
        defined_c_functions |= set(
            re.findall(r"\b(WXK[A-Z]\w+)\s*\([^)\n]*\)\s*\{", texts[path]))

    # C 函数参数个数：自家函数调用传错参数个数是硬错误
    arity_table = {}
    for path in headers + sources:
        arity_table.update(parse_c_function_arity(codes[path]))

    scanned_messages = 0
    for path in sources:
        code = codes[path]
        definition_offsets = {}
        for match in re.finditer(r"\b(WXK[A-Z]\w+)\s*\([^)\n]*\)\s*\{", code):
            definition_offsets.setdefault(match.group(1), set()).add(match.start())
        issues += c_call_arity_issues(path, code, arity_table, definition_offsets)
        for receiver, selector, arity, offset in scan_message_sends(code, own_classes):
            if receiver in ("self", "super"):
                continue
            scanned_messages += 1
            target = receiver
            # 注意：类可能只声明在 .m 里（如 WXKProbeDetail / WXKRow），
            # 所以"已知方法"要同时取头文件声明和 .m 实现，否则这些类根本不会被检查。
            known = {}
            known.update(declared.get(target, {}))
            known.update(implemented.get(target, {}))
            if not known:
                continue
            if selector in NSOBJECT_SELECTORS:
                continue
            if selector not in known:
                line = code[:offset].count("\n") + 1
                issues.append(f"{path.name}:{line} 给 {target} 发了未声明的 selector {selector}")
                continue
            if known[selector] != arity:
                line = code[:offset].count("\n") + 1
                issues.append(
                    f"{path.name}:{line} {target} 的 {selector} 参数个数不符：实发 {arity}，声明 {known[selector]}")

        for match in re.finditer(r"\b(WXK[A-Z]\w+)\s*\(", code):
            name = match.group(1)
            if name in declared_c_functions or name in defined_c_functions or name in own_classes:
                continue
            if name.startswith("WXKRowKind") or name.startswith("WXKKey"):
                continue
            line = code[:match.start()].count("\n") + 1
            issues.append(f"{path.name}:{line} 调用了未声明的 C 函数 {name}")

    for issue in issues:
        print(issue)
    print(f"检查文件 {len(all_files)} 个，类 {len(own_classes)} 个，"
          f"扫描到类消息 {scanned_messages} 处，问题 {len(issues)} 处")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
