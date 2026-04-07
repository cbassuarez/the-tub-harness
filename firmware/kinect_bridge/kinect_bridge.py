#!/usr/bin/env python3
"""
kinect_bridge.py — Kinect v2 body detection bridge for THE TUB.

Reads depth frames from a Kinect v2 via libfreenect2, detects person blobs
via depth thresholding + contour detection, and streams body data over UDP
to the Swift harness app.

UDP protocol (JSON, one packet per frame to localhost:9920):
  {"bodies": [
    {"bodyIndex": 0, "x": 960, "y": 540, "depthZ": 2.5,
     "confidence": 0.9, "isTracked": true},
    ...
  ]}

Usage:
  python3 kinect_bridge.py [--port 9920] [--fps 15] [--preview]
"""

import argparse
import json
import socket
import sys
import time

import cv2
import numpy as np

try:
    import freenect2
except ImportError:
    print("ERROR: freenect2 not installed. Install with: pip3 install freenect2")
    print("       Requires libfreenect2 built from source (Apple Silicon fork).")
    sys.exit(1)

# Depth thresholds (mm)
DEPTH_MIN_MM = 800
DEPTH_MAX_MM = 5000

# Minimum contour area to count as a person (px²)
MIN_PERSON_AREA = 5000

# Maximum bodies to track
MAX_BODIES = 6

# Depth frame dimensions (Kinect v2)
DEPTH_WIDTH = 512
DEPTH_HEIGHT = 424

# Output coordinate space (matches Kinect v2 color resolution)
OUTPUT_WIDTH = 1920
OUTPUT_HEIGHT = 1080


def detect_bodies(depth_frame: np.ndarray) -> list[dict]:
    """Threshold depth, find contours, return body blobs sorted by area."""
    # Mask valid depth range
    mask = np.zeros(depth_frame.shape, dtype=np.uint8)
    valid = (depth_frame >= DEPTH_MIN_MM) & (depth_frame <= DEPTH_MAX_MM)
    mask[valid] = 255

    # Morphological cleanup: close small gaps, remove noise
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    # Find contours
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # Filter by area and sort descending
    blobs = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area < MIN_PERSON_AREA:
            continue
        blobs.append((contour, area))
    blobs.sort(key=lambda b: b[1], reverse=True)
    blobs = blobs[:MAX_BODIES]

    # Build body data
    bodies = []
    scale_x = OUTPUT_WIDTH / DEPTH_WIDTH
    scale_y = OUTPUT_HEIGHT / DEPTH_HEIGHT

    for i, (contour, area) in enumerate(blobs):
        M = cv2.moments(contour)
        if M["m00"] == 0:
            continue
        cx = M["m10"] / M["m00"]
        cy = M["m01"] / M["m00"]

        # Depth at centroid (mm -> meters)
        cx_int = int(round(cx))
        cy_int = int(round(cy))
        cx_int = max(0, min(DEPTH_WIDTH - 1, cx_int))
        cy_int = max(0, min(DEPTH_HEIGHT - 1, cy_int))
        depth_mm = float(depth_frame[cy_int, cx_int])
        depth_m = depth_mm / 1000.0 if depth_mm > 0 else 0.0

        # Confidence from blob area (larger = more confident, capped at 1.0)
        max_expected_area = 80000  # roughly a person filling a good chunk of frame
        confidence = min(1.0, area / max_expected_area)

        bodies.append({
            "bodyIndex": i,
            "x": round(cx * scale_x, 1),
            "y": round(cy * scale_y, 1),
            "depthZ": round(depth_m, 3),
            "confidence": round(confidence, 3),
            "isTracked": True,
        })

    return bodies


def main():
    parser = argparse.ArgumentParser(description="Kinect v2 body detection bridge")
    parser.add_argument("--port", type=int, default=9920, help="UDP port (default 9920)")
    parser.add_argument("--fps", type=int, default=15, help="Target frame rate (default 15)")
    parser.add_argument("--preview", action="store_true", help="Show OpenCV preview window")
    args = parser.parse_args()

    frame_interval = 1.0 / args.fps

    # Open Kinect
    device = freenect2.Device()
    print(f"[kinect_bridge] Kinect opened: {device.serial_number}")

    # UDP socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = ("127.0.0.1", args.port)
    print(f"[kinect_bridge] Streaming to UDP {target[0]}:{target[1]} at {args.fps} Hz")

    # Start depth stream
    device.start()
    frame_count = 0

    try:
        while True:
            t0 = time.monotonic()

            # Grab depth frame
            frames = device.get_next_frame()
            depth = frames.depth  # float32 array, mm

            # Detect bodies
            bodies = detect_bodies(depth)

            # Send UDP packet
            packet = json.dumps({"bodies": bodies}).encode("utf-8")
            sock.sendto(packet, target)

            frame_count += 1
            if frame_count % (args.fps * 5) == 0:
                print(f"[kinect_bridge] frame {frame_count}, {len(bodies)} bodies detected")

            # Preview window
            if args.preview:
                vis = np.zeros((DEPTH_HEIGHT, DEPTH_WIDTH, 3), dtype=np.uint8)
                valid = (depth >= DEPTH_MIN_MM) & (depth <= DEPTH_MAX_MM)
                normalized = np.zeros_like(depth)
                normalized[valid] = 255 - ((depth[valid] - DEPTH_MIN_MM) / (DEPTH_MAX_MM - DEPTH_MIN_MM) * 255)
                vis[:, :, 1] = normalized.astype(np.uint8)

                for body in bodies:
                    cx = int(body["x"] / (OUTPUT_WIDTH / DEPTH_WIDTH))
                    cy = int(body["y"] / (OUTPUT_HEIGHT / DEPTH_HEIGHT))
                    cv2.circle(vis, (cx, cy), 10, (0, 255, 255), 2)
                    cv2.putText(vis, f"#{body['bodyIndex']} z={body['depthZ']:.1f}m",
                                (cx + 12, cy), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 255), 1)

                cv2.imshow("Kinect Bridge", vis)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

            # Pace to target FPS
            elapsed = time.monotonic() - t0
            if elapsed < frame_interval:
                time.sleep(frame_interval - elapsed)

    except KeyboardInterrupt:
        print("\n[kinect_bridge] Shutting down...")
    finally:
        device.stop()
        sock.close()
        if args.preview:
            cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
