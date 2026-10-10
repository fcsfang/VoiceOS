import copy
import runpy
from pathlib import Path
import unittest

module = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'cloud-text-evaluation.py'))
validate, schema = module['schema_valid'], module['SCHEMA']

class ContractTests(unittest.TestCase):
    def sample(self):
        return dict(claims=[dict(content='暂定观点', owner='用户', evidence='明确原话', source_ids=['source-1'])], actions=[], questions=[], relations=[], corrections=[], english_feedback=[])
    def test_nested_object_valid(self):
        self.assertTrue(validate(self.sample(), schema))
    def test_root_fields_do_not_prove_nested_types(self):
        value = self.sample(); value['claims'][0]['source_ids'] = 'source-1'
        self.assertFalse(validate(value, schema))
    def test_nested_unknown_fields_rejected(self):
        value = self.sample(); value['claims'][0]['confirmed'] = True
        self.assertFalse(validate(value, schema))
    def test_missing_nested_field_rejected(self):
        value = self.sample(); del value['claims'][0]['owner']
        self.assertFalse(validate(value, schema))
    def test_extra_root_field_rejected(self):
        value = self.sample(); value['executed'] = True
        self.assertFalse(validate(value, schema))
    def test_non_object_root_rejected(self):
        self.assertFalse(validate([], schema))

if __name__ == '__main__': unittest.main()
