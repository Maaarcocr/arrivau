#!/usr/bin/env python3
"""Black-box localhost smoke test against a running demo API; standard library only.

Use a disposable database. This intentionally creates and completes a delivery.
"""
import argparse
import json
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    parsed = urllib.parse.urlparse(base)
    if parsed.hostname not in ("localhost", "127.0.0.1", "::1"):
        parser.error("This demo uses public fixture tokens and must target loopback")

    def request(method, path, token=None, body=None, expected=200):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        payload = json.loads(raw)
        assert status == expected, f"{method} {path}: expected {expected}, got {status}: {payload}"
        return payload

    dispatcher = "demo-dispatcher"
    driver = "demo-driver-1"
    other = "demo-driver-2"
    assert request("GET", "/health")["status"] == "ok"
    request("GET", "/v1/deliveries", expected=401)
    assert request("GET", "/v1/me", dispatcher)["role"] == "dispatcher"
    request("GET", "/v1/drivers", driver, expected=403)
    shift = request("POST", "/v1/shift", driver, {"active": True, "capacity": 2})
    assert shift["active"]
    point = {"lat": 36.7163, "lng": 15.0908}
    request("POST", "/v1/location", driver, point)
    now = int(time.time())
    delivery = request("POST", "/v1/deliveries", dispatcher, {
        "shop_name": "Smoke Test Pizzeria",
        "pickup_address": "Via Roma 1, Pachino (fixture)",
        "pickup": point,
        "dropoff_address": "Via Garibaldi 8, Pachino (fixture)",
        "dropoff": {"lat": 36.7180, "lng": 15.0940},
        "ready_at": now - 60,
        "deadline_at": now + 3600,
        "load_units": 1,
        "max_ride_seconds": 1800,
    }, expected=201)
    identifier = delivery["id"]
    suggestions = request("GET", f"/v1/deliveries/{identifier}/suggestions", dispatcher)
    assert any(s["driver_id"] == "driver-1" and s["route"]["feasible"] for s in suggestions)
    assigned = request("POST", f"/v1/deliveries/{identifier}/assign", dispatcher, {"driver_id": "driver-1"})
    assert assigned["status"] == "assigned"
    assert identifier in [d["id"] for d in request("GET", "/v1/deliveries", driver)]
    assert identifier not in [d["id"] for d in request("GET", "/v1/deliveries", other)]
    request("POST", f"/v1/deliveries/{identifier}/status", other, {"status": "picked_up"}, expected=403)
    request("POST", f"/v1/deliveries/{identifier}/status", driver, {"status": "delivered"}, expected=409)
    request("POST", "/v1/shift", driver, {"active": False, "capacity": 2}, expected=409)
    route = request("GET", "/v1/route", driver)
    assert route["feasible"] and route["stops"][0]["delivery_id"] == identifier, "Use a clean database"
    assert [s["kind"] for s in route["stops"]] == ["pickup", "dropoff"], "Use a clean database"
    picked = request("POST", f"/v1/deliveries/{identifier}/status", driver, {"status": "picked_up"})
    assert picked["picked_up_at"] is not None
    done = request("POST", f"/v1/deliveries/{identifier}/status", driver, {"status": "delivered"})
    assert done["status"] == "delivered" and done["delivered_at"] is not None
    assert request("GET", "/v1/route", driver)["stops"] == []
    request("POST", "/v1/shift", driver, {"active": False, "capacity": 2})
    print(f"PASS: real HTTP dispatcher → assignment → driver pickup → delivery ({identifier})")
    print("PASS: authorization, driver isolation, transition order, active-work shift guard")


if __name__ == "__main__":
    main()

