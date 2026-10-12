"""Native-checked screen geometry for owned, fake bridge responses."""
import json
from pathlib import Path


def fixture_coordinates(revision, controls=0):
    case = json.loads((Path(__file__).resolve().parents[2] / 'Tests/Fixtures/screen-coordinate-cases.json').read_text())['cases'][0]
    case['coordinate_mapping']['observation_revision'] = revision
    return {**{key: case[key] for key in ('display', 'coordinate_mapping')},
            'text_recognition': {'version': 1, 'state': 'not_needed', 'observation_revision': revision, 'targets': [], 'detail_crops': []},
            'observation_completeness': {'version': 1, 'state': 'complete',
                'scope': 'exposed_accessibility_tree_on_assigned_display', 'collected_controls': controls,
                'reason_counts': {}, 'limitations': [], 'limitation_scopes_omitted': 0,
                'local_expansion': {'subtrees_attempted': 0, 'controls_added': 0, 'read_retries': 0}}}
