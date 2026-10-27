import yaml

try:
    with open('docker-compose.scaling.yml', 'r', encoding='utf-8') as f:
        yaml.safe_load(f)
    print('YAML syntax: OK')
except Exception as e:
    print(f'YAML syntax: FAILED - {e}')
