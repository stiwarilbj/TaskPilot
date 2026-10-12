"""Native-checked screen geometry for owned, fake bridge responses."""
import json
from pathlib import Path


def fixture_coordinates(revision):
    case = json.loads((Path(__file__).resolve().parents[2] / 'Tests/Fixtures/screen-coordinate-cases.json').read_text())['cases'][0]
    case['coordinate_mapping']['observation_revision'] = revision
    return {key: case[key] for key in ('display', 'coordinate_mapping')}
