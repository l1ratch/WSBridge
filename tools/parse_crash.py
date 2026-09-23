import json, sys

for path in [
    r"C:\Users\sm171\.dsh\attachments\v1\files\0c\0c25e311afe95060588ecb037b3f65d06b413e0955c06bb8a16942ef15233ca4\WSBridgeTunnel-2026-09-24-011610.ips",
    r"C:\Users\sm171\.dsh\attachments\v1\files\79\79e93eca0a0d3e8d224b82896b7779f114506e5d072daed35a6064119b013c06\WSBridgeTunnel-2026-09-24-011623.ips",
]:
    print(f"\n=== {path.split(chr(92))[-1]} ===")
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().strip().split("\n")
    # First line is header JSON, rest is the crash JSON
    crash = json.loads("\n".join(lines[1:]))
    ft = crash.get("faultingThread", -1)
    print(f"faultingThread: {ft}")
    print(f"exception: {crash.get('exception', {})}")
    
    threads = crash.get("threads", [])
    if ft < len(threads):
        thread = threads[ft]
        frames = thread.get("frames", [])
        print(f"\nFaulting thread frames ({len(frames)}):")
        for i, frame in enumerate(frames[:30]):
            sym = frame.get("symbol", "?")
            img_idx = frame.get("imageIndex", -1)
            offset = frame.get("imageOffset", 0)
            print(f"  {i}: [{img_idx}] {sym} +{offset}")
    
    # Print image names for reference
    images = crash.get("usedImages", [])
    print(f"\nImages:")
    for i, img in enumerate(images[:10]):
        print(f"  [{i}] {img.get('name', '?')}")
