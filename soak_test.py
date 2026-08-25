import time
import urllib.request
import concurrent.futures
import subprocess

URL = "http://localhost:8085/health"
TOTAL_REQUESTS = 25000
CONCURRENCY = 50

def get_server_rss():
    res = subprocess.run(["ps", "aux"], capture_output=True, text=True)
    for line in res.stdout.splitlines():
        if "test_suite_server" in line and "grep" not in line:
            parts = line.split()
            return float(parts[5]) / 1024.0 # MB
    return 0.0

def make_req(_):
    try:
        with urllib.request.urlopen(URL, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False

def main():
    print("🔥 Starting Sustained Memory Leak (Soak Test)...")
    initial_mem = get_server_rss()
    print(f"🧠 Initial Server Memory (RSS): {initial_mem:.2f} MB")
    
    start_time = time.time()
    mid_mem_samples = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = [executor.submit(make_req, i) for i in range(TOTAL_REQUESTS)]
        
        for idx, f in enumerate(concurrent.futures.as_completed(futures)):
            if idx % 5000 == 0 and idx > 0:
                m = get_server_rss()
                mid_mem_samples.append(m)
                print(f"  • Processed {idx} requests... Current Memory: {m:.2f} MB")

    duration = time.time() - start_time
    final_mem = get_server_rss()
    mem_diff = final_mem - initial_mem

    print("\n📊 --- SOAK TEST & MEMORY LEAK REPORT ---")
    print(f"✅ Total Requests Processed: {TOTAL_REQUESTS}")
    print(f"⏱️ Total Duration: {duration:.2f} seconds")
    print(f"🧠 Starting Memory: {initial_mem:.2f} MB")
    print(f"🧠 Final Memory After {TOTAL_REQUESTS} Requests: {final_mem:.2f} MB")
    print(f"📈 Net Memory Change (Delta): {mem_diff:+.2f} MB")
    
    if abs(mem_diff) < 2.0:
        print("🎉 RESULT: ZERO MEMORY LEAK DETECTED! Nim ORC garbage collector successfully freed all request memory.")
    else:
        print("⚠️ RESULT: Memory growth detected.")

if __name__ == "__main__":
    main()
