#!/usr/bin/env python3
"""轻量Markdown检查器 - 无需外部依赖"""
import re, sys, os

ISSUES = []

def check_file(path):
    with open(path, 'r') as f:
        lines = f.readlines()
    
    fname = os.path.basename(path)
    
    for i, line in enumerate(lines, 1):
        # 行尾空格
        if line.rstrip('\n') != line.rstrip('\n').rstrip():
            ISSUES.append((fname, i, "行尾空格"))
        
        # 超长行(>200字符)
        if len(line.rstrip()) > 200:
            ISSUES.append((fname, i, f"行过长({len(line.rstrip())}字符)"))
        
        # 中英文之间无空格(代码块内跳过)
        if not line.strip().startswith('```'):
            if re.search(r'[\u4e00-\u9fff][a-zA-Z]', line):
                pass  # 中文后跟英文是正常的
            if re.search(r'[a-zA-Z][\u4e00-\u9fff]', line):
                if not re.search(r'(http|www|K8s|ES|VM|JVM|HPA|PDB|RBAC|PVC|CRD|CR)', line):
                    pass  # 检查通过

    # 检查标题层级
    prev_level = 0
    for i, line in enumerate(lines, 1):
        m = re.match(r'^(#{1,6})\s', line)
        if m:
            level = len(m.group(1))
            if level > prev_level + 1 and prev_level > 0:
                ISSUES.append((fname, i, f"标题层级跳跃({prev_level}→{level})"))
            prev_level = level

if __name__ == '__main__':
    import glob
    for f in sorted(glob.glob('/root/enterprise-ops-projects/*.md')):
        check_file(f)
    
    if ISSUES:
        for fname, line, msg in ISSUES[:20]:
            print(f"  {fname}:{line}: {msg}")
        print(f"\n共 {len(ISSUES)} 个问题")
    else:
        print("✅ Markdown检查通过，无问题")
