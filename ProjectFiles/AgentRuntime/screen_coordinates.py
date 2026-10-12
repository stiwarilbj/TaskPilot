"""Consume the native observation's authoritative coordinate transforms.

No provider calls, guessed Retina factor, target creation, or action mutation.
Metadata-free observations are supported only for legacy offline fixtures.
"""
from __future__ import annotations

import math
from typing import Any

COORDINATE_MAPPING_VERSION = 1
NORMALIZED_EXTENT = 1000
EDGE_INSET = 0.5


class CoordinateMappingError(ValueError):
    pass


def number(value: Any) -> float:
    if type(value) not in {int, float} or not math.isfinite(value) or abs(value) > 10_000_000:
        raise CoordinateMappingError("Screen coordinates must be finite numbers")
    return value


def rectangle(value: Any) -> tuple[float, float, float, float]:
    if not isinstance(value, dict): raise CoordinateMappingError("Missing screen rectangle")
    x, y, width, height = (number(value.get(k)) for k in ("x", "y", "width", "height"))
    if width <= 0 or height <= 0 or x + width <= x or y + height <= y:
        raise CoordinateMappingError("Screen rectangles must have positive dimensions")
    number(x + width); number(y + height)
    return x, y, width, height


def pixels(value: Any) -> tuple[int, int]:
    if not isinstance(value, dict): raise CoordinateMappingError("Missing captured image dimensions")
    width, height = (value.get(k) for k in ("width", "height"))
    if any(type(n) is not int or n <= 0 or n > 10_000_000 for n in (width, height)):
        raise CoordinateMappingError("Captured image dimensions must be positive integers")
    return width, height


def transform(value: Any) -> tuple[float, float, float, float]:
    if not isinstance(value, dict): raise CoordinateMappingError("Missing native screen transform")
    return tuple(number(value.get(k)) for k in ("x_scale", "y_scale", "x_offset", "y_offset"))


def apply(matrix: tuple, point: tuple) -> tuple[float, float]:
    sx, sy, ox, oy = matrix
    x, y = (number(n) for n in point)
    return ox + x * sx, oy + y * sy


def validate_observation_mapping(observation: dict, *, required: bool = False) -> dict | None:
    mapping = observation.get("coordinate_mapping")
    if mapping is None and not required: return None
    if not isinstance(mapping, dict): raise CoordinateMappingError("The observation lacks its native coordinate mapping")
    if type(mapping.get("version")) is not int or mapping["version"] != COORDINATE_MAPPING_VERSION:
        raise CoordinateMappingError("Screen coordinate mapping versions do not match")
    if mapping.get("axes") != "quartz_top_left" or type(mapping.get("normalized_extent")) is not int or mapping["normalized_extent"] != NORMALIZED_EXTENT:
        raise CoordinateMappingError("Unsupported screen coordinate axes or extent")
    if number(mapping.get("edge_inset_points")) != EDGE_INSET:
        raise CoordinateMappingError("Unsupported screen coordinate edge policy")
    display = observation.get("display", {})
    if type(mapping.get("display_id")) is not int or type(display.get("id")) is not int or mapping["display_id"] != display["id"]:
        raise CoordinateMappingError("Screen coordinate mapping belongs to another display")
    revision = observation.get("observation_revision")
    if not isinstance(revision, str) or not revision or mapping.get("observation_revision") != revision:
        raise CoordinateMappingError("Screen coordinate mapping belongs to another observation")
    bounds = rectangle(mapping.get("display_bounds"))
    if bounds != rectangle(display): raise CoordinateMappingError("Screen coordinate mapping has stale display geometry")
    x, y, width, height = bounds
    full_width, full_height = pixels(mapping.get("full_image_size"))
    image_width, image_height = pixels(mapping.get("image_size"))
    cx, cy, cw, ch = rectangle(mapping.get("source_rect"))
    if cx < 0 or cy < 0 or cx + cw > full_width or cy + ch > full_height:
        raise CoordinateMappingError("The crop is outside the captured image")
    expected = {
        "normalized_to_global": (width / NORMALIZED_EXTENT, height / NORMALIZED_EXTENT, x, y),
        "image_to_global": (cw / image_width / full_width * width, ch / image_height / full_height * height,
                            x + cx / full_width * width, y + cy / full_height * height),
    }
    for name, calculated in expected.items():
        supplied = transform(mapping.get(name))
        if any(not math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-9) for a, b in zip(supplied, calculated)):
            raise CoordinateMappingError("The native screen transform disagrees with its geometry")
    return mapping


def action_global_point(action: dict, observation: dict) -> tuple[float, float]:
    nx, ny = number(action.get("x")), number(action.get("y"))
    if not 0 <= nx <= NORMALIZED_EXTENT or not 0 <= ny <= NORMALIZED_EXTENT:
        raise CoordinateMappingError("Action coordinates must be normalized from 0 through 1000")
    mapping = validate_observation_mapping(observation)
    x, y, width, height = rectangle(observation.get("display"))
    # Production always consumes native coefficients; old sanitized fixtures
    # use the same centralized adapter without pretending to know image pixels.
    matrix = transform(mapping["normalized_to_global"]) if mapping else (width / NORMALIZED_EXTENT, height / NORMALIZED_EXTENT, x, y)
    gx, gy = apply(matrix, (nx, ny))
    inset = mapping["edge_inset_points"] if mapping else EDGE_INSET
    return (x + width - min(inset, width / 2) if gx >= x + width else gx,
            y + height - min(inset, height / 2) if gy >= y + height else gy)


def image_global_point(point: tuple, observation: dict) -> tuple[float, float]:
    mapping = validate_observation_mapping(observation, required=True)
    width, height = pixels(mapping["image_size"])
    px, py = (number(n) for n in point)
    if not 0 <= px <= width or not 0 <= py <= height:
        raise CoordinateMappingError("The point is outside the captured image")
    return apply(transform(mapping["image_to_global"]), (px, py))


def image_action_point(point: tuple, observation: dict) -> tuple[float, float]:
    gx, gy = image_global_point(point, observation)
    sx, sy, ox, oy = transform(observation["coordinate_mapping"]["normalized_to_global"])
    return (gx - ox) / sx, (gy - oy) / sy
