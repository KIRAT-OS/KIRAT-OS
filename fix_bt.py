with open('activation-checklist.sh', 'rb') as f:
    data = f.read()

# Find the problematic sequence: .` |
old = b' _ \\_  _| _ | .` |"'
new = b' _ \\_  _| _ | .\' |"'

if old in data:
    data = data.replace(old, new)
    print("Fixed backtick issue (pattern 1)")
else:
    # Try with single quote echo
    old2 = b"| _ | .` |'"
    new2 = b"| _ | .' |'"
    if old2 in data:
        data = data.replace(old2, new2)
        print("Fixed backtick issue (pattern 2)")
    else:
        print("Pattern not found")

with open('activation-checklist.sh', 'wb') as f:
    f.write(data)

print("Done")
