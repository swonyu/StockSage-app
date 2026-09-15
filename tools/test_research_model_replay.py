import copy
import json
import unittest
from unittest.mock import patch

from tools import research_model_replay as replay


class ReplayGuardsTests(unittest.TestCase):
    def case(self):
        facts = {f'F{i}': f'fact {i}' for i in range(1, 12)}
        return {'facts': dict(reversed(list(facts.items()))), 'request': {'messages': [
            {'role': 'user', 'content': '\n'.join(f'{key}: {value}' for key, value in facts.items())}]}}

    def test_fact_ids_keep_numeric_order_and_original_capture(self):
        original = self.case()
        normalized = replay.normalize_cases([original])[0]
        self.assertEqual(normalized['facts'][9], 'fact 10')
        self.assertIsInstance(original['facts'], dict)

    def test_missing_fact_id_is_refused(self):
        case = self.case()
        del case['facts']['F3']
        with self.assertRaises(ValueError):
            replay.normalize_cases([case])

    def test_prompt_fact_mismatch_is_refused(self):
        case = self.case()
        case['facts']['F1'] = 'altered source'
        with self.assertRaises(ValueError):
            replay.normalize_cases([case])

    def check_lease(self, model_changes=None, active_changes=None):
        active = dict(owner='stocksage', session_id='session', id='request', status='held',
                      model_instance_id='owned', model_key='qwen3.5-9b',
                      metadata={'context_length': 16384})
        model = dict(identifier='owned', deviceIdentifier=None, status='idle', queued=0,
                     modelKey='qwen3.5-9b', contextLength=16384)
        active.update(active_changes or {})
        model.update(model_changes or {})
        with patch.object(replay, 'command', side_effect=[json.dumps({'active': active}), json.dumps([model])]):
            return replay.verify_lease('session', 'request', 'owned')

    def test_only_exact_owned_local_profile_is_accepted(self):
        self.assertEqual(self.check_lease()['identifier'], 'owned')

    def test_remote_instance_is_refused_even_with_same_name(self):
        with self.assertRaises(RuntimeError):
            self.check_lease({'deviceIdentifier': 'remote'})

    def test_context_mismatch_is_refused_even_when_larger(self):
        with self.assertRaises(RuntimeError):
            self.check_lease({'contextLength': 71680})

    def test_busy_model_and_wrong_owner_are_refused(self):
        for model, active in [({'queued': 1}, {}), ({'status': 'generating'}, {}),
                              ({}, {'owner': 'other'}), ({}, {'status': 'release_pending'})]:
            with self.subTest(model=model, active=active), self.assertRaises(RuntimeError):
                self.check_lease(model, active)


if __name__ == '__main__':
    unittest.main()
