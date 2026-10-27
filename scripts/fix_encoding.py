with open("kirat-os-server/scripts/fix_tls.py", "r") as f:
    lines = f.readlines()

lines[85] = 'with open(PATH, "r", encoding="utf-8") as f:\n'
lines[100] = 'with open(PATH, "w", encoding="utf-8") as f:\n'

with open("kirat-os-server/scripts/fix_tls.py", "w") as f:
    f.writelines(lines)

print("Fixed encoding lines")
