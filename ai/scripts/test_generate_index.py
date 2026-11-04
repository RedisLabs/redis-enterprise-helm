"""Run with uv run --with pyyaml --with packaging python -m unittest discover -s ai/scripts."""
import re
import unittest

from generate_index import generate_index_html


VERSION = {
    'version': '1.0.0', 'appVersion': '1.0.0',
    'created': '2026-11-01T00:00:00Z', 'digest': '12345678',
    'urls': ['https://example.com/chart.tgz'],
}


class GenerateIndexTests(unittest.TestCase):
    def test_iris_is_selected_and_components_are_hidden(self):
        page = generate_index_html({'entries': {
            'redis-agent-memory': [VERSION], 'redis-iris': [VERSION],
        }})
        self.assertIn('aria-controls="redis-iris" aria-selected="true" tabindex="0"', page)
        self.assertIn('<div id="more-products" hidden><button', page)
        self.assertIn('aria-expanded="false"', page)
        panels = re.findall(r'<section[^>]+>', page)
        self.assertEqual(len(panels), 2)
        self.assertNotIn('hidden', panels[0])
        self.assertIn('id="redis-iris"', panels[0])
        self.assertIn('hidden', panels[1])
        self.assertIn('helm install redis-iris redis-ai/redis-iris --version 1.0.0', page)

    def test_missing_iris_does_not_promote_a_component(self):
        page = generate_index_html({'entries': {'redis-agent-memory': [VERSION]}})
        self.assertIn('The Redis Iris Helm chart is not yet published.', page)
        self.assertNotIn('helm install redis-iris ', page)
        self.assertIn('aria-controls="redis-agent-memory" aria-selected="false"', page)
        self.assertIn('<div id="more-products" hidden>', page)

    def test_iris_only_has_no_more_button(self):
        page = generate_index_html({'entries': {'redis-iris': [VERSION]}})
        self.assertNotIn('class="more-toggle"', page)
        self.assertNotIn('not yet published', page)

    def test_empty_index_shows_only_unpublished_iris(self):
        page = generate_index_html({'entries': {}})
        self.assertIn('The Redis Iris Helm chart is not yet published.', page)
        self.assertNotIn('class="more-toggle"', page)
        self.assertNotIn('helm install ', page)


if __name__ == '__main__':
    unittest.main()
