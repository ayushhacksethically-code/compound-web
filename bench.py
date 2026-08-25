import asyncio
import time
import urllib.request
import concurrent.futures
import subprocess

URL = "http://localhost:8085/benchmark"
TOTAL_REQUESTS = 10000
CONCURRENCY = 50

def make_request(_):
    try:
        with urllib.request.urlopen(URL, timeout=5) as response:
            return response.status == 200
    except Exception:
        return False

def main():
    print(f"⚡ Firing {TOTAL_REQUESTS} requests across {CONCURRENCY} concurrent threads...")
    start_time = time.time()
    
    success_count = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        results = list(executor.map(make_request, range(TOTAL_REQUESTS)))
        success_count = sum(1 for r in results if r)
        
    duration = time.time() - start_time
    rps = success_count / duration
    avg_latency_ms = (duration / TOTAL_REQUESTS) * CONCURRENCY * 1000.0

    # Get memory usage of test_suite_server
    res = subprocess.run(["ps", "aux"], capture_output=True, text=True)
    mem_kb = 0
    for line in res.stdout.splitlines():
        if "test_suite_server" in line and "grep" not in line:
            parts = line.split()
            mem_kb = int(parts[5]) # RSS memory in KB
            break
            
    mem_mb = mem_kb / 1024.0

    print("\n📊 --- BENCHMARK RESULTS ---")
    print(f"✅ Total Requests Handled: {success_count} / {TOTAL_REQUESTS}")
    print(f"⏱️ Total Time Taken: {duration:.3f} seconds")
    print(f"⚡ Requests Per Second (RPS): {rps:.2f} req/sec")
    print(f"⏳ Concurrency-adjusted Latency: {avg_latency_ms:.2f} ms")
    print(f"🧠 Server Memory Footprint (RSS): {mem_mb:.2f} MB")

if __name__ == "__main__":
    main()
