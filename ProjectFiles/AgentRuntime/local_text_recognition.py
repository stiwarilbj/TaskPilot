"""Native Vision evidence and bounded same-request image attachments.

Text candidates never enter the executable Accessibility element map. No
provider calls, local actions, target synthesis, or persisted recognition data.
"""
from __future__ import annotations

import base64
import math
import struct

from screen_coordinates import rectangle, pixels, transform, apply, validate_observation_mapping, CoordinateMappingError
from observation_context import observation_indexes

TEXT_RECOGNITION_VERSION = 1
EXECUTION_CONFIDENCE = 0.8


class TextRecognitionError(ValueError):
    pass


def inside(point, rect):
    x, y, w, h = rect
    return x <= point[0] <= x + w and y <= point[1] <= y + h


def integer(value):
    if type(value) is not int or not 0 < value <= 2_147_483_647:
        raise TextRecognitionError('Invalid recognized text app/window identity')
    return value


def validate_text_recognition(observation: dict, *, required: bool = False) -> dict | None:
    report = observation.get('text_recognition')
    if report is None and not required: return None
    if not isinstance(report, dict) or type(report.get('version')) is not int or report['version'] != TEXT_RECOGNITION_VERSION:
        raise TextRecognitionError('Text recognition versions do not match')
    if report.get('state') not in ('not_needed', 'recognized', 'partial') or report.get('observation_revision') != observation.get('observation_revision'):
        raise TextRecognitionError('Text recognition belongs to another observation')
    rows, crops = report.get('targets'), report.get('detail_crops')
    if not isinstance(rows, list) or len(rows) > 48 or not isinstance(crops, list) or len(crops) > 2:
        raise TextRecognitionError('Text recognition exceeds its bounded observation budget')
    if report['state'] == 'not_needed' and (rows or crops):
        raise TextRecognitionError('Unused recognition cannot contain targets or crops')
    mapping = validate_observation_mapping(observation, required=True)
    image_matrix, normalized_matrix = transform(mapping['image_to_global']), transform(mapping['normalized_to_global'])
    display = rectangle(mapping['display_bounds'])
    size = pixels(mapping['image_size'])
    indexes = observation_indexes(observation)
    ids = set()
    try:
        for i, row in enumerate(rows):
            if not isinstance(row, dict) or row.get('candidate_id') != f"{observation['observation_revision']}:text:{i}" or row['candidate_id'] in ids:
                raise TextRecognitionError('Text recognition references a stale or duplicate candidate')
            ids.add(row['candidate_id'])
            if row.get('provisional') is not True or not isinstance(row.get('text'), str) or not row['text'].strip() or len(row['text']) > 256:
                raise TextRecognitionError('Recognized text must remain provisional data')
            if 'line_text' in row and (not isinstance(row['line_text'], str) or not row['line_text'].strip() or len(row['line_text']) > 256):
                raise TextRecognitionError('Invalid recognized text context')
            confidence = row.get('confidence')
            if type(confidence) not in (int, float) or not math.isfinite(confidence) or not 0.45 <= confidence <= 1:
                raise TextRecognitionError('Invalid text recognition confidence')
            pid, window = integer(row.get('pid')), integer(row.get('graphics_window_id'))
            owners = indexes.window_candidates(pid, window, graphics=True, application_last=True)
            owner = owners[0] if owners else None
            if owner is None:
                raise TextRecognitionError('Recognized text lacks observed native window ownership')
            secure = any(e.get('value') == '[secure]' or 'secure' in
                         (str(e.get('role', '')) + str(e.get('subrole', ''))).casefold()
                         for e in indexes.elements_by_pid.get(pid, ()))
            if secure: raise TextRecognitionError('Secure app text cannot become recognition evidence')
            frame, image, normalized = (rectangle(row.get(k)) for k in ('frame', 'image_bounds', 'normalized_bounds'))
            window_bounds = rectangle(owner.get('frame'))
            if not inside(frame[:2], window_bounds) or not inside((frame[0] + frame[2], frame[1] + frame[3]), window_bounds):
                raise TextRecognitionError('Recognized text is outside its observed window')
            for local, matrix, bounds in ((image, image_matrix, (0, 0, *size)), (normalized, normalized_matrix, (0, 0, 1000, 1000))):
                for point in ((local[0], local[1]), (local[0] + local[2], local[1] + local[3])):
                    if not inside(point, bounds): raise TextRecognitionError('Text recognition bounds are outside their image')
                mapped = (*apply(matrix, local[:2]), local[2] * matrix[0], local[3] * matrix[1])
                if any(not math.isclose(a, b, abs_tol=0.001) for a, b in zip(mapped, frame)):
                    raise TextRecognitionError('Text recognition coordinate spaces disagree')
            if not inside(frame[:2], display) or not inside((frame[0] + frame[2], frame[1] + frame[3]), display):
                raise TextRecognitionError('Text recognition is outside the assigned display')
            repeated = sum(r.get('text', '').lower() == row['text'].lower() for r in rows)
            if type(row.get('repeated_text_count')) is not int or row['repeated_text_count'] != repeated:
                raise TextRecognitionError('Repeated text candidates must remain explicit')
        for crop in crops:
            if not isinstance(crop, dict) or crop.get('mime_type') != 'image/png': raise TextRecognitionError('Invalid detail crop')
            candidates = [r for r in rows if r['text'] == crop.get('candidate_text') and r['pid'] == crop.get('pid') and
                          r['graphics_window_id'] == crop.get('graphics_window_id')]
            if not candidates:
                raise TextRecognitionError('Detail crop has no current recognized target')
            dimensions = pixels(crop.get('image_size'))
            if max(dimensions) > 4096: raise TextRecognitionError('Detail crop dimensions exceed their limit')
            matrix = transform(crop.get('image_to_global'))
            if matrix[0] <= 0 or matrix[1] <= 0 or not all(inside(apply(matrix, p), display) for p in ((0, 0), dimensions)):
                raise TextRecognitionError('Invalid detail crop coordinate transform')
            origin, end = apply(matrix, (0, 0)), apply(matrix, dimensions)
            region = (*origin, end[0] - origin[0], end[1] - origin[1])
            if not any(all(inside(p, region) for p in ((r['frame']['x'], r['frame']['y']),
                    (r['frame']['x'] + r['frame']['width'], r['frame']['y'] + r['frame']['height']))) for r in candidates):
                raise TextRecognitionError('Detail crop does not contain its recognized target')
            if not isinstance(crop.get('data'), str) or len(crop['data']) > 699_052: raise TextRecognitionError('Detail crop exceeds its byte limit')
            data = base64.b64decode(crop['data'], validate=True)
            if len(data) < 24 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR' or struct.unpack('>II', data[16:24]) != dimensions:
                raise TextRecognitionError('Invalid detail crop image bytes')
    except (CoordinateMappingError, ValueError, TypeError, KeyError, OverflowError) as error:
        if isinstance(error, TextRecognitionError): raise
        raise TextRecognitionError('Invalid native text recognition metadata') from error
    return report


def prompt_text_recognition(observation: dict) -> dict | None:
    report = validate_text_recognition(observation)
    if report is None or report['state'] == 'not_needed': return None
    return {**report, 'detail_crops': [{k: v for k, v in crop.items() if k != 'data'} for crop in report['detail_crops']]}


def detail_images(observation: dict | None) -> list[dict]:
    if not observation: return []
    report = validate_text_recognition(observation)
    return report['detail_crops'] if report else []


def coordinate_text_target(action: dict, observation: dict) -> dict | None:
    if action.get('element_id') or action.get('type') not in ('click', 'double_click'): return None
    report = validate_text_recognition(observation)
    if not report: return None
    point = (action['x'], action['y'])
    rows = [r for r in report['targets'] if r['pid'] == action.get('pid') and inside(point, rectangle(r['normalized_bounds']))]
    if len(rows) > 1: raise TextRecognitionError('action coordinates overlap provisional text candidates; select an unambiguous current target')
    if rows and rows[0]['confidence'] < EXECUTION_CONFIDENCE:
        raise TextRecognitionError('action coordinates select low-confidence provisional text; inspect the screenshot or use a native control')
    return rows[0] if rows else None
