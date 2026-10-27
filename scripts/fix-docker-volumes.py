with open('docker-compose.scaling.yml', 'r', encoding='utf-8') as f:
    lines = f.readlines()

# Find all lines that are EXACTLY "volumes:" with NO indentation (top-level only)
volume_indices = [i for i, line in enumerate(lines) if line == 'volumes:\n']

print(f"[INFO] Found {len(volume_indices)} top-level 'volumes:' blocks at lines: {[i+1 for i in volume_indices]}")

if len(volume_indices) == 2:
    first_idx = volume_indices[0]
    second_idx = volume_indices[1]
    
    # Collect entries from the second volumes block
    second_entries = []
    i = second_idx + 1
    while i < len(lines) and (lines[i].strip() == '' or lines[i].startswith('  ')):
        if lines[i].strip():
            second_entries.append(lines[i])
        i += 1
    
    # Remove the second volumes block (from second_idx to i-1)
    new_lines = lines[:second_idx] + lines[i:]
    
    # Find end of first block entries
    j = first_idx + 1
    while j < len(new_lines) and (new_lines[j].strip() == '' or new_lines[j].startswith('  ')):
        if new_lines[j].strip() == '':
            break
        j += 1
    
    # Insert the second block entries at position j
    final_lines = new_lines[:j] + second_entries + new_lines[j:]
    
    with open('docker-compose.scaling.yml', 'w', encoding='utf-8') as f:
        f.writelines(final_lines)
    
    print(f"[FIXED] Merged duplicate volumes blocks.")
    print(f"[INFO] Added entries: {[e.strip() for e in second_entries]}")
else:
    print(f"[INFO] Found {len(volume_indices)} top-level 'volumes:' blocks. {'OK' if len(volume_indices) == 1 else 'Unexpected count.'}")
