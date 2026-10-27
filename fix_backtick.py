# -*- coding: utf-8 -*-
with open('activation-checklist.sh', 'r', encoding='utf-8') as f:
    content = f.read()

# Find and replace the problematic line 491
lines = content.split('\n')
for i, line in enumerate(lines):
    if '._  _| _ | .' in line and '`' in line:
        print(f"Found at line {i+1}: {line}")
        lines[i] = line.replace('.` |', ".' |")
        print(f"Fixed to: {lines[i]}")

with open('activation-checklist.sh', 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))

print("Done")
