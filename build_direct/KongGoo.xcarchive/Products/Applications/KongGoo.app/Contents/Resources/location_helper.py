#!/usr/bin/env python3
"""
Ultra-stable GPS location simulator for iOS devices.

Multiple connection strategies with automatic failover, persistent connections,
heartbeat monitoring, hot-swap connection refresh, and exponential backoff.

Designed to match or exceed the stability of commercial GPS simulators like iAnyGo.

Usage: python3 location_helper.py [UDID]

Protocol (stdin/stdout, line-based):
  -> "lat lon"      (send location)
  -> "PING"         (health check)
  -> "QUIT"         (graceful shutdown)
  -> "RECONNECT"    (force reconnection)
  -> "STATUS"       (get connection status)
  <- "READY"        (API connection established)
  <- "READY:CLI"    (fallback to CLI mode)
  <- "OK"           (location sent successfully)
  <- "ERR:..."      (error message)
  <- "PONG"         (health check response)
  <- "STATUS:..."   (connection status)
"""

import sys
import subprocess
import signal
import time
import struct
import threading

# Ensure unbuffered stdout
sys.stdout.reconfigure(line_buffering=True)

# ─── Connection Strategy Classes ─────────────────────────────────────────────


class DVTLocationService:
    """
    Strategy 1 (Primary): Use DVT Instruments channel.
    Persistent multiplexed channel — fastest and most reliable for iOS 17+.
    """

    NAME = "DVT"

    def __init__(self, rsd):
        self.rsd = rsd
        self.dvt = None
        self.loc = None
        self._lock = threading.Lock()

    def connect(self):
        from pymobiledevice3.services.dvt.dvt_secure_socket_proxy import (
            DvtSecureSocketProxyService,
        )
        from pymobiledevice3.services.dvt.instruments.location_simulation import (
            LocationSimulation,
        )

        self.disconnect()
        self.dvt = DvtSecureSocketProxyService(self.rsd)
        self.dvt.__enter__()
        self.loc = LocationSimulation(self.dvt)

    def disconnect(self):
        if self.dvt:
            try:
                self.dvt.__exit__(None, None, None)
            except Exception:
                pass
            self.dvt = None
            self.loc = None

    def set(self, lat, lon):
        with self._lock:
            if self.loc is None:
                raise ConnectionError("DVT not connected")
            self.loc.set(lat, lon)

    def clear(self):
        with self._lock:
            if self.loc:
                try:
                    self.loc.clear()
                except Exception:
                    pass


class DirectLocationService:
    """
    Strategy 2 (Secondary): Direct protocol over service connection.
    Opens com.apple.dt.simulatelocation service and speaks raw protocol.
    Simpler than DVT but may not be available on all devices.
    """

    NAME = "Direct"

    def __init__(self, rsd):
        self.rsd = rsd
        self.service = None
        self._lock = threading.Lock()

    def connect(self):
        self.disconnect()
        self.service = self.rsd.start_lockdown_developer_service(
            "com.apple.dt.simulatelocation"
        )

    def disconnect(self):
        if self.service:
            try:
                self.service.close()
            except Exception:
                pass
            self.service = None

    def set(self, lat, lon):
        with self._lock:
            if self.service is None:
                raise ConnectionError("Direct service not connected")
            lat_bytes = str(lat).encode()
            lon_bytes = str(lon).encode()
            self.service.sendall(struct.pack(">I", 0))
            self.service.sendall(struct.pack(">I", len(lat_bytes)) + lat_bytes)
            self.service.sendall(struct.pack(">I", len(lon_bytes)) + lon_bytes)

    def clear(self):
        with self._lock:
            if self.service:
                try:
                    self.service.sendall(struct.pack(">I", 1))
                except Exception:
                    pass


# ─── Main Engine ─────────────────────────────────────────────────────────────


class LocationEngine:
    """
    Manages device connection with multiple strategies, automatic failover,
    heartbeat monitoring, HOT-SWAP connection refresh (zero downtime), and
    exponential backoff reconnection.

    Key feature: Hot-swap refresh builds a new connection BEFORE tearing down
    the old one, eliminating the "gap" that causes location to jump back home.
    """

    # DVT connections tend to drop after ~10-15 minutes of continuous use.
    # Refresh proactively before that happens.
    CONNECTION_REFRESH_INTERVAL = 480  # 8 minutes

    def __init__(self, udid=None):
        self.udid = udid
        self.rsd = None  # RemoteServiceDiscoveryService
        self.service = None  # Active location service
        self.strategy_name = ""  # Current strategy name
        self.connected = False

        # Stats
        self.total_sent = 0
        self.total_errors = 0
        self.consecutive_errors = 0
        self.last_send_time = None
        self.last_lat = 0.0  # Track last position for re-send after reconnect
        self.last_lon = 0.0

        # Reconnection state
        self._reconnect_lock = threading.Lock()
        self._reconnecting = False
        self._backoff = 0.5  # Start with 0.5s backoff
        self._connect_time = None  # When current connection was established

        # Heartbeat
        self._heartbeat_thread = None
        self._heartbeat_stop = threading.Event()

    def connect(self):
        """Establish connection using best available strategy."""
        # Get fresh device reference every time (don't reuse stale RSD)
        try:
            self.rsd = self._get_device()
            if self.rsd is None:
                return False
        except Exception as e:
            _log(f"Device discovery failed: {e}")
            return False

        # Strategy 1: DVT (primary — proven stable in stress tests)
        try:
            svc = DVTLocationService(self.rsd)
            svc.connect()
            # Verify with a test send (use last known position if available)
            test_lat = self.last_lat if self.last_lat != 0.0 else 0.0001
            test_lon = self.last_lon if self.last_lon != 0.0 else 0.0001
            svc.set(test_lat, test_lon)
            self.service = svc
            self.strategy_name = "DVT"
            self.connected = True
            self.consecutive_errors = 0
            self._backoff = 0.5
            self._connect_time = time.time()
            _log(f"Connected via DVT to {self.rsd.udid}")
            self._start_heartbeat()
            return True
        except Exception as e:
            _log(f"DVT connect failed: {e}")

        # Strategy 2: Direct service (simpler protocol)
        try:
            svc = DirectLocationService(self.rsd)
            svc.connect()
            test_lat = self.last_lat if self.last_lat != 0.0 else 0.0001
            test_lon = self.last_lon if self.last_lon != 0.0 else 0.0001
            svc.set(test_lat, test_lon)
            self.service = svc
            self.strategy_name = "Direct"
            self.connected = True
            self.consecutive_errors = 0
            self._backoff = 0.5
            self._connect_time = time.time()
            _log(f"Connected via Direct to {self.rsd.udid}")
            self._start_heartbeat()
            return True
        except Exception as e:
            _log(f"Direct connect failed: {e}")

        _log("All API strategies failed")
        return False

    def disconnect(self):
        """Clean up all connections."""
        self._stop_heartbeat()
        if self.service:
            try:
                self.service.disconnect()
            except Exception:
                pass
            self.service = None
        self.connected = False

    def set_location(self, lat, lon):
        """
        Send location to device. Returns True on success.
        Handles errors and triggers reconnection if needed.
        """
        # Track last position for reconnection re-send
        self.last_lat = lat
        self.last_lon = lon

        if not self.connected or self.service is None:
            if not self._auto_reconnect():
                return False

        try:
            self.service.set(lat, lon)
            self.total_sent += 1
            self.consecutive_errors = 0
            self.last_send_time = time.time()
            self._backoff = 0.5
            return True
        except Exception as e:
            self.total_errors += 1
            self.consecutive_errors += 1
            _log(f"Send failed ({self.strategy_name}): {e}")

            # Try immediate retry with fresh connection (max 3 attempts)
            for attempt in range(3):
                if self._auto_reconnect():
                    try:
                        self.service.set(lat, lon)
                        self.total_sent += 1
                        self.consecutive_errors = 0
                        self.last_send_time = time.time()
                        return True
                    except Exception as e2:
                        _log(f"Retry {attempt + 1} also failed: {e2}")
                        time.sleep(0.3)

            return False

    def _get_device(self):
        """Find device via tunneld with UDID matching. Always fresh discovery."""
        max_attempts = 3
        for attempt in range(max_attempts):
            try:
                from pymobiledevice3.tunneld.api import get_tunneld_devices

                devices = get_tunneld_devices()
                break
            except Exception as e:
                err_name = type(e).__name__
                if "TunneldConnection" in err_name or "ConnectionError" in str(
                    type(e).__mro__
                ):
                    _log(f"Tunneld not running (attempt {attempt + 1}/{max_attempts})")
                else:
                    _log(
                        f"Device discovery error (attempt {attempt + 1}): {err_name}: {e}"
                    )
                if attempt < max_attempts - 1:
                    time.sleep(1.0)
                else:
                    return None

        if not devices:
            _log("No tunneld devices found (tunnel running but no devices)")
            return None

        _log(f"Found {len(devices)} tunnel device(s)")

        if self.udid:
            for d in devices:
                dev_udid = getattr(d, "udid", "") or ""
                if dev_udid == self.udid:
                    _log(f"Matched UDID: {dev_udid}")
                    return d
            _log(f"UDID {self.udid} not found, using first device")

        return devices[0]

    def _auto_reconnect(self):
        """Reconnect with exponential backoff. Thread-safe."""
        with self._reconnect_lock:
            if self._reconnecting:
                return self.connected
            self._reconnecting = True

        try:
            _log(f"Auto-reconnecting (backoff: {self._backoff:.1f}s)...")
            self.disconnect()
            time.sleep(min(self._backoff, 3.0))
            result = self.connect()
            if not result:
                self._backoff = min(self._backoff * 1.5, 8.0)
            return result
        finally:
            self._reconnecting = False

    def _hot_swap_refresh(self):
        """
        HOT-SWAP connection refresh: build new connection FIRST, then tear down old.

        This eliminates the ~1-3 second gap that caused location to "jump back home"
        during proactive refresh. The old connection stays active until the new one
        is verified, so there's zero downtime.
        """
        if not self.connected:
            return

        uptime = time.time() - (self._connect_time or 0)
        _log(
            f"Hot-swap refresh starting (uptime: {uptime:.0f}s, sent: {self.total_sent})"
        )

        saved_lat = self.last_lat
        saved_lon = self.last_lon
        old_service = self.service
        # NOTE: self.service and self.connected stay valid during the swap!

        # Step 1: Build NEW connection (old one still active)
        try:
            new_rsd = self._get_device()
            if new_rsd is None:
                _log("Hot-swap: device discovery failed, keeping old connection")
                return

            new_svc = DVTLocationService(new_rsd)
            new_svc.connect()

            # Verify new connection with current position
            test_lat = saved_lat if saved_lat != 0.0 else 0.0001
            test_lon = saved_lon if saved_lon != 0.0 else 0.0001
            new_svc.set(test_lat, test_lon)

            _log("Hot-swap: new connection verified OK")

        except Exception as e:
            _log(f"Hot-swap: new connection failed ({e}), keeping old connection")
            # Old connection still active — no downtime!
            return

        # Step 2: Atomic swap — replace old with new
        self.service = new_svc
        self.rsd = new_rsd
        self._connect_time = time.time()
        # self.connected was True the whole time — zero gap!

        _log("Hot-swap: swapped to new connection")

        # Step 3: Tear down old connection (after swap)
        if old_service:
            try:
                old_service.disconnect()
            except Exception:
                pass

        _log(
            f"Hot-swap refresh complete — zero downtime, position held at {saved_lat:.6f}, {saved_lon:.6f}"
        )

    def _start_heartbeat(self):
        """Start background heartbeat thread."""
        self._stop_heartbeat()
        self._heartbeat_stop.clear()
        self._heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop, daemon=True
        )
        self._heartbeat_thread.start()

    def _stop_heartbeat(self):
        """Stop heartbeat thread."""
        self._heartbeat_stop.set()
        if self._heartbeat_thread:
            self._heartbeat_thread.join(timeout=2.0)
            self._heartbeat_thread = None

    def _heartbeat_loop(self):
        """
        Background monitor:
        1. Detect stale connections (no successful send in 15s)
        2. HOT-SWAP refresh connections before DVT timeout (zero downtime)
        3. Handle consecutive error buildup
        """
        while not self._heartbeat_stop.wait(timeout=5.0):
            if not self.connected:
                continue

            # Hot-swap refresh: reconnect before DVT times out
            if self._connect_time:
                uptime = time.time() - self._connect_time
                if uptime > self.CONNECTION_REFRESH_INTERVAL:
                    self._hot_swap_refresh()
                    continue

            # Stale connection detection
            if self.last_send_time and (time.time() - self.last_send_time) > 15.0:
                if self.total_sent > 0:
                    try:
                        test_lat = self.last_lat if self.last_lat != 0.0 else 0.0001
                        test_lon = self.last_lon if self.last_lon != 0.0 else 0.0001
                        self.service.set(test_lat, test_lon)
                    except Exception:
                        _log("Heartbeat probe failed, triggering reconnect")
                        self._auto_reconnect()

            # Too many consecutive errors
            if self.consecutive_errors >= 5:
                _log(
                    f"Too many consecutive errors ({self.consecutive_errors}), reconnecting"
                )
                self._auto_reconnect()


def _log(msg):
    """Debug logging to stderr (visible in helper's stderr, not protocol)."""
    print(f"[helper] {msg}", file=sys.stderr, flush=True)


# ─── CLI Fallback ────────────────────────────────────────────────────────────


def send_via_cli(lat, lon, udid):
    """Last-resort: send location via pymobiledevice3 CLI subprocess.
    WARNING: This spawns a new process for every call. If called rapidly,
    it can create hundreds of zombie processes. Use sparingly!"""
    try:
        python = sys.executable
        cmd = [
            python,
            "-m",
            "pymobiledevice3",
            "developer",
            "dvt",
            "simulate-location",
            "set",
            "--tunnel",
        ]
        if udid:
            cmd.append(udid)
        cmd.extend(["--", str(lat), str(lon)])
        # Short timeout to prevent zombie accumulation
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return result.returncode == 0, result.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "CLI timeout (5s)"
    except Exception as e:
        return False, str(e)


# Track CLI calls to prevent zombie accumulation
_cli_call_count = 0
_cli_max_calls = 5  # Stop using CLI after this many consecutive calls


# ─── Main Loop ───────────────────────────────────────────────────────────────


def main():
    udid = sys.argv[1] if len(sys.argv) > 1 else None

    # Handle signals gracefully
    def on_signal(signum, frame):
        sys.exit(0)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    # Initialize engine and connect (retry up to 3 times on startup)
    engine = LocationEngine(udid)
    use_api = False
    for startup_attempt in range(3):
        use_api = engine.connect()
        if use_api:
            break
        _log(
            f"Startup connect attempt {startup_attempt + 1}/3 failed, retrying in 1s..."
        )
        time.sleep(1.0)

    cli_consecutive = 0

    if use_api:
        print("READY", flush=True)
        _log(f"API mode ready ({engine.strategy_name}), UDID: {engine.rsd.udid}")
    else:
        print("READY:CLI", flush=True)
        _log("Falling back to CLI mode")

    # Use readline() instead of iteration for lower latency
    # (Python's `for line in sys.stdin:` uses internal buffering that can delay lines)
    while True:
        line = sys.stdin.readline()
        if not line:
            break  # EOF
        line = line.strip()
        if not line:
            continue

        if line == "PING":
            if engine.connected:
                print("PONG", flush=True)
            else:
                print("PONG:DEGRADED", flush=True)
            continue

        if line == "QUIT":
            break

        if line == "RECONNECT":
            _log("Manual reconnect requested")
            engine.disconnect()
            if engine.connect():
                use_api = True
                cli_consecutive = 0
                print("OK:RECONNECTED", flush=True)
            else:
                use_api = False
                print("ERR:reconnect_failed", flush=True)
            continue

        if line == "STATUS":
            stats = (
                f"strategy={engine.strategy_name},"
                f"sent={engine.total_sent},"
                f"errors={engine.total_errors},"
                f"consec_err={engine.consecutive_errors},"
                f"connected={engine.connected}"
            )
            print(f"STATUS:{stats}", flush=True)
            continue

        # Parse coordinates
        parts = line.split()
        if len(parts) < 2:
            continue

        try:
            lat = float(parts[0])
            lon = float(parts[1])
        except ValueError:
            print("ERR:invalid_coords", flush=True)
            continue

        # Try API first
        if use_api:
            if engine.set_location(lat, lon):
                print("OK", flush=True)
                cli_consecutive = 0
                continue
            else:
                _log("API send failed, trying CLI fallback")

        # CLI fallback — LIMITED to prevent zombie process accumulation.
        # Each CLI call spawns a subprocess that may hang. After 5 consecutive
        # CLI failures, stop calling CLI and just report errors.
        if cli_consecutive < 5:
            ok, err = send_via_cli(lat, lon, udid)
            if ok:
                print("OK", flush=True)
                cli_consecutive = 0
            else:
                cli_consecutive += 1
                print(f"ERR:{err}", flush=True)
                _log(f"CLI failed ({cli_consecutive}/5): {err}")
        else:
            # Stop trying CLI — too many zombies. Just report error.
            print("ERR:cli_disabled_too_many_failures", flush=True)

        # If CLI fails too many times, try to re-establish API
        if cli_consecutive >= 3 and not engine.connected:
            _log("Multiple CLI failures, attempting API reconnect...")
            if engine.connect():
                use_api = True
                cli_consecutive = 0
                _log("API reconnection successful!")

    # Cleanup
    engine.disconnect()
    _log("Helper shutdown complete")


if __name__ == "__main__":
    main()
