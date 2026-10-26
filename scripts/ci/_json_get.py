"""从 stdin 读 JSON，按点号路径取值并打印。

用法：python3 _json_get.py data.accessToken
解析失败或路径不存在时打印空串（调用方按缺字段处理）。
"""
import json
import sys


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
    except Exception:
        print("")
        return 0

    cur = data
    for key in path.split("."):
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        elif isinstance(cur, list) and key.isdigit() and int(key) < len(cur):
            cur = cur[int(key)]
        else:
            print("")
            return 0

    if cur is None:
        print("")
    elif isinstance(cur, (dict, list)):
        print(json.dumps(cur, ensure_ascii=False))
    elif isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)
    return 0


if __name__ == "__main__":
    sys.exit(main())
