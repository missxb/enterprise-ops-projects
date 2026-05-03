#!/usr/bin/env python3
"""轻量Markdown检查器 - 无需外部依赖"""
import re, sys, os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)

ISSUES = []

def check_file(path):
    with open(path, 'r') as f:
        lines = f.readlines()
    
    fname = os.path.basename(path)
    
    for i, line in enumerate(lines, 1):
        if line.rstrip('\n') != line.rstrip('\n').rstrip():
            ISSUES.append((fname, i, "行尾空格"))
        if len(line.rstrip()) > 200:
            ISSUES.append((fname, i, f"行过长({len(line.rstrip())}字符)"))

    prev_level = 0
    for i, line in enumerate(lines, 1):
        m = re.match(r'^(#{1,6})\s', line)
        if m:
            level = len(m.group(1))
            if level > prev_level + 2 and prev_level > 0:
                ISSUES.append((fname, i, f"标题层级跳跃({prev_level}→{level})"))
            prev_level = level

if __name__ == '__main__':
    import glob
    for f in sorted(glob.glob(os.path.join(REPO_DIR, '*.md'))):
        check_file(f)
    
    if ISSUES:
        for fname, line, msg in ISSUES[:20]:
            print(f"  {fname}:{line}: {msg}")
        print(f"\n共 {len(ISSUES)} 个问题")
        sys.exit(1)
    else:
        print("✅ Markdown检查通过，无问题")
        sys.exit(0)
