# AI Helm repository page

The AI release workflow generates `ai/index.html` from the published
`ai/index.yaml` after updating the chart index, then deploys the entire Pages
branch. Products appear as tabs, each with its own version selection, search,
and install command. Switch tabs with a click or the arrow, Home, and End keys.

Edit `PRODUCTS` in `generate_index.py` to control which products appear, their
display names, and their tab order. Each entry pairs a chart name from
`index.yaml` with a display name. The list covers the Redis Iris global chart
and all its products: Agent Memory, Agent Playbook, Lens, Context Gateway,
Intent Router, Identity Service, and the Iris user interface. It also retains
the Redis Iris On-Premises Library. Keep this list aligned with the dependencies
in [the Iris global chart](https://github.com/redislabsdev/iris/blob/main/iris/helm/Chart.yaml).
Unlisted charts stay off the page; listed charts without published versions
are skipped and appear automatically once published. Generation fails if no listed products are published.
The root page and operator release workflow are independent.

To preview using a local checkout of the `gh-pages` branch:

```bash
uv run --python 3.12 --with pyyaml --with packaging \
  ai/scripts/generate_index.py /path/to/pages/ai/index.yaml \
  --output /path/to/pages/ai/index.html
```

The next AI chart release publishes the updated page. This change
does not create a chart release or modify the published site by itself.
